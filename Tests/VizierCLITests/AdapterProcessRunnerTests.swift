import Foundation
import Glibc
import Testing
@testable import VizierCLI

// A hang fails the test in a minute instead of holding the CI job until it is cancelled.
@Suite(.timeLimit(.minutes(1))) struct AdapterProcessRunnerTests {
    private func sh(_ script: String, stdin: Data? = nil, timeout: Duration = .seconds(10), grace: Duration = .seconds(1), limit: Int = 1 << 20) async throws -> ProcessResult {
        try await ProcessRunner.run(["/bin/sh", "-c", script], stdin: stdin, timeout: timeout, killGrace: grace, outputLimit: limit)
    }

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await sh("echo out; echo err >&2; exit 3")
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
    }

    @Test func runsArgvWithoutAShell() async throws {
        // A shell would expand $HOME and split on ;. Argv does neither.
        let result = try await ProcessRunner.run(["/bin/echo", "$HOME; echo pwned"])
        #expect(result.stdoutText == "$HOME; echo pwned\n")
    }

    @Test func stdinIsDeliveredAndLargeOutputDoesNotDeadlock() async throws {
        // cat echoes while we are still writing: stdin must be written while stdout is drained.
        let payload = Data(repeating: 0x61, count: 2 << 20)
        let result = try await ProcessRunner.run(["/bin/cat"], stdin: payload, outputLimit: 4 << 20)
        #expect(result.stdout == payload)
        #expect(!result.truncated)
    }

    @Test func standardInputIsEmptyWhenNoneGiven() async throws {
        let result = try await sh("cat; echo done")
        #expect(result.stdoutText == "done\n")
    }

    @Test func outputIsCappedAndFlagged() async throws {
        let result = try await sh("head -c 100000 /dev/zero", limit: 1000)
        #expect(result.stdout.count == 1000)
        #expect(result.truncated)
        #expect(result.exitCode == 0)
    }

    @Test func deadlineTerminatesTheWholeGroup() async throws {
        let marker = NSTemporaryDirectory() + "vizier-grandchild-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let started = ContinuousClock.now
        let result = try await sh("sleep 60 & echo $! > '\(marker)'; wait", timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.signal == SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
        let pid = pid_t(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        // The grandchild went with its group: after reaping by init it is gone.
        var alive = true
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { alive = false; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!alive)
    }

    @Test func aHelperThatIgnoresSIGTERMIsKilled() async throws {
        let started = ContinuousClock.now
        let result = try await sh("trap '' TERM; while :; do sleep 1; done", timeout: .milliseconds(200), grace: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.signal == SIGKILL)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func childStartsWithEmptyMaskAndDefaultDispositions() async throws {
        // The daemon blocks and ignores signals for its own handlers; a helper must not inherit that.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let result = try await sh("grep -E '^(SigBlk|SigIgn)' /proc/self/status")
        var blocked = "", ignored = ""
        for line in result.stdoutText.split(separator: "\n") {
            let parts = line.split(separator: ":")
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if parts[0] == "SigBlk" { blocked = value } else { ignored = value }
        }
        #expect(UInt64(blocked, radix: 16) == 0)
        #expect(UInt64(ignored, radix: 16)! & (1 << 14) == 0)  // SIGTERM is bit 15
    }

    @Test func aGrandchildHoldingThePipesDoesNotStallTheCall() async throws {
        let started = ContinuousClock.now
        let result = try await sh("sleep 3 & echo parent")
        #expect(result.stdoutText == "parent\n")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func missingAndEmptyCommandsThrow() async {
        await #expect(throws: ProcessRunError.notFound("vizier-no-such-tool")) { try await ProcessRunner.run(["vizier-no-such-tool"]) }
        await #expect(throws: ProcessRunError.emptyCommand) { try await ProcessRunner.run([]) }
    }

    @Test func detachedHelperReceivesStdinAndItsServerOutlivesTheCall() async throws {
        let bins = FakeBins()
        // Forks a server that keeps running and exits at once, like wl-copy and xclip.
        bins.add("serve", body: "(sleep 2 &) ; exit 0")
        let started = ContinuousClock.now
        let result = try await ProcessRunner.spawnDetached(["serve"], stdin: Data("clip text".utf8), environment: bins.environment())
        #expect(result.inputDelivered)
        #expect(result.exitCode == 0)
        #expect(ContinuousClock.now - started < .seconds(1.5))
        #expect(bins.stdin("serve") == "clip text")
    }

    @Test func detachedHelperStillRunningAfterTheSettleWindowIsReportedRunning() async throws {
        let bins = FakeBins()
        bins.add("fg", body: "sleep 5", reads: false)
        let result = try await ProcessRunner.spawnDetached(["fg"], environment: bins.environment(), settle: .milliseconds(200))
        #expect(result.stillRunning)
        kill(result.pid, SIGKILL)
    }

    @Test func detachedHelperWritesNothingToTheCallersPipes() async throws {
        // stdout and stderr are /dev/null: a helper that chatters cannot hold anything open or fail on SIGPIPE.
        let bins = FakeBins()
        bins.add("chatty", body: "echo noise; echo noise >&2; exit 0")
        let result = try await ProcessRunner.spawnDetached(["chatty"], environment: bins.environment())
        #expect(result.exitCode == 0)
    }

    // MARK: bounded drain, group cleanup, descriptors

    @Test func writersThatNeverStopCannotHoldTheCallPastTheLeaderOrTheDeadline() async throws {
        // Two writers on stdout and one on stderr outlive the leader and keep the pipes full.
        let started = ContinuousClock.now
        let result = try await sh("yes out & yes alsoout & yes err >&2 & sleep 0.3; echo leader-done", timeout: .seconds(8))
        #expect(!result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count > 1000)
        #expect(!result.stderr.isEmpty)
        // A leader that itself never stops writing, with three more writers beside it, still meets its deadline.
        let loud = ContinuousClock.now
        let timed = try await sh("yes a & yes b & yes c >&2 & exec yes d", timeout: .milliseconds(300), grace: .milliseconds(300), limit: 1 << 16)
        #expect(timed.timedOut)
        #expect(ContinuousClock.now - loud < .seconds(1.5))
    }

    @Test func aDescendantThatIgnoresTERMIsKilledEvenWhenTheLeaderObeyedIt() async throws {
        let marker = NSTemporaryDirectory() + "vizier-stubborn-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let started = ContinuousClock.now
        // The inner sh ignores TERM and execs sleep, which keeps ignoring it; the leader waits and dies of TERM.
        let result = try await sh("sh -c 'trap \"\" TERM; echo $$ > \(marker); exec sleep 60' & while [ ! -s \(marker) ]; do sleep 0.05; done; wait", timeout: .milliseconds(400), grace: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.signal == SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
        let pid = pid_t(try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        var alive = true
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { alive = false; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(alive == false)
    }

    @Test func aDescriptorWithoutCloseOnExecIsNotInheritedByTheHelper() async throws {
        let descriptor = open("/dev/null", O_RDONLY)  // deliberately not O_CLOEXEC
        precondition(descriptor > 2)
        defer { close(descriptor) }
        let result = try await sh("if [ -e /proc/$$/fd/\(descriptor) ]; then echo inherited; else echo closed; fi")
        #expect(result.stdoutText == "closed\n")
    }

    // MARK: runSync

    @Test func runSyncRunsOnTheCallersThreadAndPutsItsSignalMaskBack() async throws {
        let outcome = try await offThePool { () -> (ProcessResult, Bool, Bool, ProcessResult) in
            var pipeSignal = sigset_t()
            sigemptyset(&pipeSignal)
            sigaddset(&pipeSignal, SIGPIPE)
            pthread_sigmask(SIG_UNBLOCK, &pipeSignal, nil)
            let echoed = try ProcessRunner.runSync(["/bin/sh", "-c", "cat; echo err >&2; exit 4"], stdin: Data("in\n".utf8))
            // A helper that closes its stdin and stays a while: writing to it raises SIGPIPE on this thread.
            let unread = try ProcessRunner.runSync(["/bin/sh", "-c", "exec 0<&-; sleep 0.3"], stdin: Data(repeating: 0x61, count: 1 << 20))
            var mask = sigset_t()
            pthread_sigmask(SIG_SETMASK, nil, &mask)
            var pending = sigset_t()
            sigpending(&pending)
            return (echoed, sigismember(&mask, SIGPIPE) == 1, sigismember(&pending, SIGPIPE) == 1, unread)
        }
        let (echoed, stillBlocked, stillPending, unread) = outcome
        #expect(echoed.stdoutText == "in\n" && echoed.stderrText == "err\n" && echoed.exitCode == 4)
        #expect(unread.exitCode == 0)
        #expect(!stillBlocked, "runSync left SIGPIPE blocked on its caller's thread")
        #expect(!stillPending, "runSync left a SIGPIPE pending")
        #expect(throws: ProcessRunError.notFound("vizier-no-such-tool")) { try ProcessRunner.runSync(["vizier-no-such-tool"]) }
        #expect(throws: ProcessRunError.emptyCommand) { try ProcessRunner.runSync([]) }
    }
}

import Foundation
import Glibc
import CPipe2
import Synchronization

// The one way the Linux side runs a helper.
//
// Argv only, never a shell. The child is started with posix_spawn, an empty signal mask, default
// signal dispositions and a process group of its own. Foundation's `Process` does not do that on
// Linux (Swift 6.4): its children inherit the calling thread's blocked signals, so a helper never
// saw SIGTERM when the daemon blocks signals for its DispatchSource handlers. The approach is the
// same as Sources/VizierEngine/Capture/PipeCapture.swift.

public enum ProcessRunError: Error, CustomStringConvertible, Equatable {
    case emptyCommand
    case notFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .emptyCommand: "the command is empty"
        case .notFound(let name): "\(name) was not found on PATH"
        case .launchFailed(let reason): "the helper did not start: \(reason)"
        }
    }
}

public struct ProcessResult: Sendable, Equatable {
    /// The exit code, or nil when a signal ended the helper.
    public var exitCode: Int32?
    /// The signal that ended the helper, when one did.
    public var signal: Int32?
    public var stdout: Data
    public var stderr: Data
    /// The deadline passed and the helper's group was signalled.
    public var timedOut: Bool
    /// More output arrived than `outputLimit`; the excess was dropped.
    public var truncated: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// What became of a helper started with `spawnDetached`.
public struct DetachedResult: Sendable, Equatable {
    public var pid: Int32
    /// Every byte of the stdin data reached the helper (true when there was none).
    public var inputDelivered: Bool
    /// The exit code, if the helper had exited when the settle window closed.
    public var exitCode: Int32?
    /// The helper was still running when the settle window closed (it is serving; it is left alone).
    public var stillRunning: Bool { exitCode == nil && signal == nil }
    public var signal: Int32?
}

public enum ProcessRunner {
    /// `name` as a path when it has a slash; otherwise the first executable of that name on the PATH of `environment`.
    public static func resolve(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if name.contains("/") { return fm.isExecutableFile(atPath: name) ? name : nil }
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(directory) + "/" + name
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `argv` and returns when it has exited and its output is drained.
    ///
    /// - `stdin`: bytes written to the helper's standard input, which is then closed (for secrets
    ///   and clipboard text, never argv). With nil, standard input is /dev/null.
    /// - `timeout`: after it, the helper's group gets SIGTERM, and SIGKILL after `killGrace`.
    /// - `outputLimit`: each of stdout and stderr keeps at most this many bytes.
    ///
    /// A grandchild that outlives the helper and still holds the pipes does not stall the call:
    /// output is read until the helper has exited, then whatever is already in the pipe.
    public static func run(
        _ argv: [String],
        stdin: Data? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(10),
        killGrace: Duration = .seconds(1),
        outputLimit: Int = 1 << 20
    ) async throws -> ProcessResult {
        guard let name = argv.first else { throw ProcessRunError.emptyCommand }
        guard let executable = resolve(name, environment: environment) else { throw ProcessRunError.notFound(name) }
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try runBlocking(
                        executable, argv, stdin: stdin, environment: environment,
                        timeout: timeout, killGrace: killGrace, outputLimit: outputLimit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "vizier.process-runner"
            thread.start()
        }
    }

    /// Starts a helper that serves after the call (wl-copy, xclip and xsel hold the clipboard until
    /// it is replaced). Its stdout and stderr go to /dev/null, so nothing waits for an EOF that
    /// never comes. `stdin` is written, then closed. Waits up to `settle` for the helper to exit
    /// (most of these fork a server and exit 0 at once); one still running after that is left
    /// running and reaped by a background thread when it ends.
    public static func spawnDetached(
        _ argv: [String],
        stdin: Data? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settle: Duration = .seconds(2)
    ) async throws -> DetachedResult {
        guard let name = argv.first else { throw ProcessRunError.emptyCommand }
        guard let executable = resolve(name, environment: environment) else { throw ProcessRunError.notFound(name) }
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try detachBlocking(executable, argv, stdin: stdin, environment: environment, settle: settle))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "vizier.process-detach"
            thread.start()
        }
    }

    // MARK: - run

    private static func runBlocking(
        _ executable: String, _ argv: [String], stdin: Data?, environment: [String: String],
        timeout: Duration, killGrace: Duration, outputLimit: Int
    ) throws -> ProcessResult {
        blockSIGPIPE()
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard cpipe2_cloexec(&outPipe) == 0 else { throw ProcessRunError.launchFailed("pipe: \(errnoText(errno))") }
        guard cpipe2_cloexec(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ProcessRunError.launchFailed("pipe: \(errnoText(errno))")
        }
        if stdin != nil {
            guard cpipe2_cloexec(&inPipe) == 0 else {
                for descriptor in outPipe + errPipe { close(descriptor) }
                throw ProcessRunError.launchFailed("pipe: \(errnoText(errno))")
            }
        }
        for descriptor in outPipe + errPipe + inPipe where descriptor >= 0 { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        let pid: pid_t
        do {
            pid = try spawn(executable, argv, environment: environment, stdin: inPipe[0], stdout: outPipe[1], stderr: errPipe[1])
        } catch {
            for descriptor in outPipe + errPipe + inPipe where descriptor >= 0 { close(descriptor) }
            throw error
        }
        close(outPipe[1]); close(errPipe[1])
        if inPipe[0] >= 0 { close(inPipe[0]) }
        var inFD = inPipe[1]
        var outFD = outPipe[0]
        var errFD = errPipe[0]
        for descriptor in [outFD, errFD, inFD] where descriptor >= 0 { setNonBlocking(descriptor) }

        var pending = stdin ?? Data()
        if inFD >= 0 && pending.isEmpty { close(inFD); inFD = -1 }
        var out = Data(), err = Data()
        var truncated = false
        var timedOut = false
        var leaderExited = false
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var killAt: ContinuousClock.Instant?
        var sentKill = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Bytes one descriptor may take per loop turn, so a writer that never stops cannot keep
        // the loop from checking the deadline, the leader and stdin.
        let turnBudget = 64 * 1024

        /// Reads at most `budget` bytes; returns how many it took.
        @discardableResult
        func drain(_ descriptor: inout Int32, into data: inout Data, budget: Int) -> Int {
            var taken = 0
            while descriptor >= 0, taken < budget {
                let count = read(descriptor, &buffer, min(buffer.count, budget - taken))
                if count > 0 {
                    taken += Int(count)
                    let room = max(0, outputLimit - data.count)
                    if Int(count) > room { truncated = true }
                    data.append(contentsOf: buffer[0..<min(Int(count), room)])
                } else if count == 0 {
                    close(descriptor); descriptor = -1
                } else if errno == EINTR {
                    continue
                } else {
                    if errno != EAGAIN && errno != EWOULDBLOCK { close(descriptor); descriptor = -1 }
                    break
                }
            }
            return taken
        }

        // What was in each pipe when the leader was seen to have exited; only that much is read after.
        var outLeft = 0, errLeft = 0
        while true {
            let now = clock.now
            if !leaderExited {
                // WNOWAIT: the leader stays a zombie, so its process group id cannot be reused
                // while group cleanup below still signals it.
                if cpipe2_has_exited(pid, 0) != 0 {
                    leaderExited = true
                    outLeft = outFD >= 0 ? max(0, Int(cpipe2_pending(outFD))) : 0
                    errLeft = errFD >= 0 ? max(0, Int(cpipe2_pending(errFD))) : 0
                }
            }
            if !timedOut && !leaderExited && now >= deadline {
                timedOut = true
                _ = kill(-pid, SIGTERM)
                killAt = now + killGrace
            }
            if timedOut, !sentKill, let killAt, now >= killAt {
                // Also when the leader already left: a descendant that ignored SIGTERM dies here.
                sentKill = true
                _ = kill(-pid, SIGKILL)
            }
            if leaderExited {
                // A grandchild that kept the pipes open must not hold this call: take the
                // snapshot and stop.
                outLeft -= drain(&outFD, into: &out, budget: min(outLeft, turnBudget))
                errLeft -= drain(&errFD, into: &err, budget: min(errLeft, turnBudget))
                let drained = (outLeft <= 0 || outFD < 0) && (errLeft <= 0 || errFD < 0)
                if drained && (!timedOut || sentKill) { break }
                if drained { usleep(5_000) }
                continue
            }
            var fds: [pollfd] = []
            if outFD >= 0 { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if errFD >= 0 { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            if inFD >= 0 { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            // Short ticks: exit detection and the deadline are both checked here.
            _ = fds.isEmpty ? usleep(5_000) : poll(&fds, nfds_t(fds.count), 20)
            drain(&outFD, into: &out, budget: turnBudget)
            drain(&errFD, into: &err, budget: turnBudget)
            if inFD >= 0 {
                while !pending.isEmpty {
                    let written = pending.withUnsafeBytes { write(inFD, $0.baseAddress, $0.count) }
                    if written > 0 { pending.removeFirst(written) } else { break }
                    // EAGAIN: wait for the next tick. EPIPE and others: the helper stopped reading.
                }
                if pending.isEmpty || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    close(inFD); inFD = -1
                }
            }
        }
        for descriptor in [outFD, errFD, inFD] where descriptor >= 0 { close(descriptor) }
        // The group has been dealt with; now collect the leader.
        var raw: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
        if reaped != pid { raw = 0 }
        let signaled = (raw & 0x7f) != 0 && (raw & 0x7f) != 0x7f
        return ProcessResult(
            exitCode: signaled ? nil : (raw >> 8) & 0xff,
            signal: signaled ? raw & 0x7f : nil,
            stdout: out, stderr: err, timedOut: timedOut, truncated: truncated)
    }

    // MARK: - detached

    private final class Exit: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let raw = Mutex<Int32?>(nil)
    }

    private static func detachBlocking(
        _ executable: String, _ argv: [String], stdin: Data?, environment: [String: String], settle: Duration
    ) throws -> DetachedResult {
        blockSIGPIPE()
        let devNull = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard devNull >= 0 else { throw ProcessRunError.launchFailed("open /dev/null: \(errnoText(errno))") }
        defer { close(devNull) }
        var inPipe: [Int32] = [-1, -1]
        if stdin != nil {
            guard cpipe2_cloexec(&inPipe) == 0 else { throw ProcessRunError.launchFailed("pipe: \(errnoText(errno))") }
            for descriptor in inPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        }
        let pid: pid_t
        do {
            pid = try spawn(executable, argv, environment: environment, stdin: inPipe[0], stdout: devNull, stderr: devNull)
        } catch {
            for descriptor in inPipe where descriptor >= 0 { close(descriptor) }
            throw error
        }
        if inPipe[0] >= 0 { close(inPipe[0]) }
        let exit = Exit()
        // The reaper: collects the helper whenever it ends, so a server that outlives this call leaves no zombie.
        let reaper = Thread {
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR
            exit.raw.withLock { $0 = result == pid ? raw : 0 }
            exit.semaphore.signal()
        }
        reaper.name = "vizier.process-reaper"
        reaper.start()

        let clock = ContinuousClock()
        let deadline = clock.now + settle
        var delivered = true
        if inPipe[1] >= 0 {
            setNonBlocking(inPipe[1])
            var pending = stdin ?? Data()
            while !pending.isEmpty {
                let written = pending.withUnsafeBytes { write(inPipe[1], $0.baseAddress, $0.count) }
                if written > 0 { pending.removeFirst(written); continue }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK, clock.now < deadline {
                    var fd = pollfd(fd: inPipe[1], events: Int16(POLLOUT), revents: 0)
                    _ = poll(&fd, 1, 20)
                    continue
                }
                delivered = false
                break
            }
            close(inPipe[1])
        }
        let remaining = max(.zero, deadline - clock.now)
        _ = exit.semaphore.wait(timeout: .now() + remaining.seconds)
        let raw = exit.raw.withLock { $0 }
        guard let raw else { return DetachedResult(pid: pid, inputDelivered: delivered, exitCode: nil, signal: nil) }
        let signaled = (raw & 0x7f) != 0 && (raw & 0x7f) != 0x7f
        return DetachedResult(pid: pid, inputDelivered: delivered, exitCode: signaled ? nil : (raw >> 8) & 0xff, signal: signaled ? raw & 0x7f : nil)
    }

    // MARK: - spawn

    /// `stdin` is the read end of a pipe, or a negative number for /dev/null.
    private static func spawn(_ executable: String, _ argv: [String], environment: [String: String], stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin >= 0 {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        // Nothing but 0, 1 and 2 reaches the helper, whatever the daemon left without close-on-exec.
        _ = addCloseFrom(&actions, 3)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t()
        sigemptyset(&none)
        var every = sigset_t()
        sigfillset(&every)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))

        var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for argument in arguments { free(argument) } }
        var variables: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for variable in variables { free(variable) } }
        var pid: pid_t = 0
        var result = posix_spawn(&pid, executable, &actions, &attributes, &arguments, &variables)
        // ETXTBSY: the helper's file is still open for writing somewhere (a package manager
        // finishing, or a concurrent fork holding a write descriptor for a moment). It clears.
        for _ in 0..<20 where result == ETXTBSY {
            usleep(10_000)
            result = posix_spawn(&pid, executable, &actions, &attributes, &arguments, &variables)
        }
        guard result == 0 else { throw ProcessRunError.launchFailed(errnoText(result)) }
        return pid
    }

    private typealias AddCloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32

    /// `posix_spawn_file_actions_addclosefrom_np` (glibc 2.34 and later), looked up at run time so
    /// the binary still loads on an older glibc, where close-on-exec alone has to do. The Swift
    /// Glibc module does not import it and a C shim including <spawn.h> clashes with it.
    private static let addCloseFromSymbol: AddCloseFrom? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "posix_spawn_file_actions_addclosefrom_np") else { return nil }
        return unsafeBitCast(symbol, to: AddCloseFrom.self)
    }()

    private static func addCloseFrom(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>, _ from: Int32) -> Int32 {
        addCloseFromSymbol?(actions, from) ?? ENOSYS
    }

    private static func blockSIGPIPE() {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &set, nil)
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private static func errnoText(_ code: Int32) -> String { String(cString: strerror(code)) }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

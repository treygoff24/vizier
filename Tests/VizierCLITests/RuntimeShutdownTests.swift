import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

/// A secret store whose reads wait (up to `stall`) before answering: a keyring that is stuck on a prompt.
final class StalledSecretStore: SecretStore, @unchecked Sendable {
    private let stall: TimeInterval
    private let lock = NSLock()
    private var reads = 0
    init(stall: TimeInterval) { self.stall = stall }
    var readCount: Int { lock.withLock { reads } }
    func read(_ account: String) throws -> String? {
        lock.withLock { reads += 1 }
        Thread.sleep(forTimeInterval: stall)
        return "test-key"
    }
    func store(_ value: String, account: String) throws {}
}

/// Answers at once and counts the reads: how often the daemon re-reads its keys.
final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func read(_ account: String) throws -> String? { lock.withLock { reads += 1 }; return "test-key" }
    func store(_ value: String, account: String) throws {}
}

/// A hotkey source whose `start` is suspended until the test releases it (a consent dialog the
/// user has not answered). It ignores cancellation, as a portal call waiting on D-Bus does.
@MainActor
final class SuspendedHotkey: HotkeySource, @unchecked Sendable {
    let name = "suspended-hotkey"
    private(set) var startCalled = false
    private(set) var stopCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var toggle: (@MainActor @Sendable () -> Void)?
    /// How long `stop` takes.
    var stopDelay: Duration = .zero

    nonisolated func probe() async -> AdapterProbe { AdapterProbe(name: "suspended-hotkey", available: true, detail: "fake") }

    func start(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) async throws {
        startCalled = true
        toggle = onToggle
        await withCheckedContinuation { gate = $0 }
    }

    func release() { gate?.resume(); gate = nil }
    func stop() async {
        stopCount += 1
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
    }
    func fireToggle() { toggle?() }
}

@Suite(.serialized) @MainActor struct RuntimeShutdownTests {
    private func world() throws -> RuntimeIntegrationTests.World { try RuntimeIntegrationTests.World(RuntimeIntegrationTests()) }

    private func eventually(_ what: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if what() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return what()
    }

    @Test func makeReturnsOnlyAfterCrashRecoveryHasFinished() async throws {
        let world = try world(); defer { world.cleanup() }
        // A take the last run left behind: a recording with no FLAC.
        let month = world.data.appending(path: "Takes/2026-09")
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let id = "2026-09-21T14-13-20.000Z"
        let writer = try WAVWriter(url: month.appending(path: "\(id).\(TakeFiles.recordingExtension)"))
        let samples = [Int16](repeating: 1_000, count: 16_000 * 20)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        _ = try writer.close()

        let control = try await LinuxRuntime.make(world.options)
        // The daemon publishes its socket when `make` returns, so recovery must be over by then.
        #expect(control.session.isReady, "make returned while crash recovery was still running")
        #expect(FileManager.default.fileExists(atPath: month.appending(path: "\(id).flac").path))
        _ = await control.quiesce(until: .now + .seconds(1))
    }

    @Test func aStalledKeyringBlocksNeitherStartupNorTheMainActorAndStatusStillAnswers() async throws {
        let world = try world(); defer { world.cleanup() }
        // A cloud mode, so that starting a take reads the ElevenLabs key.
        try Data("""
        { "mode": "cloud", "modes": [ { "id": "cloud", "name": "Cloud",
            "transcriber": { "engine": "elevenlabs-scribe-batch", "model": "scribe_v2", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000 },
            "remove_fillers": false } ] }
        """.utf8).write(to: world.config.appending(path: "vizier.jsonc"))
        var options = world.options
        let stalled = StalledSecretStore(stall: 4)
        options.secrets = stalled
        options.secretsLoadWait = .milliseconds(200)
        let started = ContinuousClock.now
        let control = try await LinuxRuntime.make(options)
        #expect(started.duration(to: .now) < .seconds(2), "make waited on the stalled keyring")
        let handler = CommandHandler(control: control, config: ConfigStore(directory: world.config), historyURL: world.historyURL, takesRoot: world.takesRoot, environment: world.environment)
        let daemon = Daemon(handler: handler)
        try daemon.start(); try daemon.publish()
        defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }

        // The daemon answers over the socket while the keyring is stuck...
        let before = ContinuousClock.now
        let status = try await world.call("status")
        #expect(status.ok && status.result?["daemon"] == .string("running"))
        // ...and a take starting on the main actor does not wait for the keys (it reads the snapshot).
        let begun = ContinuousClock.now
        _ = try? control.start()
        #expect(begun.duration(to: .now) < .seconds(1), "starting a take blocked the main actor on the keyring")
        #expect(before.duration(to: .now) < .seconds(3))
        _ = try? control.cancel()
        _ = await control.quiesce(until: .now + .seconds(1))
        #expect(stalled.readCount >= 1)
        #expect(control.status().mode == "cloud", "the cloud-mode config was not the one in use")
    }

    @Test func keysChangedAndTheTimerBothRefreshTheSnapshot() async throws {
        let world = try world(); defer { world.cleanup() }
        var options = world.options
        let counting = CountingSecretStore()
        options.secrets = counting
        options.secretsRefreshInterval = .seconds(3_600)
        let control = try await LinuxRuntime.make(options)
        let handler = CommandHandler(control: control, config: ConfigStore(directory: world.config), historyURL: world.historyURL, takesRoot: world.takesRoot, environment: world.environment)
        let afterStart = counting.readCount
        #expect(afterStart >= SecretAccount.allCases.count)
        // `vizier key set|delete` tells the running daemon over the socket.
        let reply = handler.handle(Request(cmd: "keys_changed"))
        #expect(reply.ok && reply.result?["refreshing"] == .bool(true))
        #expect(await eventually { counting.readCount > afterStart }, "keys_changed did not refresh the snapshot")
        // An argument is refused like any other command's.
        #expect(handler.handle(Request(cmd: "keys_changed", args: ["x": .bool(true)])).ok == false)
        _ = await control.quiesce(until: .now + .seconds(1))

        // The timer alone also re-reads.
        var timed = world.options
        let timedStore = CountingSecretStore()
        timed.secrets = timedStore
        timed.secretsRefreshInterval = .milliseconds(100)
        let other = try await LinuxRuntime.make(timed)
        let first = timedStore.readCount
        #expect(await eventually { timedStore.readCount > first }, "the timer did not refresh the snapshot")
        _ = await other.quiesce(until: .now + .seconds(1))
    }

    @Test func shutdownDuringAHotkeyRegistrationStopsTheSourceAndRejectsALateSuccess() async throws {
        let world = try world(); defer { world.cleanup() }
        let hotkey = SuspendedHotkey()
        var options = world.options
        options.hotkey = .source(hotkey)
        let control = try await LinuxRuntime.make(options)
        #expect(await eventually { hotkey.startCalled })

        // The registration is still waiting when the daemon is told to stop.
        _ = await control.quiesce(until: .now + .seconds(2))
        #expect(hotkey.stopCount >= 1, "the pending registration was not stopped at shutdown")
        // The late success must be rejected: the source is stopped again and never reported active.
        let stopsBefore = hotkey.stopCount
        hotkey.release()
        #expect(await eventually { hotkey.stopCount > stopsBefore }, "a late registration success was accepted")
        #expect(!control.hotkeyDetail.contains("active"))
        // A press of the (late) shortcut does not reach the session.
        hotkey.fireToggle()
        #expect(control.status().phase == .idle && control.status().lastEnding == nil)
    }

    @Test func aStalledHotkeyStopOrNotificationServiceDoesNotHoldShutdownPastItsDeadline() async throws {
        let world = try world(); defer { world.cleanup() }
        let hotkey = SuspendedHotkey()
        hotkey.stopDelay = .seconds(4)
        let sink = GatedSink()
        var options = world.options
        options.hotkey = .source(hotkey)
        options.notificationSink = sink
        options.silent = false
        let control = try await LinuxRuntime.make(options)
        #expect(await eventually { hotkey.startCalled })
        hotkey.release()
        #expect(await eventually { control.hotkeyDetail.contains("active") })
        // A take is in progress, and its notification is stuck inside the stalled service.
        _ = try control.start()
        await sink.waitUntilEntered(1)
        // Let the stalled pieces go after 4 s so a broken deadline shows as a slow shutdown, not a hang.
        Task { try? await Task.sleep(for: .seconds(4)); sink.release() }

        let started = ContinuousClock.now
        let complete = await control.quiesce(until: .now + .milliseconds(800))
        #expect(started.duration(to: .now) < .seconds(2.5), "shutdown ran past its deadline: \(started.duration(to: .now))")
        #expect(!complete, "stalled hotkey stop and notification service must report an incomplete shutdown")
    }
}

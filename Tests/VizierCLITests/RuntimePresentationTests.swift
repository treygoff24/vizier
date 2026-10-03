import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

/// Records every notification and the id it was asked to replace; hands out ids 100, 101, ...
final class RecordingSink: NotificationSink, @unchecked Sendable {
    struct Call: Equatable { var notification: DesktopNotification; var replacing: UInt32? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var next: UInt32 = 100
    private let failing: Set<Int>

    /// `failingCalls`: zero-based indexes of the calls that throw.
    init(failingCalls: Set<Int> = []) { failing = failingCalls }

    var calls: [Call] { lock.withLock { recorded } }

    func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32? {
        try lock.withLock {
            recorded.append(Call(notification: notification, replacing: id))
            if failing.contains(recorded.count - 1) { throw NotificationUnavailable() }
            next += 1
            return next - 1
        }
    }
}

/// A sink whose first call waits until `release()` (a stalled notification service).
final class GatedSink: NotificationSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var released = false
    private var shown: [String] = []

    var summaries: [String] { lock.withLock { shown } }
    func release() { lock.withLock { released = true } }
    func waitUntilEntered(_ count: Int) async {
        for _ in 0..<200 {
            if lock.withLock({ entered }) >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32? {
        let first = lock.withLock { entered += 1; return entered == 1 }
        while first && !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(10)) }
        lock.withLock { shown.append(notification.summary) }
        return 1
    }
}

@Suite @MainActor struct RuntimePresentationTests {
    @Test func oneNotificationUpdatesFromRecordingThroughFinalizingToTheOutcome() async {
        let sink = RecordingSink()
        let presentation = LinuxPresentation(sink: sink, modeName: { "Local" })
        // Each update is let through before the next (a fast service); a burst is coalesced, see below.
        presentation.phaseChanged(.arming)
        presentation.begin(destination: "Secret App Name", platform: "LO", level: { 0 }, seconds: { 0 })
        await presentation.drain()
        presentation.phaseChanged(.recording)
        presentation.setLive()
        presentation.setWords([WordLine.Plate("my private dictation", settled: true)])
        presentation.stopped(onTime: 2.5)
        await presentation.drain()
        presentation.phaseChanged(.finalizing)
        presentation.finish(.pasted, remark: "Pasted with xdotool.")
        presentation.phaseChanged(.idle)
        await presentation.drain()
        let calls = sink.calls
        #expect(calls.map(\.notification.summary) == ["Vizier: recording", "Vizier: finalizing", "Vizier: pasted"])
        // Each replaces the one before it: the sink's first id is 100, then 101.
        #expect(calls.map(\.replacing) == [nil, 100, 101])
        #expect(calls[0].notification.body == "Mode: Local" && calls[2].notification.body == "Pasted with xdotool.")
        #expect(calls[0].notification.timeoutMs == 0 && calls[1].notification.timeoutMs == 0 && calls[2].notification.timeoutMs == LinuxPresentation.outcomeTimeoutMs)
        // No transcript text and no destination app in any of them.
        let everything = calls.map { $0.notification.summary + " " + $0.notification.body }.joined(separator: "\n")
        #expect(!everything.contains("private dictation") && !everything.contains("Secret App Name"))
    }

    @Test func aStreamLossAndAReroutePostTheirRemarkAndAFailedNotificationStartsFresh() async {
        let sink = RecordingSink(failingCalls: [1])
        let presentation = LinuxPresentation(sink: sink, modeName: { "Gemini SMART" })
        presentation.begin(destination: "", platform: "GS", level: { 0 }, seconds: { 0 })          // shown, id 100
        await presentation.drain()
        presentation.streamLost(remark: TakeRemarks.streamDroppedRecording)                           // the sink throws here
        await presentation.drain()
        presentation.stopped(onTime: 1)
        await presentation.drain()
        presentation.reroutingToBatch()
        await presentation.drain()
        presentation.finish(.rerouted(.batch), remark: TakeRemarks.streamDropped)
        await presentation.drain()
        let calls = sink.calls
        #expect(calls.count == 5)
        #expect(calls[1].replacing == 100 && calls[1].notification.body == TakeRemarks.streamDroppedRecording)
        #expect(calls[2].replacing == nil, "after a failed notification the next one must not replace a stale id")
        #expect(calls[3].notification.body.hasPrefix("Rerouting to batch."))
        #expect(calls[4].notification.summary == "Vizier: pasted by another route" && calls[4].notification.body == TakeRemarks.streamDropped)
        #expect(calls.dropFirst(3).map(\.replacing) == [101, 102].map(Optional.some))
    }

    @Test func aBurstBehindASlowServiceCollapsesToTheLatestStateAndShutdownAbandonsAStalledOne() async {
        let sink = GatedSink()
        let presentation = LinuxPresentation(sink: sink, modeName: { "Local" })
        presentation.begin(destination: "", platform: "LO", level: { 0 }, seconds: { 0 })   // enters the sink and stalls
        await sink.waitUntilEntered(1)
        presentation.stopped(onTime: 1)                                                       // pending, then replaced
        presentation.reroutingToBatch()                                                       // pending, then replaced
        presentation.finish(.pasted, remark: "Pasted with xdotool.")                          // the latest: wins
        // The service is stalled: a drain with a deadline gives up at it, and says so.
        let started = ContinuousClock.now
        let drained = await presentation.drain(until: .now + .milliseconds(200))
        #expect(!drained)
        #expect(started.duration(to: .now) < .seconds(2), "the drain must return at its deadline, not wait for the service")
        // What was pending was abandoned: after the service wakes, only the first call was ever made.
        sink.release()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(sink.summaries == ["Vizier: recording"])
    }

    @Test func aBurstThatIsNotAbandonedDeliversTheFirstAndTheLatestOnly() async {
        let sink = GatedSink()
        let presentation = LinuxPresentation(sink: sink, modeName: { "Local" })
        presentation.begin(destination: "", platform: "LO", level: { 0 }, seconds: { 0 })
        await sink.waitUntilEntered(1)
        presentation.stopped(onTime: 1)
        presentation.reroutingToBatch()
        presentation.finish(.pasted, remark: "Pasted with xdotool.")
        sink.release()
        await presentation.drain()
        #expect(sink.summaries == ["Vizier: recording", "Vizier: pasted"])
    }

    @Test func noSinkShowsNothingAndNeverBlocks() async {
        let presentation = LinuxPresentation(sink: nil, modeName: { "Local" })
        presentation.begin(destination: "", platform: "LO", level: { 0 }, seconds: { 0 })
        presentation.finish(.failed, remark: "x")
        await presentation.drain()
    }

    @Test func notifySendIsTheFallbackWhenTheBusIsUnreachable() async throws {
        let bins = FakeBins()
        bins.installScript("notify-send", "echo 77")
        let sink = NotifySendSink(environment: bins.environment())
        let id = try await sink.notify(DesktopNotification(summary: "Vizier: recording", body: "Mode: Local", timeoutMs: 0), replacing: 42)
        #expect(id == 77)
        let argv = try #require(bins.argv("notify-send").first)
        #expect(argv.contains("--replace-id=42") && argv.contains("--print-id") && argv.suffix(2) == ["Vizier: recording", "Mode: Local"])
        // With nothing installed the chain reports it, and the take is unaffected.
        let bare = FakeBins()
        await #expect(throws: NotificationUnavailable.self) {
            _ = try await FallbackNotificationSink([NotifySendSink(environment: bare.environment())]).notify(DesktopNotification(summary: "a", body: "b", timeoutMs: 0), replacing: nil)
        }
    }
}

@Suite @MainActor struct RuntimeSoundsTests {
    private func soundsFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "vizier-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for sound in TakeSound.allCases { try Data("RIFF".utf8).write(to: url.appending(path: "\(sound.rawValue).wav")) }
        return url
    }

    private func waitForCalls(_ bins: FakeBins, _ name: String, count: Int) async -> [[String]] {
        for _ in 0..<100 {
            let calls = bins.argv(name)
            if calls.count >= count { return calls }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return bins.argv(name)
    }

    @Test func aCuePlaysTheMatchingFileWithTheFirstPlayerPresentWithoutBlocking() async throws {
        let folder = try soundsFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let bins = FakeBins()
        bins.add("paplay", body: "sleep 1", reads: false)
        bins.add("aplay", reads: false)
        let sounds = LinuxSounds(environment: bins.environment(), directory: folder)
        #expect(sounds.player == "paplay")  // pw-play is absent, paplay outranks aplay
        let started = ContinuousClock.now
        sounds.play(.start)
        #expect(started.duration(to: .now) < .milliseconds(200), "play must not wait for the player")
        let calls = await waitForCalls(bins, "paplay", count: 1)
        #expect(calls == [[folder.appending(path: "start.wav").path]])
        #expect(bins.argv("aplay").isEmpty)
        bins.add("pw-play", reads: false)
        let preferred = LinuxSounds(environment: bins.environment(), directory: folder)
        #expect(preferred.player == "pw-play")
        preferred.play(.problem)
        #expect(await waitForCalls(bins, "pw-play", count: 1) == [[folder.appending(path: "problem.wav").path]])
    }

    @Test func switchedOffOrWithoutAPlayerOrFilesItIsSilent() async throws {
        let folder = try soundsFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let bins = FakeBins(); bins.add("paplay", reads: false)
        LinuxSounds(environment: bins.environment(), directory: folder, enabled: false).play(.stop)
        let none = FakeBins()
        LinuxSounds(environment: none.environment(), directory: folder).play(.stop)
        let empty = URL(fileURLWithPath: NSTemporaryDirectory() + "vizier-nosounds-\(UUID().uuidString)")
        LinuxSounds(environment: bins.environment(), directory: empty).play(.cancel)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(bins.argv("paplay").isEmpty)
        #expect(LinuxRuntime.soundsEnabled(environment: ["VIZIER_SOUNDS": "off"]) == false)
        #expect(LinuxRuntime.soundsEnabled(environment: [:]) == true)
    }

    @Test func soundsAreFoundNextToTheBinaryThenInTheDataDirsThenTheRepoFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "vizier-locate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ path: String) throws -> URL {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(to: url.appending(path: "start.wav"))
            return url
        }
        let binary = root.appending(path: "prefix/bin/vizier")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let env = ["XDG_DATA_HOME": root.appending(path: "home").path, "XDG_DATA_DIRS": root.appending(path: "dirs").path]
        #expect(LinuxSounds.locate(environment: env, executable: binary) == nil)
        let repo = try put("prefix/Resources/Sounds")
        #expect(LinuxSounds.locate(environment: env, executable: binary)?.standardizedFileURL.path == repo.standardizedFileURL.path)
        let dirs = try put("dirs/vizier/sounds")
        #expect(LinuxSounds.locate(environment: env, executable: binary)?.standardizedFileURL.path == dirs.standardizedFileURL.path)
        let share = try put("prefix/share/vizier/sounds")
        #expect(LinuxSounds.locate(environment: env, executable: binary)?.standardizedFileURL.path == share.standardizedFileURL.path)
    }
}

@Suite @MainActor struct RuntimeCompositionTests {
    @Test func theRecorderIsPwRecordThenParecThenTheExplicitOrEnvironmentOverride() {
        let both = FakeBins(); both.add("pw-record"); both.add("parec")
        #expect(LinuxRuntime.recorderCommand(environment: both.environment()) == PipeCapture.defaultCommand)
        let onlyParec = FakeBins(); onlyParec.add("parec")
        #expect(LinuxRuntime.recorderCommand(environment: onlyParec.environment()).first == "parec")
        #expect(LinuxRuntime.recorderCommand(environment: onlyParec.environment()).contains("--format=s16le"))
        #expect(LinuxRuntime.recorderCommand(environment: both.environment(["VIZIER_RECORDER_COMMAND": "my-rec --raw -"])) == ["my-rec", "--raw", "-"])
        #expect(LinuxRuntime.recorderCommand(environment: both.environment(), explicit: ["/x/rec"]) == ["/x/rec"])
        #expect(LinuxRuntime.recorderCommand(environment: FakeBins().environment()) == PipeCapture.defaultCommand)
    }

    @Test func theMicIsNeverDeniedAndTheFocusProbeReportsTheLatestReaderAnswer() async {
        #expect(LinuxMicPermission().microphoneDenied() == false)
        let probe = LinuxFocusProbe(reader: FixedFocusReader(window: FocusedWindow(appName: "kate", pid: 4242, isTerminal: false)))
        _ = probe.destinationName()               // the first call starts the refresh
        try? await Task.sleep(for: .milliseconds(100))
        #expect(probe.destinationName() == "kate" && probe.focusedProcess() == 4242)
    }
}

/// A reader whose answer the test changes between calls.
final class SwitchableFocusReader: FocusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var current: FocusedWindow?
    init(_ window: FocusedWindow?) { current = window }
    func switchTo(_ window: FocusedWindow?) { lock.withLock { current = window } }
    func focusedWindow() async -> FocusedWindow? { lock.withLock { current } }
}

@MainActor
@Suite struct RuntimeFocusAtStopTests {
    private func window(_ name: String, _ pid: Int32) -> FocusedWindow { FocusedWindow(appName: name, pid: pid, isTerminal: false) }

    @Test func theStopReadsTheDesktopAfreshNotTheCacheTheLastPollLeft() async {
        let reader = SwitchableFocusReader(window("kate", 100))
        let probe = LinuxFocusProbe(reader: reader)
        _ = probe.destinationName()                      // starts the refresh: the cache will say kate (100)
        let deadline = ContinuousClock.now + .seconds(5)  // a loaded machine can take a while to run it
        while probe.focusedProcess() != 100, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.focusedProcess() == 100)           // the cache says A (precondition)
        reader.switchTo(window("firefox", 200))          // the user switches to B and stops before the next poll
        let pid = await probe.focusAtStop()
        #expect(pid == 200, "the stop must see B, not the cached A")
    }

    @Test func anEmptyCacheStillGetsAFreshRead() async {
        let probe = LinuxFocusProbe(reader: SwitchableFocusReader(window("kate", 4242)))
        #expect(await probe.focusAtStop() == 4242)
        // And a desktop that cannot say gives nil, not a stale answer.
        let blind = LinuxFocusProbe(reader: SwitchableFocusReader(nil))
        #expect(await blind.focusAtStop() == nil)
    }
}

struct FixedFocusReader: FocusReader {
    var window: FocusedWindow?
    func focusedWindow() async -> FocusedWindow? { window }
}

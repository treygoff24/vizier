#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import VizierEngine

@Suite struct TakeStoreTests {
    private let store: TakeStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vizier-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TakeStore(root: root)
    }

    #if canImport(AVFoundation)
    /// A take recorded the way TakeRecorder records it: 16 kHz Int16 mono, closed.
    private func record(_ take: TakeFiles, frames: Int) throws -> [Int16] {
        let file = try AVAudioFile(forWriting: take.recording, settings: TakeStore.recordingSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: HALCapture.outputFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var samples: [Int16] = []
        for i in 0..<frames {
            // A 440 Hz tone with a little deterministic noise, so FLAC has real work to do.
            let value = Int16(8_000 * sin(Double(i) * 2 * .pi * 440 / 16_000)) &+ Int16(truncatingIfNeeded: (i &* 7919) % 97)
            buffer.int16ChannelData![0][i] = value
            samples.append(value)
        }
        try file.write(from: buffer)
        file.close()
        return samples
    }

    private func read(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
    #endif

    #if !canImport(AVFoundation)
    /// The same take on Linux: a 16 kHz Int16 mono WAV, closed, as `TakeRecorder` leaves it.
    private func record(_ take: TakeFiles, frames: Int) throws -> [Int16] {
        let samples = Self.tone(frames)
        let writer = try WAVWriter(url: take.recording)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.close()
        return samples
    }

    /// The FLAC's samples as an independent decoder (ffmpeg) reads them; nil when ffmpeg is absent
    /// and not required. CI sets VIZIER_REQUIRE_FFMPEG (plan A9).
    private func decode(_ flac: URL) throws -> [Int16]? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = paths.map { $0 + "/ffmpeg" } + [NSHomeDirectory() + "/.local/bin/ffmpeg"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            #expect(ProcessInfo.processInfo.environment["VIZIER_REQUIRE_FFMPEG"] == nil, "ffmpeg is required here and absent")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-v", "error", "-i", flac.path, "-f", "s16le", "-ac", "1", "-ar", "16000", "-"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "ffmpeg decodes \(flac.lastPathComponent)")
        return stride(from: 0, to: data.count - data.count % 2, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }
    #endif

    private static func tone(_ frames: Int) -> [Int16] {
        // A 440 Hz tone with a little deterministic noise, so FLAC has real work to do.
        (0..<frames).map { i in Int16(8_000 * sin(Double(i) * 2 * .pi * 440 / 16_000)) &+ Int16(truncatingIfNeeded: (i &* 7919) % 97) }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(stat(url.path, &info) == 0)
        return info.st_mode & 0o777
    }

    @Test func takeIdsAreUTCTimestampsFiledByMonth() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.123)  // 2026-09-21T14:13:20.123Z
        let take = try store.newTake(startedAt: date)
        #expect(take.id == "2026-09-21T14-13-20.123Z")
        #expect(take.directory.lastPathComponent == "2026-09")
        #expect(take.flac.lastPathComponent == "2026-09-21T14-13-20.123Z.flac")
    }

    @Test func recordingsLeftBehindAreFoundOldestFirstAndFinishedTakesAreNot() throws {
        let later = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_100))
        let earlier = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let done = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_200))
        // Placeholder bytes: unfinishedTakes looks at names, not contents.
        try Data("x".utf8).write(to: later.recording)
        try Data("x".utf8).write(to: earlier.recording)
        try Data("x".utf8).write(to: done.flac)
        #expect(store.unfinishedTakes().map(\.id) == [earlier.id, later.id])
    }

    @Test func aTakeFolderIsCreatedPrivateAndNamedByItsMonth() throws {
        let take = try store.files(forID: "2026-09-21T14-13-20.123Z")
        #expect(take.directory == store.root.appending(path: "2026-09", directoryHint: .isDirectory))
        #if os(macOS)
        #expect(take.recording.lastPathComponent == "2026-09-21T14-13-20.123Z.caf")
        #else
        #expect(take.recording.lastPathComponent == "2026-09-21T14-13-20.123Z.wav")
        #endif
        #expect(FileManager.default.fileExists(atPath: take.directory.path))
    }

    @Test func aFailedFinishKeepsTheRecording() throws {
        let take = try store.newTake()
        try Data("not audio".utf8).write(to: take.recording)
        #expect(throws: (any Error).self) { try store.finishAudio(take) }
        #expect(FileManager.default.fileExists(atPath: take.recording.path))
    }

    @Test func unfinishedTakesAreFoundOldestFirst() throws {
        let later = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_100))
        let earlier = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_780_000_000))
        _ = try record(later, frames: 1_600)
        _ = try record(earlier, frames: 1_600)
        let done = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_200))
        _ = try record(done, frames: 1_600)
        try store.finishAudio(done)
        #expect(store.unfinishedTakes().map(\.id) == [earlier.id, later.id])
    }
    #if canImport(AVFoundation)  // Apple's FLAC encoder: its format check and its padding of tiny takes
    @Test func finishingEncodesEveryFrameLosslesslyAndRemovesTheRecording() throws {
        let take = try store.newTake()
        let samples = try record(take, frames: 24_000)
        let flac = try store.finishAudio(take)
        #expect(try AVAudioFile(forReading: flac).fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
        #expect(try read(flac) == samples)
        #expect(!FileManager.default.fileExists(atPath: take.recording.path))
    }

    @Test func aTakeShorterThanOneFLACBlockIsPaddedWithSilence() throws {
        for frames in [0, 1_600, 4_607] {
            let take = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(frames)))
            let samples = try record(take, frames: frames)
            let stored = try read(try store.finishAudio(take))
            #expect(stored.count == 4_608)
            #expect(Array(stored.prefix(frames)) == samples)
            #expect(stored.dropFirst(frames).allSatisfy { $0 == 0 })
        }
    }

    #endif

    #if !canImport(AVFoundation)
    @Test func finishingEncodesEveryFrameLosslesslyAndRemovesTheRecording() throws {
        let take = try store.newTake()
        let samples = try record(take, frames: 24_000)
        let flac = try store.finishAudio(take)
        #expect(FLACInfo.streamInfo(flac)?.totalSamples == 24_000)
        #expect(FLACInfo.streamInfo(flac)?.sampleRate == 16_000)
        if let decoded = try decode(flac) { #expect(decoded == samples) }
        #expect(!FileManager.default.fileExists(atPath: take.recording.path))
        #expect(try mode(flac) == 0o600)
    }

    /// Unlike Apple's encoder, ours needs no padding: a short take is stored exactly.
    @Test func shortTakesAreStoredExactlyNotPadded() throws {
        for frames in [0, 1, 1_600, 4_095, 4_096, 4_097, 4_607, 4_608, 12_289] {
            let take = try store.newTake(startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(frames)))
            let samples = try record(take, frames: frames)
            let flac = try store.finishAudio(take)
            #expect(FLACInfo.streamInfo(flac)?.totalSamples == Int64(frames), "\(frames) frames")
            if frames > 0, let decoded = try decode(flac) { #expect(decoded == samples, "\(frames) frames") }
        }
    }

    @Test func aFailedFinishKeepsTheRecordingAndLeavesNoUnverifiedFLAC() throws {
        let take = try store.newTake()
        try Data("not audio".utf8).write(to: take.recording)
        try Data("an earlier half-written flac".utf8).write(to: take.flac)
        #expect(throws: (any Error).self) { try store.finishAudio(take) }
        #expect(FileManager.default.fileExists(atPath: take.recording.path))
        #expect(!FileManager.default.fileExists(atPath: take.flac.path))
    }

    @Test func aFLACThatHoldsFewerFramesThanTheRecordingIsRefusedAndTheRecordingKept() throws {
        let take = try store.newTake()
        let samples = try record(take, frames: 10_000)
        let half = { (wav: URL, flac: URL) throws -> Int64 in
            try FLACEncoder.encode(Array(try WAVFile.samples(wav).prefix(5_000)), sampleRate: 16_000, to: flac)
        }
        #expect(throws: TakeStoreError.self) { try store.finishAudio(take, encoder: half) }
        #expect(try WAVFile.samples(take.recording) == samples, "the recording is untouched")
        #expect(!FileManager.default.fileExists(atPath: take.flac.path), "the unverified FLAC is gone")
        // The same take then finishes properly.
        #expect(FLACInfo.streamInfo(try store.finishAudio(take))?.totalSamples == 10_000)
    }

    @Test func theFinishedFLACIsPrivateAndNoPartialFileIsLeft() throws {
        // The encoder writes `<id>.flac.partial`, created exclusively at 0600, then renames it;
        // AudioFileTests proves the 0600 creation, this proves the take path keeps it.
        let take = try store.newTake()
        _ = try record(take, frames: 5_000)
        try store.finishAudio(take)
        #expect(try mode(take.flac) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: take.flac.path + ".partial"))
    }

    @Test func aStalePartialFromACrashedEncodeDoesNotBlockTheNextFinish() throws {
        let take = try store.newTake()
        _ = try record(take, frames: 5_000)
        try Data("half an encode".utf8).write(to: URL(fileURLWithPath: take.flac.path + ".partial"))
        #expect(FLACInfo.streamInfo(try store.finishAudio(take))?.totalSamples == 5_000)
    }

    @Test func aSurvivingRecordingOutranksAFLACThatWasNeverVerified() throws {
        let take = try store.newTake()
        let samples = try record(take, frames: 8_000)
        try Data("fLaC but cut short".utf8).write(to: take.flac)
        #expect(store.unfinishedTakes().map(\.id) == [take.id], "the recording is still the take's audio")
        let flac = try store.finishAudio(take)
        if let decoded = try decode(flac) { #expect(decoded == samples) }
        #expect(store.unfinishedTakes().isEmpty)
    }

    @Test func importingAWAVEncodesItAndLeavesTheSourceAlone() throws {
        let take = try store.newTake()
        let source = store.root.appending(path: "other-app.wav")
        let samples = Self.tone(5_000)
        let writer = try WAVWriter(url: source)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.close()
        #expect(try store.importAudio(from: source, to: take) == 5_000)
        if let decoded = try decode(take.flac) { #expect(decoded == samples) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try mode(take.flac) == 0o600)
    }

    @Test func durationComesFromTheFLACHeaderOrTheWAVLength() throws {
        let take = try store.newTake()
        _ = try record(take, frames: 24_000)
        #expect(TakeStore.duration(of: take.recording) == 1.5)
        let flac = try store.finishAudio(take)
        #expect(TakeStore.duration(of: flac) == 1.5)
        let junk = store.root.appending(path: "junk.flac")
        try Data("nope".utf8).write(to: junk)
        #expect(TakeStore.duration(of: junk) == nil)
        #expect(TakeStore.duration(of: store.root.appending(path: "missing.flac")) == nil)
    }

    /// The writer, in a child process of this test runner (`--filter` of the test below, with the
    /// environment variable set). It appends synthetic audio until the parent kills it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIZIER_CRASH_CHILD_WAV"] != nil, "only runs as the crash test's child"))
    func crashChildWritesUntilKilled() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VIZIER_CRASH_CHILD_WAV"])
        let writer = try WAVWriter(url: URL(fileURLWithPath: path))
        var index = 0
        while true {
            let block = (index..<index + 1_600).map(Self.crashSample)
            try block.withUnsafeBufferPointer { try writer.append($0) }
            index += 1_600
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private static func crashSample(_ index: Int) -> Int16 { Int16(truncatingIfNeeded: (index &* 2_654_435_761) >> 7) }

    @Test func aTakeWhoseRecorderWasKilledMidWriteIsRecoveredByTheNextLaunch() throws {
        let take = try store.newTake()
        let runner = CommandLine.arguments[0]
        try #require(FileManager.default.isExecutableFile(atPath: runner), "the test runner can start itself: \(runner)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: runner)
        child.arguments = ["--testing-library", "swift-testing", "--filter", "crashChildWritesUntilKilled"]
        child.environment = ProcessInfo.processInfo.environment.merging(["VIZIER_CRASH_CHILD_WAV": take.recording.path]) { $1 }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        // A failed precondition below must not leave an endless writer behind.
        defer {
            if child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                child.waitUntilExit()
            }
        }
        // Let it get well into the take, then kill it with no chance to patch the header or close.
        let deadline = Date().addingTimeInterval(30)
        func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: take.recording.path)[.size] as? Int) ?? 0 }
        while size() < 44 + 2 * 16_000, child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(child.isRunning, "the child was still writing when it was killed (precondition)")
        try #require(size() >= 44 + 2 * 16_000, "the child wrote at least a second (precondition)")
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)

        // The header was never patched, so this is what a crash leaves.
        let header = try Data(contentsOf: take.recording).prefix(44)
        #expect(header[40..<44].allSatisfy { $0 == 0 }, "data size still the placeholder")

        // The next launch finds the take and finishes it.
        #expect(store.unfinishedTakes().map(\.id) == [take.id])
        let onDisk = (size() - 44) / 2
        let flac = try store.finishAudio(take)
        #expect(FLACInfo.streamInfo(flac)?.totalSamples == Int64(onDisk), "every whole sample on disk is in the FLAC")
        if let decoded = try decode(flac) {
            #expect(decoded == (0..<onDisk).map(Self.crashSample), "and they are the samples the child wrote, in order")
        }
        #expect(!FileManager.default.fileExists(atPath: take.recording.path))
        #expect(store.unfinishedTakes().isEmpty)
    }
    #endif
}

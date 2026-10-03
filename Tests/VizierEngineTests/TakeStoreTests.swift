import AVFoundation
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

    @Test func takeIdsAreUTCTimestampsFiledByMonth() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.123)  // 2026-09-21T14:13:20.123Z
        let take = try store.newTake(startedAt: date)
        #expect(take.id == "2026-09-21T14-13-20.123Z")
        #expect(take.directory.lastPathComponent == "2026-09")
        #expect(take.flac.lastPathComponent == "2026-09-21T14-13-20.123Z.flac")
    }

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
}

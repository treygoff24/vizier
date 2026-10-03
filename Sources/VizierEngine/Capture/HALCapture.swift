#if canImport(AudioToolbox)
// Adapted from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift
// VoiceInk is licensed under the GNU General Public License v3.0.
// Modified 2026-09/10 by Trey Goff.
//
// Kept from upstream: the AUHAL input unit that captures without changing the system default;
// a Float32 callback format at the device's own rate with the device's preferred input channels
// mapped in; a realtime-safe render callback into pre-allocated memory; a ring of input slots
// drained on a processing queue; switching devices in place without closing the take.
// Changed for Vizier: resampling to 16 kHz uses AVAudioConverter (upstream interpolated each
// buffer on its own and dropped part of a sample at every buffer edge); atomics come from the
// standard Synchronization module; capture follows the system default input and switches when it
// changes (debounced); samples go to a sink instead of a WAV file;
// the first buffer with any nonzero sample is reported, because a blocked or dead input delivers
// exact digital silence.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import os

public enum CaptureError: Error, CustomStringConvertible {
    case alreadyRunning
    case noInputDevice
    case coreAudio(String, OSStatus)
    case converter

    public var description: String {
        switch self {
        case .alreadyRunning: "capture is already running"
        case .noInputDevice: "no default input device"
        case .coreAudio(let step, let status): "\(step) failed (OSStatus \(status))"
        case .converter: "could not build the 16 kHz converter"
        }
    }
}

public final class HALCapture: @unchecked Sendable {
    public typealias Event = CaptureEvent
    public typealias Stats = CaptureStats

    /// 16 kHz mono signed 16-bit, the format every take is stored and streamed in.
    public static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// Receives converted audio on the processing queue. The buffer is reused after the call returns.
    public typealias Sink = (AVAudioPCMBuffer) -> Void

    private final class Slot {
        let samples: UnsafeMutablePointer<Float32>
        var frameCount: UInt32 = 0
        var channelCount: UInt32 = 0
        init(capacity: Int) { samples = .allocate(capacity: capacity) }
        deinit { samples.deallocate() }
    }

    private let log = Logger(subsystem: "net.praxient.dictum", category: "capture")
    private let controlQueue = DispatchQueue(label: "net.praxient.dictum.capture.control")
    private let processingQueue = DispatchQueue(label: "net.praxient.dictum.capture.processing", qos: .userInteractive)

    // Read by the render thread. Changed only while the unit is stopped and no callback is running.
    private var audioUnit: AudioUnit?
    private var deviceID = AudioDeviceID(0)
    private var channelCount: UInt32 = 1
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderCapacitySamples: UInt32 = 0
    private var slots: [Slot] = []
    private let slotCount = 96
    private let minFramesPerRender: UInt32 = 4096
    /// Whether `audioUnit` is initialized. Control queue.
    private var initialized = false
    /// The rate the idle, prepared unit was configured for; 0 when none is prepared.
    private var preparedRate: Double = 0

    private let active = Atomic<Bool>(false)
    private let callbacksInFlight = Atomic<Int>(0)
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    private let processingScheduled = Atomic<Bool>(false)
    private let dropped = Atomic<UInt64>(0)
    private let meanSquareBits = Atomic<UInt32>(0)

    // Processing-queue state.
    private var converter: AVAudioConverter?
    private var monoBuffer: AVAudioPCMBuffer?
    private var outBuffer: AVAudioPCMBuffer?
    private var sink: Sink?
    private var signalSeen = false

    // Control-queue state.
    private var running = false
    private var switches = 0
    private var onEvent: (@Sendable (Event) -> Void)?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateListenerDevice = AudioDeviceID(0)
    private var pendingSwitch: DispatchWorkItem?

    public init() {}

    deinit {
        _ = stop()
        controlQueue.sync { teardownUnit() }
    }

    /// Mean square of the latest buffer, for the level meter. Safe from any thread.
    public var meanSquare: Float { Float(bitPattern: meanSquareBits.load(ordering: .relaxed)) }

    /// Starts capturing from the current system default input.
    public func start(sink: @escaping Sink, onEvent: @escaping @Sendable (Event) -> Void) throws {
        try controlQueue.sync {
            guard !running else { throw CaptureError.alreadyRunning }
            let device = try Self.defaultInputDevice()
            self.onEvent = onEvent
            processingQueue.sync {
                self.sink = sink
                self.signalSeen = false
            }
            meanSquareBits.store(0, ordering: .relaxed)
            dropped.store(0, ordering: .relaxed)
            // A unit prepared for another device or rate is stale; build fresh.
            if audioUnit != nil, deviceID != device || preparedRate != Self.nominalRate(device: device) {
                teardownUnit()
            }
            let wasPrepared = audioUnit != nil
            do {
                if audioUnit == nil {
                    try createUnit()
                    try configure(device: device)
                }
                try run(device: device)
            } catch where wasPrepared {
                log.error("prepared capture unit failed to start: \(String(describing: error), privacy: .private); building a fresh one")
                teardownUnit()
                do {
                    try createUnit()
                    try configure(device: device)
                    try run(device: device)
                } catch {
                    teardownUnit()
                    throw error
                }
            } catch {
                teardownUnit()
                throw error
            }
            preparedRate = 0
            watchSampleRate(of: device)
            running = true
            switches = 0
            installDefaultDeviceListener()
        }
    }

    /// Stops capture after delivering every buffered sample, including the converter's tail.
    @discardableResult
    public func stop() -> Stats {
        controlQueue.sync {
            guard running else { return Stats() }
            running = false
            pendingSwitch?.cancel()
            pendingSwitch = nil
            removeListeners()
            haltAndDrain()
            teardownUnit()
            processingQueue.sync { sink = nil }
            onEvent = nil
            meanSquareBits.store(0, ordering: .relaxed)
            // Queued after this call returns, so stopping is not delayed; the next take finds a unit ready.
            controlQueue.async { [weak self] in self?.prepareIfIdle() }
            return Stats(deviceSwitches: switches, droppedBuffers: dropped.exchange(0, ordering: .relaxed))
        }
    }

    /// Builds and initializes a unit for the default input without starting it, so the next
    /// `start` only has to start device IO. The first unit in a process costs about 200 ms more
    /// than later ones; this moves that cost off the first take. Captures nothing and does not
    /// start the device. Runs on the control queue, so a `start` issued meanwhile waits for it
    /// and then uses the prepared unit. Failures only log; `start` builds its own unit then.
    public func prepare() {
        controlQueue.async { [weak self] in self?.prepareIfIdle() }
    }

    private func prepareIfIdle() {
        guard !running, audioUnit == nil else { return }
        do {
            let device = try Self.defaultInputDevice()
            try createUnit()
            try configure(device: device)
            try check(AudioUnitInitialize(audioUnit!), "initialize unit")
            initialized = true
            preparedRate = Self.nominalRate(device: device)
            // Nothing runs while idle, so a rate change is caught by `start`'s staleness check.
            removeRateListener()
        } catch {
            log.error("could not prepare capture: \(String(describing: error), privacy: .private)")
            teardownUnit()
        }
    }

    // MARK: - Unit lifecycle (control queue)

    private func createUnit() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.coreAudio("find HAL output unit", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "create unit")
        guard let unit else { throw CaptureError.coreAudio("create unit", -1) }
        audioUnit = unit

        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)), "disable output")

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
    }

    /// Points the stopped, uninitialized unit at `device` and sizes everything for its format.
    private func configure(device: AudioDeviceID) throws {
        guard let unit = audioUnit else { throw CaptureError.coreAudio("configure", -1) }
        var id = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size), "read device format")

        let channels = Self.inputChannels(device: device, count: deviceFormat.mChannelsPerFrame)
        guard !channels.isEmpty, deviceFormat.mSampleRate > 0 else { throw CaptureError.coreAudio("device has no input channels", -1) }
        let channelCount = UInt32(channels.count)
        let rate = deviceFormat.mSampleRate

        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &callbackFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set callback format")
        var channelMap = channels
        try channelMap.withUnsafeMutableBytes { bytes in
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, bytes.baseAddress, UInt32(bytes.count)), "set channel map")
        }

        let maxFrames = max(minFramesPerRender, Self.bufferFrameSize(device: device) ?? 0)
        let capacity = maxFrames * channelCount
        if capacity > renderCapacitySamples {
            renderBuffer?.deallocate()
            renderBuffer = .allocate(capacity: Int(capacity))
            renderCapacitySamples = capacity
            slots = (0..<slotCount).map { _ in Slot(capacity: Int(capacity)) }
        }
        self.channelCount = channelCount
        self.deviceID = device

        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: Self.outputFormat),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: maxFrames),
              let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: AVAudioFrameCount(Double(maxFrames) * 16_000 / rate) + 64)
        else { throw CaptureError.converter }
        processingQueue.sync {
            self.converter = converter
            self.monoBuffer = mono
            self.outBuffer = out
        }
        log.notice("input \(Self.deviceName(device) ?? "unknown", privacy: .private): \(Int(rate), privacy: .public) Hz, channels \(channels.map { $0 + 1 }, privacy: .public)")
        watchSampleRate(of: device)
    }

    private func run(device: AudioDeviceID) throws {
        guard let unit = audioUnit else { throw CaptureError.coreAudio("start", -1) }
        if !initialized {
            try check(AudioUnitInitialize(unit), "initialize unit")
            initialized = true
        }
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        processingScheduled.store(false, ordering: .relaxed)
        active.store(true, ordering: .releasing)
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            active.store(false, ordering: .releasing)
            AudioUnitUninitialize(unit)
            initialized = false
            throw CaptureError.coreAudio("start unit", status)
        }
    }

    /// Stops the unit, waits out the render thread, and hands every queued sample to the sink,
    /// flushing the converter so the resampler's tail is not lost.
    private func haltAndDrain() {
        active.store(false, ordering: .releasing)
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
        }
        while callbacksInFlight.load(ordering: .acquiring) > 0 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        processingQueue.sync {
            processQueued()
            if let converter, let out = outBuffer {
                convert(converter, input: nil, into: out, endOfStream: true)
            }
        }
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
        }
        initialized = false
    }

    private func teardownUnit() {
        if let unit = audioUnit {
            active.store(false, ordering: .releasing)
            AudioOutputUnitStop(unit)
            while callbacksInFlight.load(ordering: .acquiring) > 0 {
                Thread.sleep(forTimeInterval: 0.001)
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        initialized = false
        preparedRate = 0
        processingQueue.sync {
            converter = nil
            monoBuffer = nil
            outBuffer = nil
        }
        slots = []
        renderBuffer?.deallocate()
        renderBuffer = nil
        renderCapacitySamples = 0
        deviceID = 0
    }

    // MARK: - Following the default input (control queue)

    private func installDefaultDeviceListener() {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSwitch(reason: "default input changed") }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block) == noErr {
            defaultListener = block
        }
    }

    private func watchSampleRate(of device: AudioDeviceID) {
        removeRateListener()
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleSwitch(reason: "input sample rate changed", force: true) }
        if AudioObjectAddPropertyListenerBlock(device, &address, controlQueue, block) == noErr {
            rateListener = block
            rateListenerDevice = device
        }
    }

    private func removeListeners() {
        if let defaultListener {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, defaultListener)
            self.defaultListener = nil
        }
        removeRateListener()
    }

    private func removeRateListener() {
        if let rateListener {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, controlQueue, rateListener)
            self.rateListener = nil
        }
    }

    /// Device changes arrive in bursts (a new default, then its format), so wait for them to settle.
    private func scheduleSwitch(reason: String, force: Bool = false) {
        pendingSwitch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.switchToDefault(reason: reason, force: force) }
        pendingSwitch = work
        controlQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func switchToDefault(reason: String, force: Bool) {
        guard running else { return }
        guard let target = try? Self.defaultInputDevice() else {
            log.error("\(reason, privacy: .public), but there is no default input now")
            return
        }
        guard force || target != deviceID else { return }
        let previous = deviceID
        log.notice("\(reason, privacy: .public); moving capture to \(Self.deviceName(target) ?? "unknown", privacy: .private)")
        haltAndDrain()
        do {
            try configure(device: target)
            try run(device: target)
            switches += 1
            onEvent?(.deviceSwitched(name: Self.deviceName(target) ?? "unknown"))
        } catch {
            log.error("switch failed: \(String(describing: error), privacy: .private); returning to the previous input")
            onEvent?(.deviceSwitchFailed(String(describing: error)))
            if previous != 0, (try? configure(device: previous)) != nil {
                try? run(device: previous)
            }
        }
    }

    // MARK: - Render thread

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        callbacksInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer { callbacksInFlight.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
        guard active.load(ordering: .acquiring), let unit = audioUnit, let buffer = renderBuffer else { return noErr }
        let samples = frames * channelCount
        guard samples <= renderCapacitySamples else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channelCount, mDataByteSize: samples * 4, mData: buffer))
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        guard status == noErr else { return status }

        let write = writeIndex.load(ordering: .relaxed)
        guard write - readIndex.load(ordering: .acquiring) < UInt64(slots.count) else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }
        let slot = slots[Int(write % UInt64(slots.count))]
        slot.frameCount = frames
        slot.channelCount = channelCount
        slot.samples.update(from: buffer, count: Int(samples))
        writeIndex.store(write + 1, ordering: .releasing)
        if !processingScheduled.exchange(true, ordering: .acquiringAndReleasing) {
            processingQueue.async { [weak self] in self?.processQueued() }
        }
        return noErr
    }

    // MARK: - Processing queue

    private func processQueued() {
        while true {
            let read = readIndex.load(ordering: .relaxed)
            guard read < writeIndex.load(ordering: .acquiring), !slots.isEmpty else {
                processingScheduled.store(false, ordering: .releasing)
                if readIndex.load(ordering: .acquiring) < writeIndex.load(ordering: .acquiring),
                   !processingScheduled.exchange(true, ordering: .acquiringAndReleasing) {
                    processingQueue.async { [weak self] in self?.processQueued() }
                }
                return
            }
            process(slots[Int(read % UInt64(slots.count))])
            readIndex.store(read + 1, ordering: .releasing)
        }
    }

    private func process(_ slot: Slot) {
        guard let converter, let mono = monoBuffer, let out = outBuffer, let dst = mono.floatChannelData?[0] else { return }
        let frames = Int(min(slot.frameCount, mono.frameCapacity))
        let channels = Int(slot.channelCount)
        guard frames > 0, channels > 0 else { return }
        var sumSquares: Float = 0
        var nonzero = false
        for i in 0..<frames {
            var sample: Float = 0
            for c in 0..<channels { sample += slot.samples[i * channels + c] }
            sample /= Float(channels)
            dst[i] = sample
            sumSquares += sample * sample
            if sample != 0 { nonzero = true }
        }
        mono.frameLength = AVAudioFrameCount(frames)
        meanSquareBits.store((sumSquares / Float(frames)).bitPattern, ordering: .relaxed)
        if nonzero, !signalSeen {
            signalSeen = true
            onEvent?(.signal)
        }
        convert(converter, input: mono, into: out, endOfStream: false)
    }

    private final class InputState: @unchecked Sendable {
        var pending: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer?) { pending = buffer }
    }

    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, into out: AVAudioPCMBuffer, endOfStream: Bool) {
        let state = InputState(input)
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let buffer = state.pending {
                    state.pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if out.frameLength > 0 { sink?(out) }
            switch status {
            case .haveData: continue
            case .error:
                log.error("converter error: \(String(describing: error), privacy: .private)")
                return
            default:
                return
            }
        }
    }

    // MARK: - Core Audio helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    public static func defaultInputDevice() throws -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw CaptureError.noInputDevice }
        return device
    }

    public static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func nominalRate(device: AudioDeviceID) -> Double {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : -1
    }

    private static func bufferFrameSize(device: AudioDeviceID) -> UInt32? {
        var address = address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr ? frames : nil
    }

    /// Zero-based device channels to capture: the device's preferred stereo pair when it names a
    /// valid one, otherwise its first one or two channels (upstream AudioInputChannelSelection).
    private static func inputChannels(device: AudioDeviceID, count: UInt32) -> [Int32] {
        guard count > 0 else { return [] }
        let fallback = (0..<min(count, 2)).map(Int32.init)
        var address = address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(device, &address) else { return fallback }
        var pair: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        let status = pair.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, pair.allSatisfy({ (1...count).contains($0) }) else { return fallback }
        var seen = Set<UInt32>()
        return pair.compactMap { seen.insert($0).inserted ? Int32($0 - 1) : nil }
    }
}
#endif

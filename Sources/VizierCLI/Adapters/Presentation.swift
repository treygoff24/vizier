import Foundation
import VizierEngine

/// The daemon's `TakePresentation`: one desktop notification that updates in place from recording
/// through finalizing to the outcome. It says the phase, the mode's name and the take's remark and
/// nothing else, so no transcript text and no destination app reaches the notification server.
/// Updates go through one ordered stream, so a slow notification service never blocks the main
/// actor and the updates never overtake each other.
/// Runs `work` and reports whether it finished by `deadline`. At the deadline the caller goes on
/// and the work is cancelled and left to finish on its own: a structured task group would wait for
/// it, and the point is to stop waiting.
enum Bounded {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) {
            lock.lock(); let taken = continuation; continuation = nil; lock.unlock()
            taken?.resume(returning: value)
        }
    }

    static func run(until deadline: ContinuousClock.Instant, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        if ContinuousClock.now >= deadline { return false }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let job = Task { await work(); once.finish(true) }
            Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                job.cancel()
                once.finish(false)
            }
        }
    }
}

/// The notification queue: one slot, latest state wins. A burst of updates (recording, finalizing,
/// outcome) while the service is slow collapses to the newest one, and nothing can pile up behind
/// a stalled service. One worker delivers; `waitIdle` resolves when nothing is pending or in flight.
final class NotificationPump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: DesktopNotification?
    private var inFlight = false
    private var abandoned = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var id: UInt32?
    private let sink: (any NotificationSink)?

    init(sink: (any NotificationSink)?) { self.sink = sink }

    func post(_ notification: DesktopNotification) {
        guard sink != nil else { return }
        lock.lock()
        if abandoned { lock.unlock(); return }
        pending = notification
        let start = !inFlight
        inFlight = true
        lock.unlock()
        if start { Task.detached { await self.work() } }
    }

    /// The next update to deliver and the id it replaces, or nil (and the waiters released) when
    /// nothing is left. Synchronous, so the lock is never held across a suspension.
    private func next() -> (DesktopNotification, UInt32?)? {
        lock.lock()
        guard !abandoned, let next = pending else {
            inFlight = false
            let done = waiters; waiters = []
            lock.unlock()
            for waiter in done { waiter.resume() }
            return nil
        }
        pending = nil
        let replacing = id
        lock.unlock()
        return (next, replacing)
    }

    private func remember(_ shown: UInt32?) { lock.lock(); id = shown; lock.unlock() }

    private func work() async {
        while let (notification, replacing) = next() {
            // A failed notification is dropped, and the next one starts a fresh one.
            var shown: UInt32?
            do { shown = try await sink?.notify(notification, replacing: replacing) } catch { shown = nil }
            remember(shown)
        }
    }

    func waitIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !inFlight { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Drops what is pending, refuses further posts and releases everyone waiting; an update
    /// already inside the sink is left to finish or time out by itself.
    func abandon() {
        lock.lock()
        abandoned = true
        pending = nil
        let done = waiters; waiters = []
        lock.unlock()
        for waiter in done { waiter.resume() }
    }
}

/// The daemon's `TakePresentation`: one desktop notification that updates in place from recording
/// through finalizing to the outcome. It says the phase, the mode's name and the take's remark and
/// nothing else, so no transcript text and no destination app reaches the notification server.
/// Updates go to a coalescing queue (latest state wins), so a slow notification service never
/// blocks the main actor and the updates never overtake each other.
@MainActor
public final class LinuxPresentation: TakePresentation {
    /// How long an outcome stays up, in milliseconds.
    public static let outcomeTimeoutMs: Int32 = 4_000

    private let pump: NotificationPump
    private let modeName: @MainActor () -> String
    private var mode = ""
    private var finalizing = false
    /// Called with true when a take leaves idle and false when it returns to it.
    public var onActiveChanged: (@MainActor (Bool) -> Void)?

    /// `sink` nil shows nothing. `modeName` supplies the active mode's name when a take begins.
    public init(sink: (any NotificationSink)?, modeName: @escaping @MainActor () -> String) {
        self.modeName = modeName
        pump = NotificationPump(sink: sink)
    }

    /// Waits until every update posted so far has been handed to the sink, or until `deadline`;
    /// at the deadline what is still pending is abandoned. Returns whether it all went out.
    @discardableResult
    public func drain(until deadline: ContinuousClock.Instant? = nil) async -> Bool {
        let pump = pump
        guard let deadline else { await pump.waitIdle(); return true }
        let finished = await Bounded.run(until: deadline) { await pump.waitIdle() }
        if !finished { pump.abandon() }
        return finished
    }

    private func post(_ summary: String, _ body: String, timeoutMs: Int32 = 0) {
        pump.post(DesktopNotification(summary: summary, body: body, timeoutMs: timeoutMs))
    }

    private var modeLine: String { mode.isEmpty ? "" : "Mode: \(mode)" }

    public func phaseChanged(_ phase: TakePhase) {
        if phase == .idle { finalizing = false }
        onActiveChanged?(phase != .idle)
    }

    public func raiseAlert() {}

    public func begin(destination: String, platform: String, level: @escaping @Sendable () -> Float, seconds: @escaping @Sendable () -> Double) {
        mode = modeName()
        finalizing = false
        post("Vizier: recording", modeLine)
    }

    public func setLive() {}
    public func setWords(_ plates: [WordLine.Plate]) {}

    public func streamLost(remark: String) {
        post(finalizing ? "Vizier: finalizing" : "Vizier: recording", remark)
    }

    public func stopped(onTime: TimeInterval) {
        finalizing = true
        post("Vizier: finalizing", modeLine)
    }

    public func reroutingToBatch() {
        post("Vizier: finalizing", "Rerouting to batch. " + modeLine)
    }

    public func finish(_ result: TakeResult, remark: String?) {
        let summary: String
        switch result {
        case .pasted: summary = "Vizier: pasted"
        case .rerouted: summary = "Vizier: pasted by another route"
        case .held: summary = "Vizier: held"
        case .failed: summary = "Vizier: failed"
        case .cancelled: summary = "Vizier: cancelled"
        }
        finalizing = false
        post(summary, remark ?? modeLine, timeoutMs: Self.outcomeTimeoutMs)
    }
}

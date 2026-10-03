#if os(Linux)
import Glibc
import CPipe2
import Foundation
import Synchronization

public enum PipeCaptureError: Error, CustomStringConvertible {
    case alreadyRunning
    case emptyCommand
    case notFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning: "capture is already running"
        case .emptyCommand: "the recorder command is empty"
        case .notFound(let name): "the recorder \(name) was not found on PATH"
        case .launchFailed(let reason): "the recorder did not start: \(reason)"
        }
    }
}

/// Captures by running a recorder command that writes raw 16 kHz mono signed 16-bit little-endian
/// samples to its standard output (PipeWire's `pw-record` by default), and reading that stream.
///
/// The command is an argument list, never a shell line. The recorder is this object's own child, in
/// a process group of its own: `stop()` signals that group and no other process.
///
/// The child is started with an empty signal mask and default signal dispositions. Foundation's
/// `Process` does not do this: on Linux (Swift 6.4) its children inherit the calling thread's
/// blocked signals, so a recorder never saw SIGTERM, and a daemon that ignores SIGTERM for its own
/// signal handling would pass that on through exec.
///
/// Byte boundaries are the stream's, not the samples': a read may end between the two bytes of a
/// sample, so the odd byte is held and joined to the next read. A byte left over at the end of the
/// stream is half a sample; it is dropped and counted in `CaptureStats.droppedBuffers`.
///
/// `stop()` sends SIGTERM, drains what the recorder already wrote, and returns after the last sink
/// call. A recorder that ignores SIGTERM for `terminationGrace` is killed; whatever it wrote before
/// then is delivered. The stop path judges by the bytes received, never by the exit status. Do not
/// call `stop()` from inside the sink or the event handler.
public final class PipeCapture: AudioCapture, @unchecked Sendable {
    public static let defaultCommand = ["pw-record", "--raw", "--rate", "16000", "--channels", "1", "--format", "s16", "-"]

    public let command: [String]
    private let terminationGrace: Duration
    private let level = Atomic<UInt32>(0)

    private final class Run: @unchecked Sendable {
        let pid: pid_t
        let out: Int32
        let err: Int32
        let done = DispatchSemaphore(value: 0)
        let flags = Mutex(Flags())
        var dropped: UInt64 = 0

        struct Flags {
            var stopping = false
            /// Set by `stop()` once the whole group is dead: nothing of the recorder's can be written
            /// after this, so the reader drains what is in the pipe and ends.
            var groupDead = false
            /// Set once `waitpid` has collected the child; its pid must not be signalled after that.
            var collected = false
            var exitStatus: Int32?
        }

        init(pid: pid_t, out: Int32, err: Int32) {
            self.pid = pid
            self.out = out
            self.err = err
        }

        /// Waits until the group leader has terminated, without collecting it, so its pid (and with it
        /// the group id) stays ours to signal. With `timeout` nil, waits as long as it takes. Returns
        /// whether it has terminated.
        func awaitExit(timeout: Duration?) -> Bool {
            guard let timeout else { return cpipe2_has_exited(pid, 1) != 0 }
            let deadline = ContinuousClock.now + timeout
            while true {
                if cpipe2_has_exited(pid, 0) != 0 { return true }
                if ContinuousClock.now >= deadline { return false }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        /// Collects the terminated leader (retrying on EINTR). Returns its raw status; nil if there is
        /// none to give (already collected elsewhere).
        @discardableResult func reap() -> Int32? {
            flags.withLock { flags in
                if flags.collected { return flags.exitStatus }
                while true {
                    var status: Int32 = 0
                    let result = waitpid(pid, &status, 0)
                    if result == pid {
                        flags.collected = true
                        flags.exitStatus = status
                        return status
                    }
                    if result < 0, errno == EINTR { continue }
                    // ECHILD or anything else: there is no child of ours to wait for any more.
                    flags.collected = true
                    return nil
                }
            }
        }

        /// Signals the recorder's whole group while the leader is still uncollected, which keeps the
        /// group id from being reused.
        func signalGroup(_ signal: Int32) {
            flags.withLock { flags in
                if !flags.collected { _ = kill(-pid, signal) }
            }
        }
    }

    private let lock = NSLock()
    private var run: Run?

    public init(command: [String] = PipeCapture.defaultCommand, terminationGrace: Duration = .seconds(3)) {
        self.command = command
        self.terminationGrace = terminationGrace
    }

    public var meanSquare: Float { Float(bitPattern: level.load(ordering: .relaxed)) }

    /// Nothing to ready: the recorder process starts with the take.
    public func prepare() {}

    public func start(sink: @escaping CaptureSink, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard run == nil else { throw PipeCaptureError.alreadyRunning }
        guard let name = command.first else { throw PipeCaptureError.emptyCommand }
        guard let executable = Self.resolve(name) else { throw PipeCaptureError.notFound(name) }

        // Close-on-exec from creation, so no child but the recorder holds an end open (dup2 below
        // clears it on 1 and 2).
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard cpipe2_cloexec(&outPipe) == 0 else { throw PipeCaptureError.launchFailed("pipe2: \(String(cString: strerror(errno)))") }
        guard cpipe2_cloexec(&errPipe) == 0 else {
            let reason = String(cString: strerror(errno))
            close(outPipe[0]); close(outPipe[1])
            throw PipeCaptureError.launchFailed("pipe2: \(reason)")
        }
        let pid: pid_t
        do { pid = try Self.spawn(executable, command, stdout: outPipe[1], stderr: errPipe[1]) } catch {
            for descriptor in outPipe + errPipe { close(descriptor) }
            throw error
        }
        // The child owns the write ends now; ours must close or EOF never arrives.
        close(outPipe[1])
        close(errPipe[1])
        level.store(0, ordering: .relaxed)
        let run = Run(pid: pid, out: outPipe[0], err: errPipe[0])
        self.run = run

        let thread = Thread { [self] in
            readStream(run, sink: sink, onEvent: onEvent)
            run.done.signal()
        }
        thread.name = "vizier.pipe-capture"
        thread.start()
    }

    public func stop() -> CaptureStats {
        lock.lock()
        defer { lock.unlock() }
        guard let run else { return CaptureStats() }
        self.run = nil
        run.flags.withLock { $0.stopping = true }
        // The grace covers the recorder's termination only, never the reader or the sink.
        run.signalGroup(SIGTERM)
        if !run.awaitExit(timeout: terminationGrace) {
            run.signalGroup(SIGKILL)
            _ = run.awaitExit(timeout: nil)
        }
        // The leader is gone but still uncollected, so its group id is still ours: kill what it left.
        run.signalGroup(SIGKILL)
        run.flags.withLock { $0.groupDead = true }
        // The reader drains the pipe to EOF (or, when a process outside the group holds the write end,
        // to what was already in the pipe now), delivering every sink call. No deadline: a slow sink
        // is not a reason to lose audio.
        run.done.wait()
        run.reap()
        close(run.out)
        close(run.err)
        level.store(0, ordering: .relaxed)
        return CaptureStats(deviceSwitches: 0, droppedBuffers: run.dropped)
    }

    // MARK: Reader

    /// Runs on the reader thread until the stream ends. Every sink and event call is made here,
    /// which is what serializes them.
    private func readStream(_ run: Run, sink: CaptureSink, onEvent: @Sendable (CaptureEvent) -> Void) {
        var fds = [pollfd(fd: run.out, events: Int16(POLLIN), revents: 0), pollfd(fd: run.err, events: Int16(POLLIN), revents: 0)]
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let capacity = bytes.count
        var samples = [Int16](repeating: 0, count: 32_768 + 1)
        var carry: UInt8?
        var errorTail = Data()
        var signalSeen = false
        var budget: Int?

        while true {
            if budget == nil, run.flags.withLock({ $0.groupDead }) {
                // Everything the recorder wrote is in the pipe by now; anything arriving later is a
                // stranger's. Read what is there and stop, whether or not EOF ever comes.
                budget = max(0, Int(cpipe2_pending(run.out)))
            }
            if budget == 0 { break }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[1].fd >= 0, fds[1].revents != 0 {
                let count = bytes.withUnsafeMutableBytes { read(run.err, $0.baseAddress, 4_096) }
                if count > 0 {
                    errorTail.append(contentsOf: bytes[0..<count])
                    if errorTail.count > 512 { errorTail = errorTail.suffix(512) }
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    fds[1].fd = -1
                }
            }
            guard fds[0].revents != 0 else { continue }
            // The first byte of `bytes` is reserved for the carried odd byte.
            let count = bytes.withUnsafeMutableBytes { read(run.out, $0.baseAddress! + 1, min(capacity - 1, budget ?? Int.max)) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            if count <= 0 { break }
            if let left = budget { budget = left - count }
            var start = 1
            if let held = carry {
                bytes[0] = held
                start = 0
                carry = nil
            }
            let total = count + (1 - start)
            let whole = total & ~1
            if total & 1 == 1 { carry = bytes[start + total - 1] }
            guard whole > 0 else { continue }

            var sum: Float = 0
            var nonzero = false
            let frames = whole / 2
            for index in 0..<frames {
                let sample = Int16(bitPattern: UInt16(bytes[start + 2 * index]) | UInt16(bytes[start + 2 * index + 1]) << 8)
                samples[index] = sample
                let scaled = Float(sample) / 32_768
                sum += scaled * scaled
                if sample != 0 { nonzero = true }
            }
            level.store((sum / Float(frames)).bitPattern, ordering: .relaxed)
            if nonzero, !signalSeen {
                signalSeen = true
                onEvent(.signal)
            }
            samples.withUnsafeBufferPointer { sink(UnsafeBufferPointer(rebasing: $0[0..<frames])) }
        }

        if carry != nil { run.dropped += 1 }
        let stopping = run.flags.withLock { $0.stopping }
        guard !stopping else { return }
        // The stream ended and nobody asked for it: the recorder died or closed its output. Watch the
        // leader without collecting it, so the group id stays ours while the group is cleaned up.
        var exited = run.awaitExit(timeout: .zero)
        if !exited {
            run.signalGroup(SIGTERM)
            exited = run.awaitExit(timeout: .seconds(1))
            if !exited {
                run.signalGroup(SIGKILL)
                exited = run.awaitExit(timeout: nil)
            }
        }
        run.signalGroup(SIGKILL)
        let status = run.reap()
        var message = "the recorder stopped by itself (\(Self.describe(status ?? 0))), so capture ended"
        if let text = String(data: errorTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            message += ": " + text
        }
        if carry != nil { message += " (half a sample at the end was dropped)" }
        onEvent(.failed(message))
    }

    /// A raw `wait` status in words: `exit status N`, or `signal N`.
    private static func describe(_ status: Int32) -> String {
        let signal = status & 0x7f
        return signal == 0 ? "exit status \((status >> 8) & 0xff)" : "signal \(signal)"
    }

    // MARK: Process

    /// Starts `argv` with `stdout`/`stderr` redirected, stdin on /dev/null, an empty signal mask, default
    /// dispositions, and a process group of its own.
    private static func spawn(_ executable: String, _ argv: [String], stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

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
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, &arguments, Glibc.environ)
        guard result == 0 else { throw PipeCaptureError.launchFailed(String(cString: strerror(result))) }
        return pid
    }

    /// `name` as a path when it has a slash; otherwise the first executable of that name on PATH.
    private static func resolve(_ name: String) -> String? {
        let fm = FileManager.default
        if name.contains("/") { return fm.isExecutableFile(atPath: name) ? name : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif

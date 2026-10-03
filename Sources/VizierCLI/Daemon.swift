import Foundation
import Dispatch
import Glibc
import VizierEngine

/// Event-driven nonblocking I/O. Sources run on the main queue, alongside TakeControl.
@MainActor
public final class Daemon {
    public let handler: CommandHandler
    private let capacity: Int
    private let idleTimeout: TimeInterval
    private var directory: RuntimeDirectory?
    private var lockFD: Int32 = -1
    private var listener: Int32 = -1
    private var listenerSource: (any DispatchSourceRead)?
    private var timer: (any DispatchSourceTimer)?
    private var clients: [Int32: Connection] = [:]
    private var signals: [any DispatchSourceSignal] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var draining = false
    public private(set) var running = false
    public private(set) var published = false
    private var socketName = "vizier.sock.new"
    private var socketIdentity: (device: UInt, inode: UInt)?

    @MainActor private final class Connection {
        let fd: Int32
        var input = Data(), output = Data()
        var offset = 0, lastActivity = ContinuousClock.now
        var closing = false, readSuspended = false
        var sources = 0
        var closed = false
        func sourceCancelled() {
            sources -= 1
            if closed && sources == 0 { Glibc.close(fd) }
        }
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        init(_ fd: Int32) { self.fd = fd }
    }

    public init(handler: CommandHandler, capacity: Int = 128, idleTimeout: TimeInterval = 30) {
        precondition(capacity > 0 && idleTimeout > 0)
        self.handler = handler; self.capacity = capacity; self.idleTimeout = idleTimeout
    }
    /// Acquires the lock and prepares a private socket without publishing it.
    public func start(installSignals: Bool = false) throws {
        guard !running else { throw CLIError("already_running", "This daemon is already running.", next: "vizier status") }
        let directory = try RuntimeDirectory(environment: handler.environment, create: true)
        let lock = openat(directory.directoryFD, "daemon.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CLIError("unsafe_lock", "Cannot open daemon lock safely.", next: "vizier doctor") }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            Glibc.close(lock); throw CLIError("unsafe_lock", "Daemon lock must be a user-owned 0600 regular file.", next: "vizier doctor")
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Glibc.close(lock); throw CLIError("already_running", "Another daemon holds the runtime lock.", next: "vizier status")
        }
        self.directory = directory; lockFD = lock; socketName = "vizier.sock.new"
        do {
            for name in ["vizier.sock", "vizier.sock.new"] {
                if fstatat(directory.directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                        throw CLIError("unsafe_socket", "Stale socket path is not a user-owned socket.", next: "vizier doctor")
                    }
                    guard unlinkat(directory.directoryFD, name, 0) == 0 else { throw io("Cannot remove stale socket.") }
                } else if errno != ENOENT { throw io("Cannot inspect stale socket.") }
            }
            listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            guard listener >= 0 else { throw io("Cannot create daemon socket.") }
            let bound = try socketAddress("/proc/self/fd/\(directory.directoryFD)/vizier.sock.new") { bind(listener, $0, $1) }
            guard bound == 0 else { throw io("Cannot bind daemon socket.") }
            guard fstatat(directory.directoryFD, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw io("Cannot inspect bound socket.") }
            socketIdentity = (info.st_dev, info.st_ino)
            guard fchmodat(directory.directoryFD, socketName, 0o600, 0) == 0, listen(listener, 32) == 0 else { throw io("Cannot prepare daemon socket.") }
            signal(SIGPIPE, SIG_IGN)
            handler.shuttingDown = false; draining = false; running = true
            if installSignals {
                for sig in [SIGTERM, SIGINT] {
                    signal(sig, SIG_IGN)
                    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                    source.setEventHandler { @Sendable [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if self.draining { self.abort() }
                            else { Task { await self.shutdown() } }
                        }
                    }
                    signals.append(source); source.resume()
                }
            }
        } catch { abort(); throw error }
    }
    /// Call after storage/session initialization. A client sees only a ready 0600 endpoint.
    public func publish() throws {
        guard running, !draining, !published, let directory else { throw io("Daemon is not ready to publish.") }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { @Sendable [weak self] in MainActor.assumeIsolated { self?.acceptClients() } }
        let ownedFD = listener
        source.setCancelHandler { Glibc.close(ownedFD) }
        listenerSource = source; source.resume()
        guard renameat(directory.directoryFD, "vizier.sock.new", directory.directoryFD, "vizier.sock") == 0 else { throw io("Cannot publish daemon socket.") }
        socketName = "vizier.sock"; published = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { @Sendable [weak self] in MainActor.assumeIsolated { self?.sweep() } }
        self.timer = timer; timer.resume()
    }
    public func run() async {
        guard running else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if running { waiter = continuation } else { continuation.resume() }
            }
        } onCancel: { Task { @MainActor in await self.shutdown() } }
    }
    public func shutdown() async {
        guard running, !draining else { return }
        draining = true; handler.shuttingDown = true
        closeListener()
        let durable = await handler.control.quiesce(until: .now + .seconds(5))
        if !durable { FileHandle.standardError.write(Data("audio_save_incomplete\n".utf8)) }
        // Existing connections remain serviced, with commands refused by the handler.
        let deadline = ContinuousClock.now + .seconds(1)
        while running && clients.values.contains(where: { !$0.output.isEmpty }) && .now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if running { abort() }
    }
    /// Forced shutdown on a second signal or a failed bootstrap; the lock is released last.
    public func abort() {
        handler.shuttingDown = true; running = false; published = false
        closeListener()
        timer?.cancel(); timer = nil
        for source in signals { source.cancel() }; signals.removeAll()
        for fd in Array(clients.keys) { drop(fd) }
        if let directory, let identity = socketIdentity {
            var info = stat()
            if fstatat(directory.directoryFD, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_dev == identity.device, info.st_ino == identity.inode {
                _ = unlinkat(directory.directoryFD, socketName, 0)
            }
        }
        socketIdentity = nil
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); Glibc.close(lockFD); lockFD = -1 }
        directory = nil
        waiter?.resume(); waiter = nil
    }
    private func closeListener() {
        if listener >= 0 { _ = Glibc.shutdown(listener, Int32(SHUT_RDWR)) }
        if let source = listenerSource { source.cancel(); listenerSource = nil }
        else if listener >= 0 { Glibc.close(listener) }
        listener = -1
    }
    private func io(_ message: String) -> CLIError { CLIError("socket_error", message, next: "vizier doctor") }
    private func acceptClients() {
        guard running, !draining, listener >= 0 else { return }
        for _ in 0..<32 {
            // accept4 sets close-on-exec and nonblocking atomically: accept followed by fcntl leaves
            // a window in which a helper spawned concurrently would inherit the client's descriptor.
            let fd = acceptCloexecNonblock(listener)
            if fd < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; break }
            guard sameUser(fd) else { Glibc.close(fd); continue }
            if clients.count >= capacity {
                let reply = Reply(id: -1, error: CLIError("daemon_busy", "Daemon connection limit reached; no command accepted.", next: "vizier status"))
                if let data = try? Wire.line(reply) { _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, Int32(MSG_NOSIGNAL)) } }
                Glibc.close(fd); continue
            }
            let connection = Connection(fd); clients[fd] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { @Sendable [weak self, weak connection] in
                MainActor.assumeIsolated { if let connection { self?.read(connection) } }
            }
            connection.sources += 1
            source.setCancelHandler { @Sendable in MainActor.assumeIsolated { connection.sourceCancelled() } }
            connection.readSource = source; source.resume()
        }
    }
    private func read(_ client: Connection) {
        guard clients[client.fd] === client, client.output.isEmpty else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<17 {
            if client.input.firstIndex(of: 10) != nil || client.input.count > Wire.requestLimit { break }
            let n = recv(client.fd, &buffer, min(buffer.count, Wire.requestLimit + 1 - client.input.count), 0)
            if n > 0 { client.input.append(contentsOf: buffer.prefix(n)); client.lastActivity = .now }
            else if n == 0 { drop(client.fd); return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { drop(client.fd); return }
        }
        process(client)
    }
    private func process(_ client: Connection) {
        guard clients[client.fd] === client, client.output.isEmpty else { return }
        let reply: Reply
        if let end = client.input.firstIndex(of: 10) {
            do { reply = handler.handle(try JSONDecoder().decode(Request.self, from: client.input[..<end])) }
            catch { reply = Reply(id: -1, error: CLIError("invalid_request", "Expected a v=1 NDJSON request with integer id, cmd and args object.", next: "vizier --help")) }
            client.input.removeSubrange(...end)
        } else if client.input.count > Wire.requestLimit {
            reply = Reply(id: -1, error: CLIError("request_too_large", "Request exceeds 64 KiB; connection closed.", next: "vizier --help")); client.closing = true
        } else { return }
        client.output = (try? Wire.line(reply)) ?? Data(); client.offset = 0
        client.readSource?.suspend(); client.readSuspended = true
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: .main)
        source.setEventHandler { @Sendable [weak self, weak client] in MainActor.assumeIsolated { if let client { self?.write(client) } } }
        client.sources += 1
        source.setCancelHandler { @Sendable in MainActor.assumeIsolated { client.sourceCancelled() } }
        client.writeSource = source; source.resume()
    }
    private func write(_ client: Connection) {
        guard clients[client.fd] === client, !client.output.isEmpty else { return }
        let n = client.output.withUnsafeBytes { send(client.fd, $0.baseAddress!.advanced(by: client.offset), client.output.count - client.offset, Int32(MSG_NOSIGNAL)) }
        if n > 0 {
            client.offset += n; client.lastActivity = .now
            if client.offset == client.output.count {
                client.output = Data(); client.offset = 0
                client.writeSource?.cancel(); client.writeSource = nil
                if client.closing { drop(client.fd); return }
                client.readSuspended = false; client.readSource?.resume()
                // Joined lines already read from the kernel need no new readiness event.
                process(client)
            }
        } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { drop(client.fd) }
    }
    private func sweep() {
        for client in Array(clients.values) {
            if client.lastActivity.duration(to: .now) > .seconds(idleTimeout) { drop(client.fd) }
        }
    }
    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        if client.readSuspended { client.readSource?.resume() }
        client.closed = true
        client.readSource?.cancel(); client.writeSource?.cancel()
        client.readSource = nil; client.writeSource = nil
        if client.sources == 0 { Glibc.close(fd) }
    }
}

/// accept4(2) with SOCK_CLOEXEC | SOCK_NONBLOCK. Glibc's Swift overlay does not export it (it needs
/// _GNU_SOURCE), so it is looked up in libc once; the plain accept + fcntl pair is only a fallback
/// for a libc without it, and keeps the old race.
private let accept4Function: (@convention(c) (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?, Int32) -> Int32)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "accept4") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?, Int32) -> Int32).self)
}()

private func acceptCloexecNonblock(_ listener: Int32) -> Int32 {
    if let accept4Function {
        return accept4Function(listener, nil, nil, Int32(SOCK_CLOEXEC.rawValue) | Int32(SOCK_NONBLOCK.rawValue))
    }
    let fd = accept(listener, nil, nil)
    if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
    return fd
}

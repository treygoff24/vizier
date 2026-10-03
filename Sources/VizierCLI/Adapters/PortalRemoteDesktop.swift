#if os(Linux)
import Foundation
import Glibc

/// Consent is obtained only by prepare(); delivery never opens a consent dialog.
public actor PortalRemoteDesktop: KeySender, ClipboardWriter {
    public nonisolated let name = "portal-remote-desktop"
    private let client: PortalClient
    private let tokens: PortalTokenStore
    private var session: String?
    private var clipboardEnabled = false
    private var keyboardEnabled = false
    private var preparing = false
    private var sending = false
    private var publishing = false
    private var generation = 0
    private var observationID = UUID()
    private var status = "Consent not granted; run vizier setup"
    private var text = Data()
    private static let mimeTypes = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"]
    private var ownerEvents = 0
    private var publication: (id: UUID, after: Int, sink: AsyncStream<Bool>.Continuation)?
    private var heldKeys: [Int32] = []
    private var heldMethod = "NotifyKeyboardKeysym"
    private var observers: [Task<Void, Never>] = []
    private var subscriptions: [DBusSignals] = []

    public init(connection: DBusConnection? = nil, stateDirectory: URL? = nil) {
        client = PortalClient(connection: connection)
        tokens = PortalTokenStore(directory: stateDirectory)
    }
    deinit { for observer in observers { observer.cancel() }; for subscription in subscriptions { subscription.cancel() } }

    public func probe() async -> AdapterProbe {
        do {
            let remote = try await client.version("org.freedesktop.portal.RemoteDesktop")
            let clipboard = try? await client.version("org.freedesktop.portal.Clipboard")
            let identity = await client.registrationDetail
            return AdapterProbe(name: name, available: session != nil && clipboardEnabled && keyboardEnabled,
                detail: "RemoteDesktop v\(remote) present; Clipboard \(clipboard.map { "v\($0) present" } ?? "absent"); \(status). \(identity). Desktop paste is unverified; Wayland has no secure-field check; keysym paste follows the layout, but a refused keysym can use physical keycodes and the portal cannot inspect the layout",
                fix: session != nil && clipboardEnabled && keyboardEnabled ? nil : "vizier setup")
        } catch { return AdapterProbe(name: name, available: false, detail: String(describing: error), fix: "Install libsystemd and a desktop portal, then run vizier setup") }
    }

    public func prepare() async throws {
        guard !preparing && !sending && !publishing else { throw PortalFailure.busy }
        preparing = true
        defer { preparing = false }
        await stop()
        let epoch = generation
        let observation = observationID
        do {
            guard try await client.version("org.freedesktop.portal.RemoteDesktop") >= 2 else { throw PortalFailure.invalidResponse }
            _ = try await client.version("org.freedesktop.portal.Clipboard")
            let owner = try await client.ownerChanges()
            subscriptions.append(owner)
            observers.append(Task { [weak self] in
                do { for try await _ in owner.stream { await self?.restart(observation: observation) } }
                catch { await self?.invalidate(observation: observation) }
            })
            let created = try await client.request("org.freedesktop.portal.RemoteDesktop", "CreateSession", options: ["session_handle_token": .string("vizier_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_"))])
            guard let handle = created["session_handle"]?.string, handle.hasPrefix("/"), generation == epoch else { throw PortalFailure.closed }
            session = handle
            let closed = try await client.match("org.freedesktop.portal.Session", "Closed", path: handle)
            subscriptions.append(closed)
            observers.append(Task { [weak self] in
                do { for try await _ in closed.stream { await self?.invalidate(observation: observation, closeSession: false) } }
                catch { await self?.invalidate(observation: observation) }
            })
            var options: [String: DBusValue] = ["types": .uint32(1), "persist_mode": .uint32(2)]
            if let token = tokens.read() { options["restore_token"] = .string(token) }
            try tokens.write(nil) // a restore token is single-use
            _ = try await client.request("org.freedesktop.portal.RemoteDesktop", "SelectDevices", args: [.objectPath(handle)], options: options)
            _ = try await client.call("org.freedesktop.portal.Clipboard", "RequestClipboard", [.objectPath(handle), .dictionary([:])])
            let transfer = try await client.match("org.freedesktop.portal.Clipboard", "SelectionTransfer")
            subscriptions.append(transfer)
            observers.append(Task { [weak self] in
                do { for try await values in transfer.stream { await self?.transfer(values) } }
                catch { await self?.invalidate(observation: observation) }
            })
            let ownership = try await client.match("org.freedesktop.portal.Clipboard", "SelectionOwnerChanged", argument0: handle)
            subscriptions.append(ownership)
            observers.append(Task { [weak self] in
                do { for try await values in ownership.stream { await self?.ownershipChanged(values) } }
                catch { await self?.invalidate(observation: observation) }
            })
            let result = try await client.request("org.freedesktop.portal.RemoteDesktop", "Start", args: [.objectPath(handle), .string("")])
            guard generation == epoch, session == handle else { throw PortalFailure.closed }
            guard let devices = result["devices"]?.uint32, devices & 1 != 0 else { throw PortalFailure.notPrepared }
            guard result["clipboard_enabled"]?.bool == true else { throw PortalFailure.clipboardDenied }
            try tokens.write(result["restore_token"]?.string)
            clipboardEnabled = true
            keyboardEnabled = true
            status = "Keyboard and clipboard consent granted; desktop delivery not verified"
        } catch {
            status = String(describing: error)
            let failure = status
            await stop()
            status = failure
            throw error
        }
    }
    private func restart(observation: UUID) async {
        guard observationID == observation else { return }
        await invalidate(observation: observation, closeSession: false)
        await client.resetRegistration()
    }
    private func invalidate(observation: UUID, closeSession: Bool = true) async {
        guard observationID == observation else { return }
        let old = session
        invalidate()
        if let old {
            await releaseKeys(handle: old)
            if closeSession { await client.close(old) }
        }
    }
    private func invalidate() {
        generation += 1
        clipboardEnabled = false; keyboardEnabled = false; text = Data()
        publication?.sink.yield(false); publication?.sink.finish(); publication = nil
        status = "Consent revoked, session closed, or portal restarted; run vizier setup"
    }
    private func ownershipChanged(_ values: [DBusValue]) {
        guard values.count == 2, values[0].string == session, let options = values[1].dictionary else { return }
        ownerEvents += 1
        if options["session_is_owner"]?.bool == true, let pending = publication, ownerEvents > pending.after {
            pending.sink.yield(true); pending.sink.finish()
        }
    }
    public func stop() async {
        observationID = UUID() // queued signals from an earlier setup cannot invalidate its successor
        let old = session
        invalidate()
        for observer in observers { observer.cancel() }
        for subscription in subscriptions { subscription.cancel() }
        observers.removeAll(); subscriptions.removeAll()
        if let old { await releaseKeys(handle: old); await client.close(old) }
        session = nil
        await client.releaseIfOwned()
    }
    public func publish(_ text: String) async throws {
        guard let handle = session, clipboardEnabled else { throw PortalFailure.notPrepared }
        guard !publishing else { throw PortalFailure.busy }
        publishing = true
        let id = UUID()
        let (stream, sink) = AsyncStream<Bool>.makeStream()
        publication = (id, ownerEvents, sink)
        defer {
            publishing = false
            if publication?.id == id { publication = nil }
            sink.finish()
        }
        self.text = Data(text.utf8)
        let epoch = generation
        do {
            _ = try await client.call("org.freedesktop.portal.Clipboard", "SetSelection", [.objectPath(handle), .dictionary(["mime_types": .array("s", Self.mimeTypes.map(DBusValue.string))])])
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    guard let owned = await iterator.next(), owned else { throw PortalFailure.closed }
                    return owned
                }
                group.addTask { try await Task.sleep(for: .seconds(2)); throw PortalFailure.timeout }
                defer { group.cancelAll() }
                guard try await group.next() == true else { throw PortalFailure.closed }
            }
            guard generation == epoch, clipboardEnabled else { throw PortalFailure.closed }
        } catch {
            if generation == epoch { await invalidate(observation: observationID) }
            status = "Clipboard ownership was not confirmed; run vizier setup"
            throw error
        }
    }
    private func transfer(_ values: [DBusValue]) async {
        guard values.count >= 3, let handle = values[0].string, let serial = values[2].uint32 else { return }
        let mime = values[1].string
        let data = text
        var success = false
        if handle == session, clipboardEnabled, let mime, Self.mimeTypes.contains(mime) {
            do {
                let reply = try await client.call("org.freedesktop.portal.Clipboard", "SelectionWrite", [.objectPath(handle), .uint32(serial)])
                guard let first = reply.first, case .unixFD(let fd) = first else { throw PortalFailure.invalidResponse }
                // FileHandle writes on a utility queue: large selections never block the actor.
                success = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        defer { _ = Glibc.close(fd) }
                        continuation.resume(returning: Self.writeSelection(data, fd: fd))
                    }
                }
            } catch { success = false }
        }
        _ = try? await client.call("org.freedesktop.portal.Clipboard", "SelectionWriteDone", [.objectPath(handle), .uint32(serial), .bool(success)])
    }
    /// A clipboard reader may close early or stop draining. Bound the transfer and block
    /// SIGPIPE on this worker only, so neither case kills or stalls the daemon.
    private nonisolated static func writeSelection(_ data: Data, fd: Int32) -> Bool {
        var blocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { return false }
        defer {
            if sigismember(&previous, SIGPIPE) == 0 {
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                // Consume only this thread's pending broken-pipe signal before restoring its mask.
                _ = sigtimedwait(&blocked, nil, &zero)
            }
            _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let result = poll(&descriptor, 1, 100)
                    if result < 0 && errno != EINTR { return false }
                    if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
                    continue
                }
                return false
            }
            return true
        }
    }
    private func releaseKeys(handle: String) async {
        let keys = heldKeys.reversed()
        let method = heldMethod
        heldKeys.removeAll() // take ownership before suspending, so stop/invalidate cannot double-release
        for key in keys {
            _ = try? await client.call("org.freedesktop.portal.RemoteDesktop", method, [.objectPath(handle), .dictionary([:]), .int32(key), .uint32(0)])
        }
    }
    public func send(_ chord: PasteChord) async throws {
        guard let handle = session, keyboardEnabled else { throw PortalFailure.notPrepared }
        guard !sending else { throw PortalFailure.busy }
        try Task.checkCancellation()
        sending = true
        defer { sending = false }
        let epoch = generation
        func sequence(keysym: Bool) -> [(Int32, UInt32)] {
            let modifiers: [Int32] = chord == .ctrlShiftV ? (keysym ? [0xffe3, 0xffe1] : [29, 42]) : (keysym ? [0xffe3] : [29])
            let v: Int32 = keysym ? 0x76 : 47
            return modifiers.map { ($0, UInt32(1)) } + [(v, 1), (v, 0)] + modifiers.reversed().map { ($0, UInt32(0)) }
        }
        var events = sequence(keysym: true)
        heldMethod = "NotifyKeyboardKeysym"
        var index = 0
        var attempted = false
        var failed = false
        while index < events.count {
            if generation != epoch || !keyboardEnabled || Task.isCancelled { failed = true; break }
            let (key, state) = events[index]
            if state == 1 { heldKeys.append(key) } // also release a key whose reply is ambiguous
            attempted = true
            do {
                _ = try await client.call("org.freedesktop.portal.RemoteDesktop", heldMethod, [.objectPath(handle), .dictionary([:]), .int32(key), .uint32(state)])
                if state == 0 { heldKeys.removeAll { $0 == key } }
                index += 1
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                if index == 0, heldMethod == "NotifyKeyboardKeysym", let error = error as? DBusFailure, error.unsupportedMethod {
                    heldKeys.removeAll(); attempted = false
                    heldMethod = "NotifyKeyboardKeycode"; events = sequence(keysym: false)
                    continue // explicit refusal before any key was sent; no ambiguous retry
                }
                failed = true; break
            }
        }
        await releaseKeys(handle: handle) // every exit path, including cancellation/invalidation
        if failed {
            if generation == epoch { await invalidate(observation: observationID) }
            status = "Paste may have reached the desktop; no fallback retry; run vizier setup"
            if !attempted { throw PortalFailure.closed }
        }
    }
}
#endif

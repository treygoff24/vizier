#if os(Linux)
import Foundation

public actor PortalGlobalShortcuts: HotkeySource {
    public nonisolated let name = "portal-global-shortcuts"
    private let client: PortalClient
    private let toggleTrigger: String
    private let cancelTrigger: String
    private var session: String?
    private var generation = 0
    private var observationID = UUID()
    private var starting = false
    private var bound = false
    private var cancelBound = false
    private var status = "Shortcuts not bound; run vizier setup"
    private var observers: [Task<Void, Never>] = []
    private var subscriptions: [DBusSignals] = []

    public init(connection: DBusConnection? = nil, toggleTrigger: String = "CTRL+ALT+space", cancelTrigger: String = "CTRL+ALT+BackSpace") {
        client = PortalClient(connection: connection)
        self.toggleTrigger = toggleTrigger; self.cancelTrigger = cancelTrigger
    }
    deinit { for observer in observers { observer.cancel() }; for subscription in subscriptions { subscription.cancel() } }
    public func probe() async -> AdapterProbe {
        do {
            let version = try await client.version("org.freedesktop.portal.GlobalShortcuts")
            let identity = await client.registrationDetail
            return AdapterProbe(name: name, available: bound, detail: "GlobalShortcuts v\(version) present; \(status). \(identity). Physical shortcut activation is unverified", fix: bound ? nil : "Install net.praxient.vizier.desktop and run vizier setup")
        } catch { return AdapterProbe(name: name, available: false, detail: String(describing: error), fix: "Install libsystemd and a GlobalShortcuts portal; alternatively bind vizier toggle and vizier cancel in the compositor") }
    }
    public func start(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) async throws {
        guard !starting else { throw PortalFailure.busy }
        starting = true
        defer { starting = false }
        await stop()
        let epoch = generation
        let observation = observationID
        do {
            _ = try await client.version("org.freedesktop.portal.GlobalShortcuts")
            let owner = try await client.ownerChanges()
            subscriptions.append(owner)
            observers.append(Task { [weak self] in
                do { for try await _ in owner.stream { await self?.restart(observation: observation) } }
                catch { await self?.invalidate(observation: observation) }
            })
            let created = try await client.request("org.freedesktop.portal.GlobalShortcuts", "CreateSession", options: ["session_handle_token": .string("vizier_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_"))])
            guard let handle = created["session_handle"]?.string, handle.hasPrefix("/"), generation == epoch else { throw PortalFailure.closed }
            session = handle
            let closed = try await client.match("org.freedesktop.portal.Session", "Closed", path: handle)
            subscriptions.append(closed)
            observers.append(Task { [weak self] in
                do { for try await _ in closed.stream { await self?.invalidate(observation: observation, closeSession: false) } }
                catch { await self?.invalidate(observation: observation) }
            })
            // Subscribe before binding so immediate activations are not missed.
            let activated = try await client.match("org.freedesktop.portal.GlobalShortcuts", "Activated", argument0: handle)
            subscriptions.append(activated)
            observers.append(Task { [weak self] in
                do {
                    for try await values in activated.stream {
                        guard values.count >= 2, values[0].string == handle, let id = values[1].string else { continue }
                        await self?.activate(id, session: handle, onToggle: onToggle, onCancel: onCancel)
                    }
                } catch { await self?.invalidate(observation: observation) }
            })
            let shortcuts: [DBusValue] = [
                .structure([.string("toggle"), .dictionary(["description": .string("Toggle dictation"), "preferred_trigger": .string(toggleTrigger)])]),
                .structure([.string("cancel"), .dictionary(["description": .string("Cancel dictation"), "preferred_trigger": .string(cancelTrigger)])]),
            ]
            let result = try await client.request("org.freedesktop.portal.GlobalShortcuts", "BindShortcuts", args: [.objectPath(handle), .array("(sa{sv})", shortcuts), .string("")])
            guard generation == epoch, session == handle else { throw PortalFailure.closed }
            guard case .array(_, let values) = result["shortcuts"] else { throw PortalFailure.invalidResponse }
            let ids = Set(values.compactMap { value -> String? in
                guard case .structure(let pair) = value else { return nil }
                return pair.first?.string
            })
            guard ids.contains("toggle") else { throw PortalFailure.notPrepared }
            bound = true
            cancelBound = ids.contains("cancel")
            status = cancelBound ? "Toggle and cancel consent granted; physical activation not verified" : "Toggle consent granted; cancel is not bound (bind vizier cancel in the compositor); physical activation not verified"
        } catch {
            let failure = String(describing: error)
            await stop(); status = failure
            throw error
        }
    }
    private func activate(_ id: String, session handle: String, onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) async {
        guard session == handle, bound else { return }
        switch id { case "toggle": await onToggle(); case "cancel": if cancelBound { await onCancel() }; default: break }
    }
    private func restart(observation: UUID) async {
        guard observationID == observation else { return }
        invalidate(); await client.resetRegistration()
    }
    private func invalidate(observation: UUID, closeSession: Bool = true) async {
        guard observationID == observation else { return }
        let old = session
        invalidate()
        if closeSession, let old { await client.close(old) }
    }
    private func invalidate() { generation += 1; bound = false; cancelBound = false; status = "Session closed or portal restarted; run vizier setup" }
    public func stop() async {
        observationID = UUID() // queued signals from an earlier setup cannot invalidate its successor
        let old = session
        invalidate()
        for observer in observers { observer.cancel() }
        for subscription in subscriptions { subscription.cancel() }
        observers.removeAll(); subscriptions.removeAll()
        session = nil
        if let old { await client.close(old) }
        await client.releaseIfOwned()
    }
}
#endif

#if os(Linux)
import Foundation
import Glibc

public enum PortalFailure: Error, Sendable, CustomStringConvertible {
    case notPrepared, denied(UInt32), timeout, invalidResponse, busy, clipboardDenied, closed
    public var description: String {
        switch self {
        case .notPrepared: "Portal consent is not granted; run vizier setup"
        case .denied(let code): "Portal consent denied or cancelled (response \(code)); run vizier setup"
        case .timeout: "Portal request timed out; run vizier setup"
        case .invalidResponse: "Portal returned an invalid response"
        case .busy: "Portal operation already in progress"
        case .clipboardDenied: "Portal clipboard consent was not granted; run vizier setup"
        case .closed: "Portal session closed or service restarted; run vizier setup"
        }
    }
}

/// One peer identity per adapter. Registry.Register must precede even presence probes.
actor PortalClient {
    static let path = "/org/freedesktop/portal/desktop"
    private var connection: DBusConnection?
    private let suppliedConnection: Bool
    private var registered = false
    private var registration: (id: UUID, task: Task<String, Never>)?
    private var registrationEpoch = 0
    private(set) var registrationDetail = "App identity has not been registered"
    init(connection: DBusConnection?) { self.connection = connection; suppliedConnection = connection != nil }

    func releaseIfOwned() {
        if !suppliedConnection { connection = nil; resetRegistration() }
    }

    func bus() async throws -> DBusConnection {
        if let connection { return connection }
        let opened = try await DBusConnection.open()
        // Concurrent callers may have opened another connection while suspended.
        if let connection { return connection }
        connection = opened
        return opened
    }
    func register() async throws {
        if registered { return }
        let bus = try await bus()
        if registered { return }
        let epoch = registrationEpoch
        let flight: (id: UUID, task: Task<String, Never>)
        if let registration { flight = registration }
        else {
            flight = (UUID(), Task {
                do {
                    _ = try await bus.call(interface: "org.freedesktop.host.portal.Registry", member: "Register", arguments: [.string("net.praxient.vizier"), .dictionary([:])])
                    return "App id net.praxient.vizier registered (requires net.praxient.vizier.desktop on GNOME)"
                } catch {
                    return "Registry.Register unavailable or rejected; GNOME may reject shortcuts without installed net.praxient.vizier.desktop"
                }
            })
            registration = flight
        }
        let detail = await flight.task.value
        guard registrationEpoch == epoch else { try await register(); return }
        if registration?.id == flight.id {
            registrationDetail = detail; registered = true; registration = nil
        }
    }
    // After a verified owner change, new subscriptions resolve GetNameOwner afresh.
    func resetRegistration() { registered = false; registrationEpoch += 1; registration = nil }
    func version(_ interface: String) async throws -> UInt32 {
        try await register()
        let bus = try await bus()
        let values = try await bus.call(interface: "org.freedesktop.DBus.Properties", member: "Get", arguments: [.string(interface), .string("version")])
        guard let version = values.first?.uint32 else { throw PortalFailure.invalidResponse }
        return version
    }
    func call(_ interface: String, _ member: String, _ args: [DBusValue] = [], path: String = PortalClient.path) async throws -> [DBusValue] {
        try await register()
        return try await bus().call(path: path, interface: interface, member: member, arguments: args)
    }
    func match(_ interface: String, _ member: String, path: String? = PortalClient.path, argument0: String? = nil) async throws -> DBusSignals {
        try await bus().match(path: path, interface: interface, member: member, argument0: argument0)
    }
    func ownerChanges() async throws -> DBusSignals {
        try await bus().match(sender: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", member: "NameOwnerChanged", argument0: "org.freedesktop.portal.Desktop")
    }
    func request(_ interface: String, _ member: String, args: [DBusValue] = [], options: [String: DBusValue] = [:], timeout: Duration = .seconds(300)) async throws -> [String: DBusValue] {
        try await register()
        let bus = try await bus()
        let token = "vizier_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let sender = bus.uniqueName.dropFirst().replacingOccurrences(of: ".", with: "_")
        let expected = "/org/freedesktop/portal/desktop/request/\(sender)/\(token)"
        // Install and acknowledge the match before calling: a response can precede the reply.
        let signals = try await bus.match(path: expected, interface: "org.freedesktop.portal.Request", member: "Response")
        defer { signals.cancel() }
        var options = options
        options["handle_token"] = .string(token)
        var actualRequest = expected
        do {
            let reply = try await bus.call(interface: interface, member: member, arguments: args + [.dictionary(options)])
            if let returned = reply.first?.string, returned.hasPrefix("/") { actualRequest = returned }
            guard actualRequest == expected else { throw PortalFailure.invalidResponse }
            return try await withThrowingTaskGroup(of: [String: DBusValue].self) { group in
                group.addTask {
                    var iterator = signals.stream.makeAsyncIterator()
                    guard let response = try await iterator.next(), response.count == 2,
                          let code = response[0].uint32, let result = response[1].dictionary else { throw PortalFailure.invalidResponse }
                    guard code == 0 else { throw PortalFailure.denied(code) }
                    return result
                }
                group.addTask { try await Task.sleep(for: timeout); throw PortalFailure.timeout }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw PortalFailure.invalidResponse }
                return result
            }
        } catch {
            // Withdraw abandoned request/dialog; errors here do not hide the original failure.
            _ = try? await bus.call(path: actualRequest, interface: "org.freedesktop.portal.Request", member: "Close")
            throw error
        }
    }
    func close(_ session: String) async {
        _ = try? await bus().call(path: session, interface: "org.freedesktop.portal.Session", member: "Close")
    }
}

/// Tokens are capabilities. Never log them; create the file at 0600 before writing any bytes.
struct PortalTokenStore: Sendable {
    let directory: URL
    var file: URL { directory.appendingPathComponent("portal.json") }
    init(directory: URL?) {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        self.directory = directory ?? base.appendingPathComponent("vizier")
    }
    func read() -> String? {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { _ = Glibc.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size <= 65536 else { return nil }
        let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return object["restore_token"]
    }
    func write(_ token: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), chmod(directory.path, 0o700) == 0 else { throw DBusFailure.operation(-errno) }
        let temp = directory.appendingPathComponent(".portal-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DBusFailure.operation(-errno) }
        defer { _ = Glibc.close(fd); _ = unlink(temp.path) }
        let data = try JSONSerialization.data(withJSONObject: token.map { ["restore_token": $0] } ?? [:])
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temp.path, file.path) == 0 else { throw DBusFailure.operation(-errno) }
    }
}
#endif

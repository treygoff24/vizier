import Foundation
import Glibc

/// Owns directory descriptors so creation/unlink cannot follow a substituted `vizier` symlink.
final class RuntimeDirectory {
    private(set) var rootFD: Int32 = -1
    private(set) var directoryFD: Int32 = -1
    let socketPath: String
    var anchoredSocketPath: String { "/proc/self/fd/\(directoryFD)/vizier.sock" }

    init(environment: [String: String], create: Bool) throws {
        guard let root = environment["XDG_RUNTIME_DIR"], root.hasPrefix("/") else {
            throw Self.unavailable("XDG_RUNTIME_DIR must be an absolute, user-owned 0700 directory.", next: "export XDG_RUNTIME_DIR=/run/user/$(id -u)")
        }
        socketPath = root + "/vizier/vizier.sock"
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CLIError("socket_path_too_long", "Unix socket path exceeds 107 bytes.", next: "vizier doctor")
        }
        rootFD = Glibc.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Self.unavailable("Cannot open XDG_RUNTIME_DIR without following a symlink.") }
        var info = stat()
        guard fstat(rootFD, &info) == 0 else { throw Self.unavailable("Cannot inspect runtime directory.") }
        try Self.validate(info, uid: getuid())
        if create && mkdirat(rootFD, "vizier", 0o700) != 0 && errno != EEXIST {
            throw Self.unavailable("Cannot create the private vizier runtime directory.")
        }
        directoryFD = openat(rootFD, "vizier", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            if !create && errno == ENOENT { throw SocketClient.down() }
            throw Self.unavailable("Cannot open the vizier runtime directory safely.")
        }
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid() else {
            throw Self.unavailable("The vizier runtime directory must be user-owned.")
        }
        guard info.st_mode & 0o7777 == 0o700 else {
            throw Self.unavailable("The vizier runtime directory must be mode 0700.", next: "chmod 700 \"$XDG_RUNTIME_DIR/vizier\"")
        }
    }
    deinit {
        // A throwing initializer also runs deinit once its stored properties are initialized.
        // This is the sole owner of closes, including failed validation paths.
        if directoryFD >= 0 { Glibc.close(directoryFD) }
        if rootFD >= 0 { Glibc.close(rootFD) }
    }
    static func validate(_ info: stat, uid: uid_t) throws {
        guard info.st_uid == uid else { throw unavailable("Runtime directory belongs to another user.") }
        guard info.st_mode & 0o7777 == 0o700 else {
            throw unavailable("Runtime directory must have mode 0700.", next: "chmod 700 \"$XDG_RUNTIME_DIR\"")
        }
    }
    static func unavailable(_ message: String, next: String = "export XDG_RUNTIME_DIR=/run/user/$(id -u)") -> CLIError {
        CLIError("runtime_dir_unavailable", message, next: next)
    }
    func validateSocket() throws {
        var info = stat()
        guard fstatat(directoryFD, "vizier.sock", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw SocketClient.down() }
            throw Self.unavailable("Cannot inspect the socket.")
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600 else {
            throw CLIError("unsafe_socket", "Socket must be owned by this user and mode 0600.", next: "vizier doctor")
        }
    }
}

func socketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw CLIError("socket_path_too_long", "Unix socket path exceeds 107 bytes.", next: "vizier doctor")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

// Linux ucred's ABI is three 32-bit integers; Glibc does not import struct ucred in Swift.
struct PeerCredentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
func sameUser(_ fd: Int32) -> Bool {
    var peer = PeerCredentials()
    var size = socklen_t(MemoryLayout<PeerCredentials>.size)
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) == 0 && size == MemoryLayout<PeerCredentials>.size && peer.uid == getuid()
}

public enum SocketClient {
    public static func down() -> CLIError {
        CLIError("daemon_not_running", "Vizier daemon is down.", next: "vizier daemon")
    }
    /// Synchronous I/O: call from a detached task when the in-process daemon uses MainActor.
    public static func call(_ request: Request, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Reply {
        let directory = try RuntimeDirectory(environment: environment, create: false)
        try directory.validateSocket()
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw CLIError("socket_error", "Cannot create client socket.", next: "vizier doctor") }
        defer { Glibc.close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = try socketAddress(directory.anchoredSocketPath) { connect(fd, $0, $1) }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw down() }
            throw CLIError("socket_error", "Cannot connect to daemon socket.", next: "vizier doctor")
        }
        guard sameUser(fd) else { throw CLIError("peer_refused", "Daemon UID does not match this user.", next: "vizier doctor") }
        let requestData = try Wire.line(request)
        guard requestData.count - 1 <= Wire.requestLimit else { throw CLIError("request_too_large", "Request exceeds 64 KiB.", next: "vizier --help") }
        var sent = 0
        while sent < requestData.count {
            let n = requestData.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), requestData.count - sent, Int32(MSG_NOSIGNAL)) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break } // an overloaded daemon may already have sent daemon_busy and closed
            sent += n
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= 16 * 1024 * 1024 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CLIError("socket_error", "No daemon reply; command acceptance is unknown.", next: "vizier status") }
            data.append(contentsOf: buffer.prefix(n))
            if let end = data.firstIndex(of: 10) {
                let reply: Reply
                do { reply = try JSONDecoder().decode(Reply.self, from: data[..<end]) }
                catch { throw CLIError("invalid_reply", "Daemon returned invalid JSON.", next: "vizier doctor") }
                guard reply.v == 1, (reply.id == request.id || (reply.id == -1 && reply.error?.code == "daemon_busy")), reply.ok ? (reply.result != nil && reply.error == nil) : (reply.error != nil && reply.result == nil) else {
                    throw CLIError("invalid_reply", "Daemon reply envelope does not match request.", next: "vizier doctor")
                }
                return reply
            }
        }
        throw CLIError("invalid_reply", "Daemon reply exceeded 16 MiB.", next: "vizier history --limit 1")
    }
}

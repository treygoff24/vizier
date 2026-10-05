import Foundation
import Glibc

/// `ydotool key` with raw evdev keycodes: it writes to /dev/uinput through `ydotoold`, so it
/// works under any compositor, at the price of a daemon and uinput permission. Default on COSMIC, opt-in fallback elsewhere.
public struct YdotoolKeySender: KeySender {
    public let name = "ydotool"
    private let env: HelperEnvironment

    // linux/input-event-codes.h
    static let keyLeftCtrl = 29, keyLeftShift = 42, keyV = 47

    public init(env: HelperEnvironment = HelperEnvironment()) { self.env = env }

    /// What a path turned out to be when checked as a ydotoold socket.
    enum SocketState: Equatable {
        case live, missing, notASocket, denied, refused
    }

    /// Checks `path` is a socket (S_ISSOCK, not a regular file left behind) that accepts a connect.
    /// ydotoold binds a datagram socket in current versions; a stream socket is accepted too.
    /// Connecting sends nothing, so nothing is injected.
    static func socketState(_ path: String) -> SocketState {
        var info = stat()
        guard stat(path, &info) == 0 else { return errno == EACCES ? .denied : .missing }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return .notASocket }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return .refused }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
            buffer[path.utf8.count] = 0
        }
        var denied = false
        for type in [SOCK_DGRAM, SOCK_STREAM] {
            let descriptor = socket(AF_UNIX, Int32(type.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 { return .live }
            if errno == EACCES { denied = true }
        }
        return denied ? .denied : .refused
    }

    /// The socket `ydotoold` listens on, as the client will be told to find it. YDOTOOL_SOCKET wins
    /// without a check (the probe reports it). Without it, ydotoold versions disagree on the
    /// default: some listen on `$XDG_RUNTIME_DIR/.ydotool_socket`, others on `/tmp/.ydotool_socket`,
    /// and a client built for one never finds the other. Vizier checks its private
    /// `$XDG_RUNTIME_DIR/vizier-input/socket` first, then those legacy defaults. The first live socket
    /// is used (the runtime dir first; a stale file or a non-socket there moves on to the next
    /// candidate), and `send` passes it to the client explicitly, so the mismatch cannot break the paste.
    static func socketPath(variables: [String: String], usable: (String) -> Bool = { socketState($0) == .live },
                           ownedByCurrentUser: (String) -> Bool = { socketOwnedByCurrentUser($0) }) -> (path: String, explicit: Bool)? {
        if let configured = variables["YDOTOOL_SOCKET"], !configured.isEmpty {
            return (configured, true)
        }
        return defaultCandidates(variables).first(where: { ($0 != "/tmp/.ydotool_socket" || ownedByCurrentUser($0)) && usable($0) }).map { ($0, false) }
    }

    static func socketOwnedByCurrentUser(_ path: String, currentUID: uid_t = getuid()) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_uid == currentUID
    }

    static func defaultCandidates(_ variables: [String: String]) -> [String] {
        var candidates: [String] = []
        if let runtime = variables["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            candidates.append(runtime + "/vizier-input/socket")
            candidates.append(runtime + "/.ydotool_socket")
        }
        candidates.append("/tmp/.ydotool_socket")
        return candidates
    }

    public func probe() async -> AdapterProbe {
        guard env.resolve("ydotool") != nil else {
            return Helper.missing(name, tool: "ydotool", env: env)
        }
        let fix = "start ydotoold (systemctl --user enable --now ydotool, or run `ydotoold` as a user with access to /dev/uinput); set YDOTOOL_SOCKET if it listens elsewhere"
        guard let socket = Self.socketPath(variables: env.variables) else {
            return AdapterProbe(name: name, available: false,
                                detail: "ydotoold is not running (no live socket at \(Self.defaultCandidates(env.variables).joined(separator: " or ")))",
                                fix: fix)
        }
        switch Self.socketState(socket.path) {
        case .live:
            return AdapterProbe(name: name, available: true, detail: "ydotoold socket \(socket.path)")
        case .missing:
            return AdapterProbe(name: name, available: false, detail: "YDOTOOL_SOCKET points at \(socket.path), which does not exist", fix: fix)
        case .notASocket:
            return AdapterProbe(name: name, available: false, detail: "\(socket.path) is not a socket", fix: fix)
        case .refused:
            return AdapterProbe(name: name, available: false, detail: "nothing accepts connections on \(socket.path) (a stale socket)", fix: fix)
        case .denied:
            return AdapterProbe(name: name, available: false,
                                detail: "the ydotoold socket \(socket.path) is not writable by this user",
                                fix: "run ydotoold as your user with /dev/uinput access or start it with --socket-own=$(id -u):$(id -g)")
        }
    }

    public func send(_ chord: PasteChord) async throws {
        let c = Self.keyLeftCtrl, s = Self.keyLeftShift, v = Self.keyV
        let events: [String]
        switch chord {
        case .ctrlV: events = ["\(c):1", "\(v):1", "\(v):0", "\(c):0"]
        case .ctrlShiftV: events = ["\(c):1", "\(s):1", "\(v):1", "\(v):0", "\(s):0", "\(c):0"]
        }
        var variables = env.variables
        guard let socket = Self.socketPath(variables: variables), Self.socketState(socket.path) == .live else {
            throw AdapterError("ydotoold socket is unavailable; paste the clipboard manually")
        }
        variables["YDOTOOL_SOCKET"] = socket.path
        try await Helper.send(["ydotool", "key"] + events, environment: variables)
    }
}

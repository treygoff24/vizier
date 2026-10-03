import Foundation
import Glibc
import VizierEngine

/// The local speech servers a mode may use (D15): whisper.cpp's `whisper-server` for transcription
/// and a bring-your-own cleanup server. `vizier doctor` and `vizier setup` check that each one a
/// mode uses answers on loopback, and say how to start it when it does not.
public enum LocalServers {
    public enum Role: String, Sendable { case whisper, cleanup }

    public struct Target: Sendable, Equatable {
        public var role: Role
        public var url: URL
        public var model: String
        public var modeID: String
        /// The active mode's own engine (its chain would fail without it), not just a fallback or another mode's.
        public var needed: Bool
    }

    /// Every local-engine use across the config's modes, the active mode's first.
    public static func targets(_ config: VizierConfig) -> [Target] {
        let active = config.settings.mode
        var found: [Target] = []
        for mode in config.settings.modes {
            let isActive = mode.id == active
            var links: [(model: String, url: String?, primary: Bool)] = []
            if mode.transcriber.engine == "local-whisper" { links.append((mode.transcriber.model, mode.transcriber.url, true)) }
            for link in [mode.fallback, mode.offlineFallback].compactMap({ $0 }) where link.engine == "local-whisper" {
                links.append((link.model, link.url, false))
            }
            for link in links {
                found.append(Target(role: .whisper, url: link.url.flatMap(URL.init(string:)) ?? LocalWhisper.defaultURL,
                                    model: link.model, modeID: mode.id, needed: isActive && link.primary))
            }
            if let cleanup = mode.cleanup, cleanup.engine == "local-cleanup" {
                found.append(Target(role: .cleanup, url: cleanup.url.flatMap(URL.init(string:)) ?? LocalCleanup.defaultURL,
                                    model: cleanup.model, modeID: mode.id, needed: isActive))
            }
        }
        var seen = Set<String>()
        return found.sorted { ($0.modeID == active ? 0 : 1) < ($1.modeID == active ? 0 : 1) }
            .filter { seen.insert("\($0.role.rawValue) \($0.url.absoluteString)").inserted }
    }

    /// True when something accepts a TCP connection at the URL's loopback host and port.
    public static func answers(_ url: URL, timeoutMs: Int32 = 400) -> Bool {
        guard Loopback.allows(url) else { return false }
        let port = UInt16(url.port ?? 80)
        let host = url.host()?.lowercased() ?? "127.0.0.1"
        let ipv6 = host.contains(":")
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { Glibc.close(fd) }
        var result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6); address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
            result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, timeoutMs) == 1 else { return false }
        var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
    }

    public struct Check: Sendable, Equatable {
        public var name: String
        public var status: String
        public var detail: String
        public var fix: String
    }

    public static let modelFolder = "~/.local/share/vizier/models"

    /// One check per distinct server a mode uses. A server the active mode needs is a `fail` when
    /// down; one that is only a fallback or belongs to another mode is a `warn`.
    public static func checks(_ config: VizierConfig, environment: [String: String], answers probe: (URL) -> Bool = { LocalServers.answers($0) }) -> [Check] {
        targets(config).map { target in
            let name = target.role == .whisper ? "local_whisper" : "local_cleanup"
            let who = target.needed ? "the active mode (\(target.modeID))" : "mode \(target.modeID)"
            let place = "\(target.url.host() ?? "127.0.0.1"):\(target.url.port ?? 80)"
            if !Loopback.allows(target.url) {
                return Check(name: name, status: "fail", detail: "\(target.url.absoluteString) is not a loopback address (127.0.0.1 or [::1]); local engines refuse anything else.", fix: "vizier config path")
            }
            if probe(target.url) {
                return Check(name: name, status: "ok", detail: "\(place) answers; used by \(who).", fix: "")
            }
            let status = target.needed ? "fail" : "warn"
            switch target.role {
            case .whisper:
                let file = "ggml-\(target.model).bin"
                let binary = ProcessRunner.resolve("whisper-server", environment: environment)
                let port = target.url.port ?? 8738
                let path = target.url.path.isEmpty ? "/v1/audio/transcriptions" : target.url.path
                let detail = "Nothing answers at \(place), used by \(who); it needs whisper.cpp's whisper-server with the \(target.model) model (\(file))." + (binary == nil ? " whisper-server is not on PATH." : "")
                let fix = "Build whisper.cpp (https://github.com/ggml-org/whisper.cpp) so whisper-server is on PATH; download the model: curl -L --create-dirs -o \(modelFolder)/\(file) https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file) ; start it: whisper-server -m \(modelFolder)/\(file) --host 127.0.0.1 --port \(port) --inference-path \(path)"
                return Check(name: name, status: status, detail: detail, fix: fix)
            case .cleanup:
                let detail = "Nothing answers at \(place), used by \(who) for cleanup; it needs an OpenAI-style chat server (for example llama.cpp's llama-server) serving the \(target.model) model."
                let fix = "Start your cleanup model server on \(place) (for example: llama-server -m <model.gguf> --host 127.0.0.1 --port \(target.url.port ?? 8747)), or choose a mode without it: vizier config set mode <id>"
                return Check(name: name, status: status, detail: detail, fix: fix)
            }
        }
    }
}

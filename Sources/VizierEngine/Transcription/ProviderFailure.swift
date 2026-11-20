import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Metadata safe to include in take logs and benchmarks. Provider messages, WebSocket reasons,
/// and NSError descriptions can echo input or include a request URL.
enum ProviderFailure {
    /// Return the matching literal from our list; never forward a provider's own string.
    static func knownName(_ name: String?, among names: [String]) -> String? {
        names.first { $0 == name }
    }

    static func http(_ status: Int, detail: String? = nil) -> String {
        let code = "HTTP \(status)"
        return detail.map { "\(code): \($0)" } ?? code
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        let kind = error.domain == NSURLErrorDomain ? "network error" : "transport error"
        return "\(kind) \(error.code)"
    }

    static func describe(_ error: Error, on socket: URLSessionWebSocketTask) -> String {
        var parts: [String] = []
        if socket.closeCode != .invalid {
            parts.append("closed \(socket.closeCode.rawValue)")
        }
        if let http = socket.response as? HTTPURLResponse, http.statusCode != 101 {
            parts.append(Self.http(http.statusCode))
        }
        parts.append(Self.describe(error))
        return parts.joined(separator: ": ")
    }
}

import Foundation
import Network
import Testing
@testable import Vizier

/// The key test sends `xi-api-key` or `x-goog-api-key` in a header, which URLSession copies onto a
/// redirected request. Its session must refuse every redirect, so a cross-host `Location` never
/// sees the key.
@Suite struct KeyTestRedirectTests {
    @Test(arguments: [301, 302, 307, 308])
    func aCrossHostRedirectNeverReceivesTheKey(status: Int) async throws {
        let server = try await KeyRedirectServer.start(status: status)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("test-key", forHTTPHeaderField: "xi-api-key")
        request.setValue("test-key", forHTTPHeaderField: "x-goog-api-key")
        let (_, response) = try await NetworkKeyTester().fetch(request)
        #expect((response as? HTTPURLResponse)?.statusCode == status)
        #expect(server.seen.map(\.path) == ["/start"])
        #expect(!server.seen.contains { $0.path == "/stolen" && $0.hadKey })
        #expect(server.seen.first?.hadKey == true)
        #expect(NetworkKeyTester.result(forStatus: status) == .unreachable("the service answered \(status)"))
    }
}

/// A one-route HTTP server on 127.0.0.1: `/start` answers a redirect to `localhost` (another host
/// name for the same listener), anything else 200. It records each request's path and whether it
/// carried a key header.
nonisolated final class KeyRedirectServer: @unchecked Sendable {
    struct Seen { var path: String; var hadKey: Bool }
    private let listener: NWListener
    private let status: Int
    private let queue = DispatchQueue(label: "key-redirect-server")
    private let lock = NSLock()
    private var requests: [Seen] = []
    var seen: [Seen] { lock.withLock { requests } }
    var port: UInt16 { listener.port!.rawValue }

    private init(status: Int) throws {
        self.status = status
        // Loopback only, both families, so `localhost` reaches it whichever address it resolves to.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    static func start(status: Int) async throws -> KeyRedirectServer {
        let server = try KeyRedirectServer(status: status)
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = NSLock()
            nonisolated(unsafe) var done = false
            server.listener.stateUpdateHandler = { state in
                resumed.withLock {
                    guard !done else { return }
                    switch state {
                    case .ready: done = true; continuation.resume()
                    case .failed(let error): done = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let lines = text.split(separator: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let hadKey = lines.contains { $0.lowercased().hasPrefix("xi-api-key:") || $0.lowercased().hasPrefix("x-goog-api-key:") }
            lock.withLock { requests.append(Seen(path: path, hadKey: hadKey)) }
            let reply = path == "/start"
                ? "HTTP/1.1 \(status) Moved\r\nLocation: http://localhost:\(port)/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

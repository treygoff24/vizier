#if os(Linux)
import Foundation
import Glibc

/// One loopback connection, with a bounded blocking reader on its own queue. No real audio or keys.
final class WebSocketTestServer: @unchecked Sendable {
    enum Provider: String, CaseIterable, Sendable { case scribe, gemini }
    enum Behavior: Sendable {
        case happy, refuse(Int), close(UInt16, String), dropDuringSend, dropDuringFinish, silent, neverSetup
    }
    struct Frame: Sendable { let opcode: UInt8; let data: Data; let masked: Bool }
    struct Snapshot: Sendable {
        var frames: [Frame] = []
        var upgraded = false
        var droppedDuringPayload = false
        var error: String?
    }
    let endpoint: URL
    private let listener: Int32
    private let lock = NSLock()
    private var listenerOpen = true
    private var client: Int32 = -1
    private var stopped = false
    private var state = Snapshot()
    private let finished = DispatchSemaphore(value: 0)

    init(provider: Provider, behavior: Behavior) throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { Glibc.close(fd); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Glibc.close(fd); throw POSIXError(.EIO) }
        listener = fd
        endpoint = URL(string: "ws://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/test")!
        DispatchQueue(label: "websocket-test-\(address.sin_port)").async { [self] in
            defer { finished.signal() }
            serve(provider, behavior)
        }
    }

    var snapshot: Snapshot { lock.withLock { state } }

    /// Shutdown wakes accept/recv; the worker owns close, avoiding descriptor-reuse races.
    func stop() {
        lock.withLock {
            stopped = true
            if listenerOpen { _ = shutdown(listener, Int32(SHUT_RDWR)) }
            if client >= 0 { _ = shutdown(client, Int32(SHUT_RDWR)) }
        }
        if finished.wait(timeout: .now() + 4) == .timedOut {
            lock.withLock { state.error = "server worker did not stop" }
        }
    }

    private func serve(_ provider: Provider, _ behavior: Behavior) {
        defer { lock.withLock { listenerOpen = false; Glibc.close(listener) } }
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        lock.withLock { client = fd; if stopped { _ = shutdown(fd, Int32(SHUT_RDWR)) } }
        defer { lock.withLock { client = -1; Glibc.close(fd) } }
        // A backstop only: stop() wakes a blocked recv or send with shutdown. A recv that times out
        // fails with EAGAIN and is recorded as a server error, so the bound must outlast any pause a
        // healthy client can take. With the whole suite running on a 2-vCPU runner, the client's
        // tasks have waited over 2 s for a cooperative thread at startup; 3 s was too tight.
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        do {
            var header = Data()
            while header.suffix(4) != Data("\r\n\r\n".utf8) {
                guard header.count < 16_384 else { throw POSIXError(.EMSGSIZE) }
                header += try read(fd, count: 1)
            }
            if case .refuse(let status) = behavior {
                try write(fd, Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            guard let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else {
                throw POSIXError(.EINVAL)
            }
            let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            let acceptKey = Self.sha1(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)).base64EncodedString()
            try write(fd, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n".utf8))
            lock.withLock { state.upgraded = true }
            if provider == .scribe, !isNeverSetup(behavior) { try message(fd, #"{"message_type":"session_started"}"#) }
            // Ping exercises Foundation's automatic pong without using a provider message.
            try frame(fd, opcode: 9, data: Data("probe".utf8))
            var firstAudio = true
            var applicationFrames = 0
            while true {
                let prefix = try read(fd, count: 2)
                let opcode = prefix[0] & 15
                let masked = prefix[1] & 128 != 0
                var size = UInt64(prefix[1] & 127)
                if size == 126 { size = try read(fd, count: 2).reduce(0) { ($0 << 8) | UInt64($1) } }
                if size == 127 { size = try read(fd, count: 8).reduce(0) { ($0 << 8) | UInt64($1) } }
                guard size <= 4_000_000, masked else { throw POSIXError(.EINVAL) }
                let mask = try read(fd, count: 4)
                if opcode == 1 || opcode == 2 { applicationFrames += 1 }
                if case .dropDuringSend = behavior, applicationFrames == (provider == .scribe ? 1 : 3), opcode == 1 {
                    // Drop after the header and masking key, before draining the audio payload.
                    lock.withLock { state.droppedDuringPayload = true }
                    reset(fd)
                    return
                }
                let payload = try read(fd, count: Int(size))
                let data = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
                lock.withLock { state.frames.append(Frame(opcode: opcode, data: data, masked: masked)) }
                if opcode == 8 { try frame(fd, opcode: 8, data: data); return }
                if opcode == 9 { try frame(fd, opcode: 10, data: data); continue }
                guard opcode == 1 || opcode == 2 else { continue }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if provider == .gemini, object["setup"] != nil, !isNeverSetup(behavior) {
                    try message(fd, #"{"setupComplete":{}}"#)
                }
                let realtime = object["realtimeInput"] as? [String: Any] ?? [:]
                let audio = provider == .scribe ? (object["commit"] as? Bool == false) : realtime["audio"] != nil
                let ending = provider == .scribe ? (object["commit"] as? Bool == true) : realtime["activityEnd"] != nil
                if audio, firstAudio {
                    firstAudio = false
                    if case .close(let code, let reason) = behavior {
                        try frame(fd, opcode: 8, data: Data([UInt8(code >> 8), UInt8(code & 255)]) + Data(reason.utf8))
                        continue // Keep TCP alive so the peer can process the close frame and acknowledge it.
                    }
                    if case .happy = behavior {
                        try message(fd, provider == .scribe ? #"{"message_type":"partial_transcript","text":"zorblex"}"# : #"{"serverContent":{"interimInputTranscription":{"text":"zorblex"}}}"#)
                    }
                }
                if ending {
                    if case .dropDuringFinish = behavior { reset(fd); return }
                    if case .happy = behavior {
                        if provider == .scribe {
                            try message(fd, #"{"message_type":"committed_transcript","text":"Zorblex."}"#, binary: true)
                        } else {
                            try message(fd, #"{"serverContent":{"inputTranscription":{"text":"Zorblex."}}}"#, binary: true)
                            try message(fd, #"{"serverContent":{"generationComplete":true}}"#)
                        }
                    }
                }
            }
        } catch {
            // EOF after client settlement is expected; protocol/setup errors remain inspectable.
            if let posix = error as? POSIXError, posix.code == .ECONNRESET { return }
            lock.withLock { if !stopped { state.error = String(describing: error) } }
        }
    }

    private func isNeverSetup(_ behavior: Behavior) -> Bool { if case .neverSetup = behavior { true } else { false } }
    private func reset(_ fd: Int32) {
        var value = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &value, socklen_t(MemoryLayout<linger>.size))
    }
    private func read(_ fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(n == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += n
        }
        return Data(bytes)
    }
    private func write(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Glibc.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += n
        }
    }
    private func message(_ fd: Int32, _ text: String, binary: Bool = false) throws {
        try frame(fd, opcode: binary ? 2 : 1, data: Data(text.utf8))
    }
    private func frame(_ fd: Int32, opcode: UInt8, data: Data) throws {
        var header = Data([128 | opcode])
        if data.count < 126 { header.append(UInt8(data.count)) }
        else if data.count <= 65535 {
            header.append(126); header.append(UInt8(data.count >> 8)); header.append(UInt8(data.count & 255))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(data.count) >> shift) & 255)) }
        }
        try write(fd, header + data)
    }

    // RFC 3174 SHA-1, used only for the RFC 6455 upgrade (not for security).
    static func sha1(_ data: Data) -> Data {
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var bytes = Array(data)
        let bits = UInt64(bytes.count) * 8
        bytes.append(128)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bits >> shift) & 255)) }
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 { for j in 0..<4 { w[i] = (w[i] << 8) | UInt32(bytes[offset + i * 4 + j]) } }
            for i in 16..<80 { w[i] = rotate(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1) }
            var (a,b,c,d,e) = (h[0],h[1],h[2],h[3],h[4])
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5a827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6
                }
                let t = rotate(a,5) &+ f &+ e &+ k &+ w[i]
                (e,d,c,b,a) = (d,c,rotate(b,30),a,t)
            }
            for (i,v) in [a,b,c,d,e].enumerated() { h[i] = h[i] &+ v }
        }
        return Data(h.flatMap { x in [UInt8(x >> 24), UInt8((x >> 16) & 255), UInt8((x >> 8) & 255), UInt8(x & 255)] })
    }
}
#endif

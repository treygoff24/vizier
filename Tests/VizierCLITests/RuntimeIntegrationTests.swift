import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

/// A loopback HTTP server that answers every POST with a fixed whisper transcript and keeps the
/// bodies it was sent.
final class StubWhisperServer: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var descriptor: Int32 = -1
    private let transcript: String
    private(set) var port: UInt16 = 0

    init(transcript: String) {
        self.transcript = transcript
        descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        precondition(bound == 0 && listen(descriptor, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        let listener = descriptor
        let thread = Thread { [unowned self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                self.serve(client)
            }
        }
        thread.start()
    }

    var url: String { "http://127.0.0.1:\(port)/v1/audio/transcriptions" }
    var requestBodies: [Data] { lock.withLock { bodies } }

    func stop() { shutdown(descriptor, Int32(SHUT_RDWR)); Glibc.close(descriptor) }

    private func serve(_ client: Int32) {
        defer { Glibc.close(client) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>?
        var expected = 0
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { return }
            data.append(contentsOf: buffer.prefix(n))
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self).lowercased()
                expected = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            }
            if let headerEnd, data.count - headerEnd.upperBound >= expected {
                lock.withLock { bodies.append(Data(data[headerEnd.upperBound...])) }
                let body = Data("{\"text\": \"\(transcript)\"}".utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                let reply = Data(head.utf8) + body
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, Int32(MSG_NOSIGNAL)) }
                return
            }
        }
    }
}

@Suite(.serialized) @MainActor struct RuntimeIntegrationTests {
    func settings(url: String) -> String {
        """
        {
          "mode": "local",
          "modes": [
            {
              "id": "local", "name": "Local",
              "transcriber": { "engine": "local-whisper", "model": "large-v3-turbo", "mode": "verbatim", "languages": ["en"], "final_timeout_ms": 4000, "url": "\(url)" },
              "remove_fillers": false
            }
          ]
        }
        """
    }

    /// Synthetic speech: 1.5 s of a 220 Hz tone as a WAV the fake recorder will play back.
    func makeRecording(in directory: URL) throws -> URL {
        let url = directory.appending(path: "tone.wav")
        let writer = try WAVWriter(url: url)
        var samples = [Int16](repeating: 0, count: 24_000)
        for index in samples.indices { samples[index] = Int16(10_000 * sin(2 * Double.pi * 220 * Double(index) / 16_000)) }
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        _ = try writer.close()
        return url
    }

    /// Everything the daemon runs on: a stub whisper server, a fake recorder, fake clipboard and key tools.
    @MainActor final class World {
        let root: URL, config: URL, data: URL
        let stub = StubWhisperServer(transcript: "hello from the stub")
        let bins = FakeBins()
        var environment: [String: String] = [:]
        var options: LinuxRuntime.Options

        init(_ owner: RuntimeIntegrationTests) throws {
            root = URL(fileURLWithPath: "/tmp/vzrt-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            config = root.appending(path: "config"); data = root.appending(path: "data")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try Data(owner.settings(url: stub.url).utf8).write(to: config.appending(path: "vizier.jsonc"))
            // The fake recorder: the WAV's samples (past its 44-byte header) on stdout, then silence until killed.
            let wav = try owner.makeRecording(in: root)
            let recorder = root.appending(path: "fake-record")
            try Data("#!/bin/sh\n/usr/bin/tail -c +45 '\(wav.path)'\nexec /bin/sleep 30\n".utf8).write(to: recorder)
            chmod(recorder.path, 0o755)
            // The fake desktop tools: an X11 clipboard (xclip, with read-back) and xdotool for the paste keys.
            bins.addClipboardTool("xclip")
            bins.add("xdotool", reads: false)
            environment = bins.environment(["DISPLAY": ":99", "XDG_RUNTIME_DIR": root.path])
            options = LinuxRuntime.Options(environment: environment, configDirectory: config, dataDirectory: data)
            options.recorderCommand = [recorder.path]
            options.desktop = DesktopSession(display: .x11, family: .other, currentDesktop: "")
            options.silent = true
            options.soundsEnabled = false
            options.useSecretService = false
            options.usePortals = false
            options.hotkey = .none
            options.prePasteDelay = .milliseconds(1)
        }

        var historyURL: URL { data.appending(path: "history.sqlite") }
        var takesRoot: URL { data.appending(path: "Takes") }

        func cleanup() { stub.stop(); try? FileManager.default.removeItem(at: root) }
        func call(_ command: String) async throws -> Reply {
            let environment = environment
            return try await Task.detached { try SocketClient.call(Request(cmd: command), environment: environment) }.value
        }
    }

    @Test func toggleTwiceRecordsTranscribesPastesAndWritesHistory() async throws {
        let world = try World(self); defer { world.cleanup() }
        let bins = world.bins, stub = world.stub
        let control = try await LinuxRuntime.make(world.options)
        let handler = CommandHandler(control: control, config: ConfigStore(directory: world.config), historyURL: world.historyURL, takesRoot: world.takesRoot, environment: world.environment)
        let daemon = Daemon(handler: handler)
        try daemon.start(); try daemon.publish()
        defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let historyURL = world.historyURL, takesRoot = world.takesRoot
        func call(_ command: String) async throws -> Reply { try await world.call(command) }

        // Recovery of earlier takes runs first; a command before it ends is refused with startup_not_ready.
        var first: Reply?
        for _ in 0..<100 {
            let reply = try await call("toggle")
            if reply.error?.code != "startup_not_ready" { first = reply; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let started = try #require(first)
        #expect(started.ok && (started.result?["phase"] == .string("recording") || started.result?["phase"] == .string("arming")))
        try await Task.sleep(for: .milliseconds(900))
        let stopped = try await call("toggle")
        #expect(stopped.ok && stopped.result?["phase"] == .string("finalizing"))

        // Delivery lands asynchronously: wait for the take to end.
        var ending: JSONValue?
        for _ in 0..<200 {
            let status = try await call("status")
            if status.result?["phase"] == .string("idle"), let last = status.result?["lastEnding"], last != .null { ending = last; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let end = try #require(ending, "the take never ended")
        #expect(end["result"]?["pasted"] != nil, "ending: \(end)")

        // History has the take, with its outcome and text; `last` reads it back.
        let history = try HistoryStore(readingOnly: historyURL, takesRoot: takesRoot)
        let records = try history.search("", outcomes: nil, limit: 5, before: nil)
        #expect(records.count == 1)
        #expect(records.first?.outcome == .pasted)
        #expect(records.first?.finalText == "hello from the stub")
        #expect(records.first?.transcriberEngine == "local-whisper")
        let last = try await call("last")
        #expect(last.result?["take"]?["text"] == .string("hello from the stub"))

        // The stub got the saved audio as FLAC; the paste helpers got the text and the paste chord.
        // The audio is kept under <data>/Takes (the folder history and recovery read), as FLAC.
        let kept = FileManager.default.enumerator(atPath: world.takesRoot.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".flac") } ?? []
        #expect(kept.count == 1, "kept audio: \(kept)")
        // (The engine also sends the server body-less warm-up requests; only the upload has a body.)
        let uploads = stub.requestBodies.filter { !$0.isEmpty }
        #expect(uploads.count == 1)
        #expect(uploads.first.map { $0.range(of: Data("fLaC".utf8)) != nil } == true, "the upload carries a FLAC stream")
        #expect(bins.stdin("xclip")?.trimmingCharacters(in: .whitespaces) == "hello from the stub")
        #expect(bins.argv("xdotool").contains { $0.contains("ctrl+v") })
        #expect(bins.argv("xclip").contains { $0.contains("-in") })
    }

    @Test func theGlobalShortcutDrivesTheSessionAndStopsWithTheDaemon() async throws {
        let world = try World(self); defer { world.cleanup() }
        let hotkey = FakeHotkey()
        var options = world.options
        options.hotkey = .source(hotkey)
        let control = try await LinuxRuntime.make(options)
        for _ in 0..<100 where !hotkey.started { try await Task.sleep(for: .milliseconds(20)) }
        #expect(hotkey.started && control.hotkeyDetail == "fake-hotkey active")
        // Recovery must finish before commands are accepted; then the shortcut's toggle starts a take.
        for _ in 0..<100 where !control.session.isReady { try await Task.sleep(for: .milliseconds(20)) }
        hotkey.fireToggle()
        #expect([.arming, .recording].contains(control.status().phase))
        hotkey.fireCancel()
        #expect(control.status().phase == .idle)
        #expect(control.status().lastEnding?.result == .cancelled)
        // Quiesce (the daemon's SIGTERM path) takes the shortcut down first.
        #expect(await control.quiesce(until: .now + .seconds(3)))
        #expect(hotkey.stopped)
    }

    @Test func aDesktopWithoutAPortalLeavesTheHotkeyToTheCompositorBinds() async throws {
        let world = try World(self); defer { world.cleanup() }
        let control = try await LinuxRuntime.make(world.options)
        #expect(control.hotkeyDetail.contains("vizier toggle"))
        _ = await control.quiesce(until: .now + .seconds(1))
    }

    @Test func acceptedClientsAreCloseOnExecAndNonblocking() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        func socketFDs() -> [Int32: String] {
            var found: [Int32: String] = [:]
            for name in (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? [] {
                guard let fd = Int32(name), let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(name)"), target.hasPrefix("socket:") else { continue }
                found[fd] = target
            }
            return found
        }
        func flags(_ fd: Int32) -> Int? {
            guard let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(fd)", encoding: .utf8),
                  let line = info.split(separator: "\n").first(where: { $0.hasPrefix("flags:") }) else { return nil }
            return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces), radix: 8)
        }
        let before = socketFDs()
        let root = rig.root.path
        // A client that stays connected while the daemon's side is inspected.
        let client = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
        defer { Glibc.close(client) }
        let connected = try socketAddress(root + "/vizier/vizier.sock") { connect(client, $0, $1) }
        #expect(connected == 0)
        var accepted: [Int32: String] = [:]
        for _ in 0..<100 {
            accepted = socketFDs().filter { before[$0.key] == nil && $0.key != client }
            if !accepted.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!accepted.isEmpty, "the daemon never accepted the client")
        for (fd, _) in accepted {
            let value = try #require(flags(fd))
            #expect(value & 0o2000000 != 0, "accepted fd \(fd) is not close-on-exec")
            #expect(value & 0o4000 != 0, "accepted fd \(fd) is blocking")
        }
        _ = root
    }
}

@MainActor
final class FakeHotkey: HotkeySource, @unchecked Sendable {
    let name = "fake-hotkey"
    private(set) var started = false, stopped = false
    private var toggle: (@MainActor @Sendable () -> Void)?, cancel: (@MainActor @Sendable () -> Void)?

    nonisolated func probe() async -> AdapterProbe { AdapterProbe(name: "fake-hotkey", available: true, detail: "fake") }
    func start(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) async throws {
        toggle = onToggle; cancel = onCancel; started = true
    }
    func stop() async { stopped = true }
    func fireToggle() { toggle?() }
    func fireCancel() { cancel?() }
}

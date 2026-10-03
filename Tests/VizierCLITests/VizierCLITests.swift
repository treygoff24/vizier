import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

@MainActor
final class FakeTakeControl: TakeControl {
    var value = TakeStatus(phase: .idle, takeID: nil, seconds: 0, mode: "local", lastEnding: nil)
    var refusal: TakeCommandError?
    var cancellations = 0
    var quiesceDelay: Duration = .zero
    var quiescing = false
    var commands: [String] = []
    func status() -> TakeStatus { value }
    func toggle() throws(TakeCommandError) -> TakeStatus { commands.append("toggle"); if let refusal { throw refusal }; return value }
    func start() throws(TakeCommandError) -> TakeStatus { commands.append("start"); if let refusal { throw refusal }; value.phase = .recording; return value }
    func stop() throws(TakeCommandError) -> TakeStatus { commands.append("stop"); if let refusal { throw refusal }; value.phase = .finalizing; return value }
    func cancel() throws(TakeCommandError) -> TakeStatus { commands.append("cancel"); cancellations += 1; if let refusal { throw refusal }; value.phase = .idle; return value }
    func quiesce(until deadline: ContinuousClock.Instant) async -> Bool {
        commands.append("quiesce"); quiescing = true
        try? await Task.sleep(for: quiesceDelay)
        value.phase = .idle; quiescing = false; return true
    }
}

@MainActor
final class Rig {
    let root: URL
    let config: ConfigStore
    let history: HistoryStore
    let control = FakeTakeControl()
    let handler: CommandHandler
    var env: [String: String]
    init() throws {
        root = URL(fileURLWithPath: "/tmp/vz-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        config = ConfigStore(directory: root.appending(path: "config"))
        try config.writeStarterFilesIfMissing()
        history = try HistoryStore(databaseURL: root.appending(path: "history.sqlite"), takesRoot: root.appending(path: "takes"))
        env = ["XDG_RUNTIME_DIR": root.path, "PATH": "/usr/bin:/bin"]
        handler = CommandHandler(control: control, config: config, historyURL: root.appending(path: "history.sqlite"), takesRoot: root.appending(path: "takes"), environment: env)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func call(_ request: Request) async throws -> Reply {
        let env = env
        return try await Task.detached { try SocketClient.call(request, environment: env) }.value
    }
    func addTake(id: String, date: Date, text: String, outcome: TakeOutcome = .pasted) throws {
        try history.begin(TakeDraft(id: id, startedAt: date, destinationAtStart: nil, modeID: "local", transcriberEngine: "local-whisper", transcriberModel: "fake", fallbackEngine: nil, fallbackModel: nil, cleanerEngine: nil, cleanerModel: nil))
        try history.setStages(id: id, stages: TakeStages(raw: nil, cleaned: nil, final: text, route: "batch", transcriptionMs: nil, cleanupMs: nil, replacementMs: nil))
        try history.finish(id: id, stoppedAt: date.addingTimeInterval(1), outcome: outcome, reason: nil, destinationAtPaste: nil, pasteMethod: "fake", pasteMs: nil)
    }
}

// Runs raw framing I/O away from the daemon's MainActor. Short reads and EINTR are intentional.
func exchange(root: String, chunks: [Data], replies: Int) throws -> [Reply] {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { throw SocketClient.down() }
    defer { Glibc.close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = try socketAddress(root + "/vizier/vizier.sock") { connect(fd, $0, $1) }
    guard result == 0 else { throw SocketClient.down() }
    for chunk in chunks {
        var sent = 0
        while sent < chunk.count {
            let n = chunk.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: sent), chunk.count - sent, Int32(MSG_NOSIGNAL)) }
            guard n > 0 else { throw SocketClient.down() }; sent += n
        }
        usleep(20_000)
    }
    var data = Data(), values: [Reply] = [], buffer = [UInt8](repeating: 0, count: 4096)
    while values.count < replies {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw SocketClient.down() }
        data.append(contentsOf: buffer.prefix(n))
        while let end = data.firstIndex(of: 10) {
            values.append(try JSONDecoder().decode(Reply.self, from: data[..<end])); data.removeSubrange(...end)
        }
    }
    return values
}

func connected(_ root: String) throws -> Int32 {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard try socketAddress(root + "/vizier/vizier.sock", { connect(fd, $0, $1) }) == 0 else { Glibc.close(fd); throw SocketClient.down() }
    return fd
}
func receiveReply(_ fd: Int32) throws -> Reply {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while data.count < 16 * 1024 * 1024 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw SocketClient.down() }
        data.append(contentsOf: buffer.prefix(n))
        if let end = data.firstIndex(of: 10) { return try JSONDecoder().decode(Reply.self, from: data[..<end]) }
    }
    throw SocketClient.down()
}

@Suite("VizierCLITests")
struct VizierCLITests {
    @Test @MainActor func roundTripPermissionsAndCommands() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let pong = try await rig.call(Request(id: 17, cmd: "ping"))
        #expect(pong.v == 1 && pong.id == 17 && pong.ok && pong.result?["pong"] == .bool(true))
        let status = try await rig.call(Request(cmd: "status"))
        #expect(status.result?["daemon"] == .string("running"))
        #expect(status.result?["phase"] == .string("idle"))
        for command in ["start", "stop", "toggle", "cancel"] { #expect(try await rig.call(Request(cmd: command)).ok) }
        #expect(rig.control.commands == ["start", "stop", "toggle", "cancel"])
        var info = stat()
        #expect(lstat(rig.root.appending(path: "vizier").path, &info) == 0 && info.st_mode & 0o7777 == 0o700)
        #expect(lstat(rig.root.appending(path: "vizier/vizier.sock").path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
    }

    @Test(arguments: ["unset", "relative", "mode", "owner", "root_symlink", "child_symlink", "child_mode", "long"])
    @MainActor func runtimeRefusals(kind: String) throws {
        let rig = try Rig(); defer { rig.cleanup() }
        var env = rig.env
        switch kind {
        case "unset": env.removeValue(forKey: "XDG_RUNTIME_DIR")
        case "relative": env["XDG_RUNTIME_DIR"] = "relative"
        case "mode": #expect(chmod(rig.root.path, 0o755) == 0)
        case "owner": env["XDG_RUNTIME_DIR"] = "/proc" // root-owned, also not 0700
        case "root_symlink":
            let link = rig.root.appending(path: "link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.root); env["XDG_RUNTIME_DIR"] = link.path
        case "child_symlink": try FileManager.default.createSymbolicLink(at: rig.root.appending(path: "vizier"), withDestinationURL: rig.root)
        case "child_mode": try FileManager.default.createDirectory(at: rig.root.appending(path: "vizier"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        default: env["XDG_RUNTIME_DIR"] = "/" + String(repeating: "x", count: 110)
        }
        do { _ = try RuntimeDirectory(environment: env, create: true); Issue.record("Unsafe runtime accepted: \(kind)") }
        catch let error as CLIError { #expect(error.code == (kind == "long" ? "socket_path_too_long" : "runtime_dir_unavailable")) }
    }

    @Test @MainActor func secondDaemonCannotUnlinkLiveSocket() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let first = Daemon(handler: rig.handler); try first.start(); try first.publish(); defer { first.abort() }
        let loop = Task { await first.run() }; defer { loop.cancel() }
        let second = Daemon(handler: rig.handler)
        do { try second.start(); try second.publish(); second.abort(); Issue.record("Second daemon accepted") }
        catch let error as CLIError { #expect(error.code == "already_running") }
        #expect(try await rig.call(Request(cmd: "ping")).ok)
    }

    @Test @MainActor func staleSocketReplacedAndUnsafePathRefused() throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let runtime = try RuntimeDirectory(environment: rig.env, create: true)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0); defer { Glibc.close(fd) }
        #expect(try socketAddress(runtime.anchoredSocketPath) { bind(fd, $0, $1) } == 0)
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); daemon.abort()
        try Data("synthetic".utf8).write(to: rig.root.appending(path: "vizier/vizier.sock"))
        do { try daemon.start(); try daemon.publish(); daemon.abort(); Issue.record("Regular file at socket path accepted") }
        catch let error as CLIError { #expect(error.code == "unsafe_socket") }
        #expect(try String(contentsOf: rig.root.appending(path: "vizier/vizier.sock"), encoding: .utf8) == "synthetic")
    }

    @Test @MainActor func splitAndJoinedLines() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let a = try Wire.line(Request(id: 11, cmd: "start")), b = try Wire.line(Request(id: 12, cmd: "stop"))
        let root = rig.root.path
        let values = try await Task.detached { try exchange(root: root, chunks: [Data(a.prefix(8)), Data(a.dropFirst(8)) + b], replies: 2) }.value
        #expect(values.map(\.id) == [11, 12] && values.allSatisfy(\.ok))
        #expect(values[0].result?["phase"] == .string("recording") && values[1].result?["phase"] == .string("finalizing"))
    }

    @Test @MainActor func oversizeBadVersionMalformedAndDroppedClient() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let root = rig.root.path
        let huge = Data(repeating: 32, count: Wire.requestLimit + 1)
        let values = try await Task.detached { try exchange(root: root, chunks: [huge], replies: 1) }.value
        #expect(values.first?.error?.code == "request_too_large")
        let version = try await rig.call(Request(v: 2, id: 19, cmd: "start"))
        #expect(version.id == 19 && version.error?.code == "bad_version" && rig.control.commands.isEmpty)
        let malformed = try await Task.detached { try exchange(root: root, chunks: [Data("broken\n".utf8)], replies: 1) }.value
        #expect(malformed.first?.error?.code == "invalid_request")
        // Close before reading the reply; next client still succeeds (SIGPIPE must not terminate).
        _ = try await Task.detached { try exchange(root: root, chunks: [Data("partial".utf8)], replies: 0) }.value
        #expect(try await rig.call(Request(cmd: "ping")).ok)
    }

    @Test(arguments: [TakeCommandError.alreadyRecording, .notRecording, .busyFinalizing, .startupNotReady])
    @MainActor func stateRefusalMapping(error: TakeCommandError) async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        rig.control.refusal = error
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let reply = try await rig.call(Request(cmd: "start"))
        #expect(!reply.ok && reply.error?.code == error.rawValue && reply.exitCode == 4)
        let commands: [TakeCommandError: String] = [.alreadyRecording: "vizier stop", .notRecording: "vizier start", .busyFinalizing: "vizier status", .startupNotReady: "vizier doctor"]
        #expect(reply.error?.next == commands[error])
    }

    @Test @MainActor func daemonDownExitsAndHelp() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        do { _ = try await rig.call(Request(cmd: "status")); Issue.record("Down daemon accepted") }
        catch let error as CLIError {
            let reply = Reply(id: 1, error: error)
            #expect(error.code == "daemon_not_running" && error.next == "vizier daemon")
            #expect(CLI.render(reply, command: "status", json: true).exit == 3)
            #expect(CLI.render(reply, command: "status", json: false).stderr.contains("down"))
        }
        #expect(await CLI.run(["status", "--json"], environment: rig.env) == 3)
        #expect(try Invocation.parse(["status", "--json"]).json)
        #expect(try Invocation.parse(["--json", "status"]).json)
        #expect(try Invocation.parse([]).help)
        #expect(try Invocation.parse(["help", "history"]).command == "history")
        #expect(CLI.help("history").contains("--text"))
        #expect(throws: CLIError.self) { try Invocation.parse(["history", "--limit", "0"]) }
        #expect(CLIError("usage", "bad", next: "vizier --help").exitCode == 2)
        #expect(CLIError("storage_error", "bad", next: "vizier doctor").exitCode == 1)
    }

    @Test @MainActor func doctorJSONShape() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let reply = try await rig.call(Request(cmd: "doctor"))
        #expect(reply.ok)
        guard case .array(let checks) = reply.result?["checks"] else { Issue.record("checks missing"); return }
        #expect(Set(checks.compactMap { $0["name"]?.string }) == Set(["runtime_dir", "socket", "config", "history", "libcurl", "pw_record", "desktop_entry", "local_whisper", "take_session"]))  // the starter config's default mode is local whisper
        #expect(checks.allSatisfy { $0["status"]?.string != nil && $0["detail"]?.string != nil && ($0["status"] == .string("ok") ? $0["fix"] == .string("") : $0["fix"]?.string?.isEmpty == false) })
        #expect(checks.first { $0["name"] == .string("socket") }?["status"] == .string("ok"))
        #expect(checks.first { $0["name"] == .string("libcurl") }?["detail"]?.string?.contains("8.") == true)
        let output = CLI.render(reply, command: "doctor", json: true)
        let decoded = try JSONDecoder().decode(Reply.self, from: Data(output.stdout.utf8))
        #expect(decoded == reply)
        #expect(checks.first { $0["name"] == .string("take_session") }?["status"] == .string("ok"))
        rig.handler.control = UnavailableTakeControl(mode: "local")
        let unavailable = try await rig.call(Request(cmd: "doctor"))
        guard case .array(let unavailableChecks) = unavailable.result?["checks"] else { Issue.record("checks missing"); return }
        #expect(unavailableChecks.first { $0["name"] == .string("take_session") }?["detail"] == .string("not wired in this build"))
        #expect(output.exit == (reply.result?["healthy"]?.bool == true ? 0 : 5))
        try Data("{broken".utf8).write(to: rig.config.settingsURL)
        let badConfig = try await rig.call(Request(cmd: "doctor"))
        guard case .array(let badChecks) = badConfig.result?["checks"] else { Issue.record("checks missing"); return }
        #expect(badChecks.first { $0["name"] == .string("config") }?["status"] == .string("fail"))
    }

    @Test @MainActor func historyPrivacyPaginationLastAndConfig() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        try rig.addTake(id: "synthetic-a", date: Date(timeIntervalSince1970: 2000.100), text: "Synthetic alpha")
        try rig.addTake(id: "synthetic-b", date: Date(timeIntervalSince1970: 2000.100), text: "Synthetic beta", outcome: .rerouted)
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        let metadata = try await rig.call(Request(cmd: "history", args: ["limit": .number(1)]))
        guard case .array(let rows) = metadata.result?["takes"] else { Issue.record("history missing"); return }
        #expect(rows.count == 1 && rows[0]["id"] == .string("synthetic-b") && rows[0]["text"] == nil)
        let page = try await rig.call(Request(cmd: "history", args: ["before": metadata.result!["before"]!, "text": .bool(true)]))
        guard case .array(let older) = page.result?["takes"] else { Issue.record("page missing"); return }
        #expect(older.count == 1 && older[0]["text"] == .string("Synthetic alpha"))
        let last = try await rig.call(Request(cmd: "last"))
        #expect(last.result?["take"]?["text"] == .string("Synthetic beta"))
        #expect(CLI.render(last, command: "last", json: false).stdout == "Synthetic beta\n")
        let original = try String(contentsOf: rig.config.settingsURL, encoding: .utf8)
        #expect(original.contains("//"))
        #expect(try await rig.call(Request(cmd: "config", args: ["action": .string("set"), "mode": .string("scribe")])).ok)
        #expect(try rig.config.settingsSnapshot().settings.mode == "scribe")
        #expect(try String(contentsOf: rig.config.settingsURL, encoding: .utf8).contains("//"))
        #expect(try await rig.call(Request(cmd: "config", args: ["action": .string("path")])).result?["path"] == .string(rig.config.settingsURL.path))
        let get = try await rig.call(Request(cmd: "config", args: ["action": .string("get")]))
        #expect(get.result?["settings"]?["mode"] == .string("scribe") && get.result?["vocabulary"] == nil)
        #expect(try await rig.call(Request(cmd: "config", args: ["action": .string("set"), "mode": .string("absent")])).error?.code == "unknown_mode")
    }

    @Test @MainActor func unsafeSocketAndLockPermissions() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        #expect(chmod(rig.root.appending(path: "vizier/vizier.sock").path, 0o666) == 0)
        do { _ = try await rig.call(Request(cmd: "ping")); Issue.record("Public socket accepted") }
        catch let error as CLIError { #expect(error.code == "unsafe_socket") }
        daemon.abort()
        #expect(chmod(rig.root.appending(path: "vizier/daemon.lock").path, 0o644) == 0)
        do { try daemon.start(); try daemon.publish(); daemon.abort(); Issue.record("Public lock accepted") }
        catch let error as CLIError { #expect(error.code == "unsafe_lock") }
    }

    @Test @MainActor func unknownArgumentsAreNotApplied() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let loop = Task { await daemon.run() }; defer { loop.cancel() }
        #expect(try await rig.call(Request(cmd: "start", args: ["surprise": .bool(true)])).error?.code == "invalid_args")
        #expect(rig.control.commands.isEmpty)
        #expect(try await rig.call(Request(cmd: "unknown")).error?.code == "unknown_command")
        #expect(try await rig.call(Request(cmd: "history", args: ["text": .string("true")])).error?.code == "invalid_args")
        #expect(try await rig.call(Request(cmd: "history", args: ["limit": .number(1.5)])).error?.code == "invalid_args")
    }

    @Test(arguments: [SIGTERM, SIGINT]) @MainActor func signalShutdown(sig: Int32) async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let child = Process()
        let buildDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let binary = buildDirectory.appending(path: "vizier")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return } // tests-only builds omit the executable
        child.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_RUNTIME_DIR"] = rig.root.path
        environment["XDG_CONFIG_HOME"] = rig.root.appending(path: "child-config").path
        environment["XDG_DATA_HOME"] = rig.root.appending(path: "child-data").path
        child.environment = environment
        child.standardOutput = Pipe(); child.standardError = Pipe()
        child.arguments = ["daemon", "--json"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let socketPath = rig.root.appending(path: "vizier/vizier.sock").path
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(child.isRunning && FileManager.default.fileExists(atPath: socketPath))
        #expect(try await rig.call(Request(cmd: "ping")).ok)
        #expect(kill(child.processIdentifier, sig) == 0)
        for _ in 0..<200 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!child.isRunning)
        if child.isRunning { child.terminate(); return }
        #expect(child.terminationStatus == 0)
        let output = (child.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        if let first = output.split(separator: 10).first {
            let ready = try JSONDecoder().decode(Reply.self, from: Data(first))
            #expect(ready.result?["ready"] == .bool(true) && ready.result?["socket"] == .string(socketPath))
        } else { Issue.record("No ready signal") }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); daemon.abort()
    }

    @Test @MainActor func shutdownQuiescesAndReleasesLock() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish()
        rig.control.value.phase = .finalizing
        await daemon.shutdown()
        #expect(rig.control.commands == ["quiesce"] && !daemon.running)
        #expect(!FileManager.default.fileExists(atPath: rig.root.appending(path: "vizier/vizier.sock").path))
        #expect(rig.handler.handle(Request(cmd: "start")).error?.code == "shutting_down")
        let second = Daemon(handler: rig.handler); try second.start(); try second.publish(); second.abort()
        #expect(rig.control.commands == ["quiesce"])
    }
    @Test func runtimeOwnerBranchIsIndependentOfMode() throws {
        var info = stat(); info.st_uid = getuid() + 1; info.st_mode = S_IFDIR | 0o700
        #expect(throws: CLIError.self) { try RuntimeDirectory.validate(info, uid: getuid()) }
        info.st_uid = getuid()
        try RuntimeDirectory.validate(info, uid: getuid())
    }

    @Test @MainActor func capacityAndIdleDeadline() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler, capacity: 1, idleTimeout: 0.2)
        try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let root = rig.root.path
        let fd = try connected(root); defer { Glibc.close(fd) }
        let ping = try Wire.line(Request(cmd: "ping"))
        #expect(ping.withUnsafeBytes { send(fd, $0.baseAddress, ping.count, Int32(MSG_NOSIGNAL)) } == ping.count)
        #expect(try await Task.detached { try receiveReply(fd) }.value.ok)
        let refused = try await rig.call(Request(cmd: "start"))
        #expect(refused.error?.code == "daemon_busy" && refused.exitCode == 4)
        #expect(rig.control.commands.isEmpty)
        try await Task.sleep(for: .milliseconds(1300))
        let n = await Task.detached { () -> Int in var byte: UInt8 = 0; return recv(fd, &byte, 1, 0) }.value
        #expect(n == 0)
        #expect(try await rig.call(Request(cmd: "ping")).ok)
    }

    @Test @MainActor func publicationWaitsForInitialization() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let daemon = Daemon(handler: rig.handler); try daemon.start(); defer { daemon.abort() }
        #expect(!FileManager.default.fileExists(atPath: rig.root.appending(path: "vizier/vizier.sock").path))
        var info = stat()
        #expect(lstat(rig.root.appending(path: "vizier/vizier.sock.new").path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        do { _ = try await rig.call(Request(cmd: "ping")); Issue.record("Socket published before initialization") }
        catch let error as CLIError { #expect(error.code == "daemon_not_running") }
        try daemon.publish()
        #expect(try await rig.call(Request(cmd: "ping")).ok)
    }

    @Test @MainActor func quiesceHoldsLockAndFlushesReply() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let text = String(repeating: "synthetic ", count: 60_000)
        try rig.addTake(id: "synthetic-large", date: .now, text: text)
        rig.control.value.phase = .finalizing; rig.control.quiesceDelay = .milliseconds(150)
        let daemon = Daemon(handler: rig.handler); try daemon.start(); try daemon.publish(); defer { daemon.abort() }
        let fd = try connected(rig.root.path); defer { Glibc.close(fd) }
        let line = try Wire.line(Request(id: 42, cmd: "last"))
        #expect(line.withUnsafeBytes { send(fd, $0.baseAddress, line.count, Int32(MSG_NOSIGNAL)) } == line.count)
        // Peek proves the server queued a reply, leaving the large remainder under backpressure.
        let peek = await Task.detached { () -> Int in var byte: UInt8 = 0; return recv(fd, &byte, 1, Int32(MSG_PEEK)) }.value
        #expect(peek == 1)
        let draining = Task { await daemon.shutdown() }
        for _ in 0..<100 { if rig.control.quiescing { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(rig.control.quiescing)
        let contender = Daemon(handler: rig.handler)
        do { try contender.start(); contender.abort(); Issue.record("Lock released during quiesce") }
        catch let error as CLIError { #expect(error.code == "already_running") }
        #expect(rig.handler.handle(Request(cmd: "start")).error?.code == "shutting_down")
        while rig.control.quiescing { try await Task.sleep(for: .milliseconds(2)) }
        let reply = try await Task.detached { try receiveReply(fd) }.value
        #expect(reply.id == 42 && reply.result?["take"]?["text"]?.string?.count == text.count)
        await draining.value
        #expect(rig.control.commands == ["quiesce"] && !daemon.running)
        try contender.start(); contender.abort()
    }

    @Test @MainActor func localReadsAndCLIRecovery() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let data = rig.root.appending(path: "vizier")
        let localConfig = ConfigStore(directory: data); try localConfig.writeStarterFilesIfMissing()
        var env = rig.env
        env["XDG_CONFIG_HOME"] = rig.root.path; env["XDG_DATA_HOME"] = rig.root.path
        _ = try HistoryStore(databaseURL: data.appending(path: "history.sqlite"), takesRoot: data.appending(path: "takes"))
        for words in [["config", "path"], ["config", "get"], ["history"], ["last"]] {
            #expect(await CLI.run(words + ["--json"], environment: env) == 0)
        }
        #expect(await CLI.run(["config", "set", "mode", "scribe", "--json"], environment: env) == 3)
        #expect(try Invocation.parse(["--version", "--json"]).command == "version")
        #expect(await CLI.run(["--version", "--json"], environment: env) == 0)
        env.removeValue(forKey: "XDG_RUNTIME_DIR")
        #expect(await CLI.run(["config", "path", "--json"], environment: env) == 0)
        #expect(try Invocation.parse(["history", "--limit=5", "--before=2000:synthetic"]).args["limit"] == .number(5))
        let ending = TakeEnding(takeID: "synthetic", result: .held, remark: nil, endedAt: Date(timeIntervalSince1970: 1000))
        rig.control.value.lastEnding = ending
        #expect(CLI.render(rig.handler.handle(Request(cmd: "status")), command: "status", json: false).stdout.contains("synthetic"))
        do { _ = try Invocation.parse(["stats"]); Issue.record("Unknown command accepted") }
        catch let error as CLIError { #expect(error.next == "vizier status" && error.message.contains("Did you mean")) }
        var info = stat(); info.st_uid = getuid(); info.st_mode = S_IFDIR | 0o755
        do { try RuntimeDirectory.validate(info, uid: getuid()); Issue.record("Mode accepted") }
        catch let error as CLIError { #expect(error.next == "chmod 700 \"$XDG_RUNTIME_DIR\"") }
    }

}

struct VersionTests {
    /// `vizier version` reports the release the packages are stamped with: the VERSION file is the one source.
    @Test func theCLIReportsTheRepositoryVersion() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appending(path: "VERSION"), encoding: .utf8)
        let prefix = "MARKETING_VERSION="
        let declared = try #require(text.split(separator: "\n").first { $0.hasPrefix(prefix) })
        #expect(String(declared.dropFirst(prefix.count)) == VizierVersion.marketing)
    }
}

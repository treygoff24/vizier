import Foundation
import Glibc
import VizierEngine

public struct Invocation: Sendable {
    public var command: String
    public var args: [String: JSONValue]
    public var json: Bool
    public var help: Bool
    public static func parse(_ arguments: [String]) throws -> Invocation {
        let json = arguments.contains("--json")
        var words = arguments.filter { $0 != "--json" }.flatMap { word -> [String] in
            if word.hasPrefix("--limit=") || word.hasPrefix("--before=") {
                return word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            }
            return [word == "--version" ? "version" : word]
        }
        var help = words.contains("--help") || words.contains("-h")
        words.removeAll { $0 == "--help" || $0 == "-h" }
        if words.first == "help" { help = true; words.removeFirst() }
        if words.isEmpty { return Invocation(command: "help", args: [:], json: json, help: true) }
        let command = words.removeFirst()
        let known = ["daemon", "ping", "status", "toggle", "start", "stop", "cancel", "last", "history", "config", "doctor", "version", "key", "setup"]
        guard known.contains(command) else {
            let guess = ["stats": "status", "stat": "status", "hist": "history", "configuration": "config"][command]
            throw CLIError("usage", "Unknown command '\(command)'." + (guess.map { " Did you mean \($0)?" } ?? ""), next: guess.map { "vizier \($0)" } ?? "vizier --help")
        }
        if help { return Invocation(command: command, args: [:], json: json, help: true) }
        var args: [String: JSONValue] = [:]
        switch command {
        case "history":
            while !words.isEmpty {
                let option = words.removeFirst()
                guard args[option == "--text" ? "text" : String(option.dropFirst(2))] == nil else {
                    throw CLIError("usage", "Repeated history flag.", next: "vizier history --help")
                }
                switch option {
                case "--text": args["text"] = .bool(true)
                case "--limit":
                    guard !words.isEmpty, let n = Int(words.removeFirst()), (1...100).contains(n) else {
                        throw CLIError("usage", "--limit requires an integer from 1 to 100.", next: "vizier history --limit 20")
                    }
                    args["limit"] = .number(Double(n))
                case "--before":
                    guard !words.isEmpty, (CommandHandler.date(words[0]) != nil || CommandHandler.validCursor(words[0])) else {
                        throw CLIError("usage", "--before requires a history cursor or ISO 8601 time.", next: "vizier history --help")
                    }
                    args["before"] = .string(words.removeFirst())
                default: throw CLIError("usage", "Unknown history flag '\(option)'.", next: "vizier history --help")
                }
            }
        case "config":
            guard let action = words.first, ["path", "get", "set"].contains(action) else {
                throw CLIError("usage", "config requires path, get or set.", next: "vizier config get")
            }
            if action == "set" {
                guard words.count == 3, words[1] == "mode", !words[2].isEmpty else {
                    throw CLIError("usage", "Only the active mode may be set.", next: "vizier config set mode local")
                }
                args["mode"] = .string(words[2])
            } else if words.count != 1 { throw CLIError("usage", "Unexpected config argument.", next: "vizier config \(action)") }
            args["action"] = .string(action)
        case "key":
            // The key itself is never an argument: `set` reads it from stdin.
            guard let action = words.first, ["set", "status", "delete"].contains(action) else {
                throw CLIError("usage", "key requires set, status or delete.", next: "vizier key --help")
            }
            words.removeFirst()
            var piped = false
            if let at = words.firstIndex(of: "--stdin") { piped = true; words.remove(at: at) }
            let accounts = SecretAccount.allCases.map(\.rawValue)
            if let name = words.first {
                guard accounts.contains(name) else {
                    throw CLIError("usage", "Unknown key name; use \(accounts.joined(separator: " or ")). Keys are never accepted as arguments.", next: "vizier key --help")
                }
                args["account"] = .string(name); words.removeFirst()
            } else if action != "status" {
                throw CLIError("usage", "key \(action) needs a key name: \(accounts.joined(separator: " or ")).", next: "vizier key \(action) elevenlabs")
            }
            guard words.isEmpty else { throw CLIError("usage", "Unexpected key argument. Keys are never accepted as arguments; pipe the key on stdin.", next: "vizier key --help") }
            args["action"] = .string(action)
            if piped { args["stdin"] = .bool(true) }
        case "setup":
            for option in words {
                switch option {
                case "--autostart": args["autostart"] = .bool(true)
                case "--no-portal": args["noPortal"] = .bool(true)
                default: throw CLIError("usage", "Unknown setup flag '\(option)'.", next: "vizier setup --help")
                }
            }
        default:
            guard words.isEmpty else {
                let next = words.contains("--jsno") || words.contains("--jason") ? "vizier \(command) --json" : "vizier \(command) --help"
                throw CLIError("usage", "Unexpected argument '\(words[0])'.", next: next)
            }
        }
        return Invocation(command: command, args: args, json: json, help: false)
    }
}

public enum CLI {
    public static let overview = """
    Usage: vizier <command> [--json]
    One binary: daemon serves; all other commands use its private Unix socket.
    Commands:
      version             Print binary version and protocol version
      daemon              Run in foreground; stop with SIGTERM or Ctrl+C
      ping                Check daemon reachability
      status              Show phase, active mode and last ending; reports down
      start / stop        Start capture / accept stop (delivery continues)
      toggle / cancel     Start-or-stop / cancel an active take, preserving audio
      last                Print the last ended take's final text
      history             List metadata; --text explicitly includes final text
      config              path | get | set mode <id>
      doctor              Check runtime, socket, config, history, libcurl, pw-record, local servers
      setup               Probe this desktop, ask the portals for consent, write config and the autostart unit
      key                 set | status | delete <elevenlabs|gemini>; the key is read from stdin
    Options: --json (versioned envelope); --help or help <command>.
    Exit codes: 0 success; 1 other error; 2 usage; 3 daemon down;
                4 state refusal; 5 doctor found a failure.
    Environment: XDG_RUNTIME_DIR (absolute, user-owned 0700; no /tmp fallback),
                 XDG_CONFIG_HOME, XDG_DATA_HOME, PATH.
    First steps: vizier daemon; vizier doctor --json; vizier status --json.
    See docs/cli.md for schemas. Related: vizier <command> --help.
    """
    public static func help(_ command: String) -> String {
        let detail: String
        switch command {
        case "version": detail = "Usage: vizier version [--json] (alias: --version)\nReports binary and wire protocol versions without a daemon."
        case "history": detail = "Usage: vizier history [--limit 1..100] [--before <cursor-or-ISO8601>] [--text] [--json]\nDefault limit 20. Newest first; use result.before for the next page. Text is opt-in.\nExample: vizier history --limit 5 --json\nRelated: vizier last"
        case "config": detail = "Usage: vizier config path|get|set mode <id> [--json]\nget returns settings only, without vocabulary or replacements. set preserves comments.\nExample: vizier config set mode local --json\nRelated: vizier config get; vizier status"
        case "daemon": detail = "Usage: vizier daemon [--json]\nForeground daemon; SIGINT/SIGTERM finish active audio work before releasing the socket lock.\nRequires user-owned 0700 XDG_RUNTIME_DIR. Existing daemon: vizier status.\nCommands are refused with startup_not_ready until crash recovery of earlier takes finishes."
        case "setup": detail = "Usage: vizier setup [--autostart] [--no-portal] [--json]\nProbes the desktop, microphone capture, paste route, hotkey, keys and local whisper; asks the GNOME/KDE/Hyprland portals for consent; writes the starter config; installs ~/.config/systemd/user/vizier.service (--autostart also enables it) and prints compositor binds.\nRun it from a terminal inside your desktop session, before the first take.\nRelated: vizier doctor; vizier key set gemini"
        case "key": detail = "Usage: vizier key set|status|delete <elevenlabs|gemini> [--stdin] [--json]\nset reads the key from stdin only (hidden prompt on a terminal, or pipe it); it is never an argument. Stored in Secret Service when available, else ~/.config/vizier/keys.json (0600).\nstatus says where each key resolves from (VIZIER_ELEVENLABS_API_KEY / VIZIER_GEMINI_API_KEY, secret-service, file) and never prints it.\nExample: printf %s \"$KEY\" | vizier key set gemini --stdin\nRelated: vizier doctor"
        case "stop": detail = "Usage: vizier stop [--json]\nAccept stop immediately; poll vizier status for delivery. Refused when idle or finalizing.\nRelated: vizier cancel; vizier last"
        case "last": detail = "Usage: vizier last [--json]\nPrint final text from the newest ended take. No takes: empty output, exit 0.\nRelated: vizier history --text"
        case "doctor": detail = "Usage: vizier doctor [--json]\nOffline structured checks with fix commands; exit 5 if any fails. Works with daemon down.\nRelated: vizier daemon; vizier config path"
        case "status": detail = "Usage: vizier status [--json]\nReport daemon running/down, take phase, seconds, mode and last ending; down exits 3.\nRelated: vizier daemon; vizier doctor"
        case "ping", "start", "toggle", "cancel": detail = "Usage: vizier \(command) [--json]\nRun \(command) through the daemon; refusal includes the next command.\nRelated: vizier status; vizier doctor"
        default: return overview
        }
        return detail + "\n--json is accepted before or after the command.\nExits: 0 ok, 1 error, 2 usage, 3 down, 4 refusal, 5 doctor failure."
    }
    /// Converts all output to a single predictable stdout envelope in JSON mode.
    public static func render(_ reply: Reply, command: String, json: Bool) -> (stdout: String, stderr: String, exit: Int32) {
        if json {
            let text = (try? Wire.encoder().encode(reply)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let diagnostic = reply.error.map { "\($0.message) Next: \($0.next)\n" } ?? ""
            return (text + "\n", diagnostic, reply.exitCode)
        }
        if let error = reply.error { return ("", "\(error.message) Next: \(error.next)\n", error.exitCode) }
        if command == "version" { return ("Vizier \(reply.result?["version"]?.string ?? "unknown") (protocol 1)\n", "", reply.exitCode) }
        if command == "last" { return (reply.result?["take"]?["text"]?.string.map { $0 + "\n" } ?? "", "", reply.exitCode) }
        if command == "status", let result = reply.result {
            let ending: String
            if let last = result["lastEnding"], last != .null {
                let bytes = try? Wire.encoder().encode(last)
                ending = " Last ending: " + (bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown")
            } else { ending = " Last ending: none." }
            return ("Daemon running; \(result["phase"]?.string ?? "unknown"); mode \(result["mode"]?.string ?? "unknown"); \(result["seconds"]?.number ?? 0) seconds.\(ending)\n", "", reply.exitCode)
        }
        if command == "doctor", case .array(let checks) = reply.result?["checks"] {
            return (checks.map { "\($0["name"]?.string ?? ""): \($0["status"]?.string ?? "") - \($0["detail"]?.string ?? "")" + (($0["fix"]?.string ?? "").isEmpty ? "" : "\n  Fix: \($0["fix"]?.string ?? "")") }.joined(separator: "\n") + "\n", "", reply.exitCode)
        }
        if command == "config", let path = reply.result?["path"]?.string, reply.result?["settings"] == nil, reply.result?["mode"] == nil {
            return (path + "\n", "", reply.exitCode)
        }
        if command == "ping" { return ("Daemon responds.\n", "", reply.exitCode) }
        // Pretty JSON is also readable for metadata and accepted state snapshots.
        let encoder = Wire.encoder(); encoder.outputFormatting.insert(.prettyPrinted)
        let text = reply.result.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (text + "\n", "", reply.exitCode)
    }

    @MainActor
    public static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                           makeControl: (@MainActor () async throws -> any TakeControl)? = nil) async -> Int32 {
        let json = arguments.contains("--json")
        do {
            let invocation = try Invocation.parse(arguments)
            if invocation.help {
                let text = help(invocation.command)
                if json { emit(render(Reply(id: 1, result: .object(["help": .string(text)])), command: "help", json: true)) }
                else { print(text) }
                return 0
            }
            if invocation.command == "version" {
                let reply = Reply(id: 1, result: .object(["version": .string(VizierVersion.marketing), "protocol": .number(1)]))
                emit(render(reply, command: "version", json: json)); return 0
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            func base(_ key: String, _ fallback: URL) -> URL {
                if let path = environment[key], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
                return fallback
            }
            let config = ConfigStore(directory: base("XDG_CONFIG_HOME", home.appending(path: ".config")).appending(path: "vizier"))
            let data = base("XDG_DATA_HOME", home.appending(path: ".local/share")).appending(path: "vizier")
            let historyURL = data.appending(path: "history.sqlite"), takesRoot = data.appending(path: "Takes")
            if invocation.command == "key" {
                let reply = KeyCommand.run(args: invocation.args.mapValues { $0 }, environment: environment, configDirectory: config.directory)
                if reply.error == nil, ["set", "delete"].contains(invocation.args["action"]?.string) {
                    // Best effort: a running daemon re-reads its keys now rather than at its next timer.
                    _ = try? await Task.detached { try SocketClient.call(Request(cmd: "keys_changed"), environment: environment) }.value
                }
                if json || reply.error != nil { emit(render(reply, command: "key", json: json)) }
                else { emit((reply.result.map(KeyCommand.describe) ?? "", "", reply.exitCode)) }
                return reply.exitCode
            }
            if invocation.command == "setup" {
                let result = await Setup.run(
                    Setup.Options(autostart: invocation.args["autostart"]?.bool == true, noPortal: invocation.args["noPortal"]?.bool == true),
                    environment: Setup.Environment(variables: environment, configDirectory: config.directory, dataDirectory: data))
                let reply = Reply(id: 1, result: result)
                if json { emit(render(reply, command: "setup", json: true)) } else { emit((Setup.describe(result), "", reply.exitCode)) }
                return reply.exitCode
            }
            if invocation.command == "daemon" {
                let handler = CommandHandler(control: UnavailableTakeControl(mode: "local"), config: config, historyURL: historyURL,
                                             takesRoot: takesRoot, environment: environment)
                let daemon = Daemon(handler: handler)
                try daemon.start(installSignals: true)
                defer { daemon.abort() }
                // Hold the lock before storage writes or session/capture initialization.
                try config.writeStarterFilesIfMissing()
                _ = try HistoryStore(databaseURL: historyURL, takesRoot: takesRoot)
                if let makeControl { handler.control = try await makeControl() }
                else {
                    handler.control = try await LinuxRuntime.make(LinuxRuntime.Options(environment: environment, configDirectory: config.directory, dataDirectory: data))
                }
                // A SIGTERM during startup began the shutdown against the placeholder control; stop
                // what this one started (hotkey, portal) instead of publishing a socket.
                if handler.shuttingDown {
                    _ = await handler.control.quiesce(until: .now + .seconds(5))
                    return 0
                }
                try daemon.publish()
                if json { emit(render(Reply(id: 1, result: .object(["ready": .bool(true), "socket": .string(environment["XDG_RUNTIME_DIR"]! + "/vizier/vizier.sock")])), command: "daemon", json: true)) }
                FileHandle.standardError.write(Data("Vizier daemon listening.\n".utf8))
                await daemon.run()
                if json { emit(render(Reply(id: 1, result: .object(["stopped": .bool(true)])), command: "daemon", json: true)) }
                return 0
            }
            let reply: Reply
            do {
                reply = try await Task.detached {
                    try SocketClient.call(Request(cmd: invocation.command, args: invocation.args), environment: environment)
                }.value
            } catch is CLIError where invocation.command == "doctor" {
                // A down daemon cannot diagnose itself. Offline local diagnostics are the recovery path.
                let result = await Task.detached {
                    Doctor.report(config: config, historyURL: historyURL,
                                  takesRoot: takesRoot, environment: environment)
                }.value
                reply = Reply(id: 1, result: result)
            } catch let error as CLIError where ["daemon_not_running", "runtime_dir_unavailable"].contains(error.code) &&
                (["history", "last"].contains(invocation.command) || (invocation.command == "config" && invocation.args["action"]?.string != "set")) {
                let local = CommandHandler(control: UnavailableTakeControl(mode: "local"), config: config,
                    historyURL: historyURL, takesRoot: takesRoot, environment: environment)
                reply = local.handle(Request(cmd: invocation.command, args: invocation.args))
            }
            let output = render(reply, command: invocation.command, json: invocation.json)
            emit(output); return output.exit
        } catch let error as CLIError {
            let output = render(Reply(id: 1, error: error), command: "", json: json); emit(output); return output.exit
        } catch {
            let output = render(Reply(id: 1, error: CLIError("internal_error", "Cannot initialize Vizier; no take was accepted.", next: "vizier doctor")), command: "", json: json)
            emit(output); return output.exit
        }
    }
    private static func emit(_ output: (stdout: String, stderr: String, exit: Int32)) {
        if !output.stdout.isEmpty { FileHandle.standardOutput.write(Data(output.stdout.utf8)) }
        if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
    }
}

/// Bootstrap boundary only; never pretends to record. L6 supplies the real engine session factory.
@MainActor
final class UnavailableTakeControl: TakeControl {
    let mode: String
    init(mode: String) { self.mode = mode }
    func status() -> TakeStatus { TakeStatus(phase: .idle, takeID: nil, seconds: 0, mode: mode, lastEnding: nil) }
    /// Nothing is ever in flight here, so shutdown never waits.
    func quiesce(until deadline: ContinuousClock.Instant) async -> Bool { true }
    func toggle() throws(TakeCommandError) -> TakeStatus { throw .startupNotReady }
    func start() throws(TakeCommandError) -> TakeStatus { throw .startupNotReady }
    func stop() throws(TakeCommandError) -> TakeStatus { throw .startupNotReady }
    func cancel() throws(TakeCommandError) -> TakeStatus { throw .startupNotReady }
}

import Foundation
import FoundationNetworking
import Glibc
import VizierEngine

@MainActor
public final class CommandHandler {
    public internal(set) var control: any TakeControl
    public let config: ConfigStore
    private let historyURL: URL
    private let takesRoot: URL
    public let environment: [String: String]
    public var shuttingDown = false
    private var startupRefused = false

    public init(control: any TakeControl, config: ConfigStore, historyURL: URL, takesRoot: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.control = control; self.config = config; self.historyURL = historyURL
        self.takesRoot = takesRoot; self.environment = environment
    }

    public func handle(_ request: Request) -> Reply {
        do {
            guard request.v == 1 else { throw CLIError("bad_version", "Only protocol v=1 is supported.", next: "vizier --help") }
            guard !shuttingDown else { throw CLIError("shutting_down", "Daemon is shutting down.", next: "vizier daemon") }
            return Reply(id: request.id, result: try execute(request))
        } catch let error as TakeCommandError {
            startupRefused = error == .startupNotReady
            let next: String
            switch error {
            case .alreadyRecording: next = "vizier stop"
            case .notRecording: next = "vizier start"
            case .busyFinalizing: next = "vizier status"
            case .startupNotReady: next = "vizier doctor"
            }
            return Reply(id: request.id, error: CLIError(error.rawValue, "Take command refused: \(error.rawValue).", next: next))
        } catch let error as CLIError { return Reply(id: request.id, error: error) }
        catch {
            // Engine errors may include vocabulary/transcripts; never echo arbitrary error descriptions.
            return Reply(id: request.id, error: CLIError("storage_error", "Cannot read or update local storage.", next: "vizier doctor"))
        }
    }

    func execute(_ request: Request) throws -> JSONValue {
        let args = request.args
        switch request.cmd {
        case "ping", "status", "toggle", "start", "stop", "cancel", "last", "doctor", "keys_changed":
            try validate(args, allowed: [])
        case "history": try validate(args, allowed: ["limit", "before", "text"])
        case "config": try validate(args, allowed: ["action", "mode"])
        default: throw CLIError("unknown_command", "Unknown command '\(request.cmd)'.", next: "vizier --help")
        }
        switch request.cmd {
        case "ping": return .object(["pong": .bool(true)])
        case "keys_changed":
            // Sent by `vizier key set|delete`: the session re-reads its keys in the background.
            (control as? KeyRefreshing)?.keysChanged()
            return .object(["refreshing": .bool(control is KeyRefreshing)])
        case "status":
            var status = try JSONValue.encoded(control.status())
            if case .object(var fields) = status { fields["daemon"] = .string("running"); status = .object(fields) }
            return status
        case "toggle": return try .encoded(control.toggle())
        case "start": return try .encoded(control.start())
        case "stop": return try .encoded(control.stop())
        case "cancel": return try .encoded(control.cancel())
        case "last":
            let store = try history()
            // Last ended take (rather than an in-progress take or a rerun's text).
            let records = try store.search("", outcomes: [.pasted, .rerouted, .held, .failed, .cancelled], limit: 1, before: nil)
            guard let record = records.first else { return .object(["take": .null]) }
            return .object(["take": historyValue(record, text: true)])
        case "history":
            let limit = try integer(args["limit"], default: 20)
            guard (1...100).contains(limit) else { throw invalid("limit must be an integer from 1 to 100.", next: "vizier history --limit 20") }
            var before: Date?
            var cursor: String?
            if let value = args["before"] {
                guard let string = value.string else { throw invalid("before must be a cursor or ISO 8601 time.", next: "vizier history --help") }
                if Self.validCursor(string) { cursor = string }
                else if let date = Self.date(string) { before = date }
                else { throw invalid("Invalid history cursor.", next: "vizier history --help") }
            }
            if let value = args["text"], value.bool == nil { throw invalid("text must be a boolean.", next: "vizier history --text") }
            let records = try history().search("", outcomes: nil, limit: limit, before: before, cursor: cursor)
            return .object(["takes": .array(records.map { historyValue($0, text: args["text"]?.bool == true) }),
                            "before": records.last.map { .string("\(Int64(($0.startedAt.timeIntervalSince1970 * 1000).rounded())):\($0.id)") } ?? .null])
        case "config":
            guard let action = args["action"]?.string else { throw invalid("config requires action path, get or set.", next: "vizier config get") }
            if action == "path" {
                guard args["mode"] == nil else { throw invalid("path takes no mode.", next: "vizier config path") }
                return .object(["path": .string(config.settingsURL.path)])
            }
            if action == "get" {
                guard args["mode"] == nil else { throw invalid("get takes no mode.", next: "vizier config get") }
                let snapshot = try config.settingsSnapshot()
                return .object(["path": .string(config.settingsURL.path), "settings": try .encoded(snapshot.settings)])
            }
            guard action == "set", let mode = args["mode"]?.string, !mode.isEmpty else {
                throw invalid("set requires an active mode id.", next: "vizier config set mode local")
            }
            let snapshot = try config.settingsSnapshot()
            guard snapshot.settings.modes.contains(where: { $0.id == mode }) else {
                throw CLIError("unknown_mode", "Mode is not defined in the config.", next: "vizier config get")
            }
            let updated = try config.setActiveMode(mode, expected: snapshot)
            return .object(["path": .string(config.settingsURL.path), "mode": .string(updated.settings.mode)])
        case "doctor": return Doctor.report(config: config, historyURL: historyURL, takesRoot: takesRoot, environment: environment, probeSocket: false, session: control is UnavailableTakeControl ? "not wired in this build" : (startupRefused ? "recovery running (last take command refused)" : nil))
        default: preconditionFailure("validated command")
        }
    }
    private func history() throws -> HistoryStore { try HistoryStore(readingOnly: historyURL, takesRoot: takesRoot) }
    private func historyValue(_ record: TakeRecord, text: Bool) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(record.id), "startedAt": .string(Self.timestamp(record.startedAt)),
            "stoppedAt": record.stoppedAt.map { .string(Self.timestamp($0)) } ?? .null,
            "outcome": .string(record.outcome.rawValue), "mode": .string(record.modeID)]
        if text { fields["text"] = record.finalText.map(JSONValue.string) ?? .null }
        return .object(fields)
    }
    private func validate(_ args: [String: JSONValue], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw invalid("Unknown argument; no command was applied.", next: "vizier --help") }
    }
    private func invalid(_ message: String, next: String) -> CLIError { CLIError("invalid_args", message, next: next) }
    private func integer(_ value: JSONValue?, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let n = value.number, n.isFinite, n >= 1, n <= 100, n.rounded() == n else {
            throw invalid("limit must be an integer from 1 to 100.", next: "vizier history --limit 20")
        }
        return Int(n)
    }
    nonisolated static func validCursor(_ text: String) -> Bool {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && Int64(parts[0]) != nil && !parts[1].isEmpty
    }
    nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.string(from: date)
    }
    nonisolated static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public enum Doctor {
    public static func report(config: ConfigStore, historyURL: URL, takesRoot: URL, environment: [String: String], probeSocket: Bool = true, session: String? = "daemon down") -> JSONValue {
        var checks: [JSONValue] = []
        func add(_ name: String, _ status: String, _ detail: String, _ fix: String) {
            checks.append(.object(["name": .string(name), "status": .string(status), "detail": .string(detail), "fix": .string(status == "ok" ? "" : fix)]))
        }
        do {
            let directory = try RuntimeDirectory(environment: environment, create: false)
            add("runtime_dir", "ok", "User-owned 0700 runtime directories.", "vizier doctor")
            do {
                try directory.validateSocket()
                let responds = try !probeSocket || (SocketClient.call(Request(cmd: "ping"), environment: environment)).ok
                add("socket", responds ? "ok" : "fail", responds ? "Daemon responds over a user-owned 0600 socket." : "Daemon refused ping.", "vizier daemon")
            } catch { add("socket", "fail", "Daemon socket unavailable or unsafe.", "vizier daemon") }
        } catch let error as CLIError {
            if error.code == "daemon_not_running" {
                add("runtime_dir", "ok", "Runtime root is valid; daemon directory is absent.", "vizier daemon")
                add("socket", "fail", "Daemon is down.", "vizier daemon")
            } else {
                add("runtime_dir", "fail", error.message, error.next)
                add("socket", "fail", "Runtime directory unavailable.", error.next)
            }
        } catch { add("runtime_dir", "fail", "Runtime unavailable.", "vizier doctor") }
        do {
            _ = try config.settingsSnapshot()
            guard config.load().errors.isEmpty else { throw CLIError("storage_error", "Config validation failed.", next: "vizier config path") }
            add("config", "ok", "Settings, vocabulary and replacements parse successfully.", "vizier config get")
        }
        catch { add("config", "fail", "Config missing or invalid: \(config.directory.path)", "vizier config path") }
        do { _ = try HistoryStore(readingOnly: historyURL, takesRoot: takesRoot); add("history", "ok", "History opens read-only.", "vizier history --limit 1") }
        catch { add("history", "fail", "History database unavailable: \(historyURL.path)", "vizier daemon") }
        if let version = loadedCurlVersion() {
            add("libcurl", version.number >= 0x080b00 ? "ok" : "fail", "FoundationNetworking loaded libcurl \(version.text); live engines require 8.11+. Batch engines remain available.", "sudo apt-get update && sudo apt-get install libcurl4t64")
        } else { add("libcurl", "fail", "Cannot inspect FoundationNetworking's loaded libcurl.", "vizier doctor") }
        func onPath(_ name: String) -> Bool {
            (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).contains {
                let directory = $0.isEmpty ? "." : String($0)
                return access(directory + "/" + name, X_OK) == 0
            }
        }
        // GNOME and KDE identify the portal client by this file; elsewhere it is harmless to lack.
        if let entry = Setup.installedDesktopEntry(variables: environment) {
            add("desktop_entry", "ok", "\(Setup.desktopEntryName) is installed at \(entry.path).", "")
        } else {
            add("desktop_entry", "warn", "\(Setup.desktopEntryName) is not installed; the GNOME and KDE portals (paste, global shortcut) need it to identify Vizier.", "vizier setup")
        }
        if onPath("pw-record") { add("pw_record", "ok", "pw-record is executable on PATH.", "") }
        else if onPath("parec") { add("pw_record", "ok", "pw-record is missing; parec (PulseAudio) will record instead.", "") }
        else { add("pw_record", "fail", "Neither pw-record nor parec is on PATH.", DistroFamily.detect().install(["pipewire-bin"], names: [.fedora: ["pipewire-utils"], .arch: ["pipewire"], .suse: ["pipewire-tools"]])) }
        for check in LocalServers.checks(config.load().config, environment: environment) { add(check.name, check.status, check.detail, check.fix) }
        add("take_session", session == nil ? "ok" : "fail", session ?? "Take session is available.", "vizier status")
        return .object(["checks": .array(checks), "healthy": .bool(!checks.contains { $0["status"]?.string == "fail" })])
    }
    /// Inspect the library actually referenced by FoundationNetworking, not `curl --version`.
    /// RTLD_NOLOAD avoids accidentally checking a different installed libcurl.
    public static func loadedCurlVersion() -> (text: String, number: UInt32)? {
        _ = URLSession.shared  // ensure FoundationNetworking has initialized its transport
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/proc/self/maps")) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.readToEnd(), let mappings = String(data: data, encoding: .utf8) else { return nil }
        let paths = Set(mappings.split(separator: "\n").compactMap { line -> String? in
            guard let slash = line.firstIndex(of: "/") else { return nil }
            let path = String(line[slash...])
            return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("libcurl.so") ? path : nil
        })
        guard paths.count == 1, let path = paths.first,
              let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "curl_version_info") else { return nil }
        typealias VersionInfo = @convention(c) (Int32) -> UnsafeRawPointer?
        let function = unsafeBitCast(symbol, to: VersionInfo.self)
        guard let info = function(0) else { return nil }
        // curl_version_info_data begins with enum age, pointer version, unsigned version_num.
        let pointerOffset = MemoryLayout<UnsafeRawPointer>.alignment
        guard let string = info.load(fromByteOffset: pointerOffset, as: UnsafePointer<CChar>?.self) else { return nil }
        let number = info.load(fromByteOffset: pointerOffset + MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        return (String(cString: string), number)
    }
}

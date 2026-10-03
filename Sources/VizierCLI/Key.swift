import Foundation
import Glibc
import VizierEngine

/// `vizier key set|status|delete <elevenlabs|gemini>` (D12). The key is never an argument and is
/// never printed or logged: `set` reads it from stdin (hidden prompt on a terminal, or a pipe),
/// `status` names where each key resolves from.
public enum KeyCommand {
    /// Where `set` gets the key. Throws a `CLIError` when it cannot be read safely.
    public typealias Reader = @Sendable () throws -> String

    public static func run(args: [String: JSONValue], environment: [String: String], configDirectory: URL,
                           useSecretService: Bool = true, secretServiceLocator: (any SecretServiceLocator)? = nil,
                           readKey: Reader = Self.readFromStandardInput) -> Reply {
        let store = LinuxSecretStore(environment: environment, configDirectory: configDirectory, useSecretService: useSecretService, secretServiceLocator: secretServiceLocator)
        do {
            switch args["action"]?.string {
            case "set": return Reply(id: 1, result: try set(args, store: store, environment: environment, readKey: readKey))
            case "delete": return Reply(id: 1, result: try delete(args, store: store, environment: environment))
            case "status": return Reply(id: 1, result: status(args, store: store, environment: environment))
            default: throw CLIError("usage", "key requires set, status or delete.", next: "vizier key --help")
            }
        } catch let error as CLIError {
            return Reply(id: 1, error: error)
        } catch {
            return Reply(id: 1, error: CLIError("key_error", "The key command failed: \(SecretError.publicDescription(error))", next: "vizier key status"))
        }
    }

    private static func account(_ args: [String: JSONValue]) throws -> SecretAccount {
        guard let name = args["account"]?.string, let account = SecretAccount(rawValue: name) else {
            throw CLIError("usage", "Name the key: elevenlabs or gemini.", next: "vizier key status")
        }
        return account
    }

    private static func set(_ args: [String: JSONValue], store: LinuxSecretStore, environment: [String: String], readKey: Reader) throws -> JSONValue {
        let account = try account(args)
        let key = try readKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CLIError("empty_key", "No key was provided on stdin; nothing was stored.", next: "vizier key set \(account.rawValue) --help") }
        guard key.utf8.count <= 512, !key.contains(where: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.value < 32 } }) else {
            throw CLIError("invalid_key", "That does not look like an API key (it has spaces or control characters, or is too long); nothing was stored.", next: "vizier key set \(account.rawValue) --help")
        }
        let backend: SecretBackend
        do { backend = try store.storeReporting(key, account: account.rawValue) }
        catch { throw CLIError("key_store_failed", "The key could not be stored: \(SecretError.publicDescription(error))", next: "vizier doctor") }
        var fields: [String: JSONValue] = ["key": .string(account.rawValue), "storedIn": .string(backend.rawValue)]
        if let overriding = environment[account.environmentVariable], !overriding.isEmpty {
            fields["note"] = .string("\(account.environmentVariable) is set and takes precedence over the stored key")
        }
        return .object(fields)
    }

    private static func delete(_ args: [String: JSONValue], store: LinuxSecretStore, environment: [String: String]) throws -> JSONValue {
        let account = try account(args)
        do { try store.delete(account.rawValue) }
        catch { throw CLIError("key_delete_failed", "The key could not be removed: \(SecretError.publicDescription(error))", next: "vizier key status") }
        var fields: [String: JSONValue] = ["key": .string(account.rawValue), "deleted": .bool(true)]
        if let remaining = environment[account.environmentVariable], !remaining.isEmpty {
            fields["note"] = .string("\(account.environmentVariable) is still set in this environment")
        }
        return .object(fields)
    }

    private static func status(_ args: [String: JSONValue], store: LinuxSecretStore, environment: [String: String]) -> JSONValue {
        let wanted = args["account"]?.string.flatMap(SecretAccount.init(rawValue:)).map { [$0] } ?? SecretAccount.allCases
        let keys: [JSONValue] = wanted.map { account in
            let found = store.status(account.rawValue)
            return .object([
                "key": .string(account.rawValue), "name": .string(account.displayName),
                "resolvedFrom": found.resolvedFrom.map { .string($0.rawValue) } ?? .null,
                "presentIn": .array(found.presentIn.map { .string($0.rawValue) }),
                "errors": .array(found.errors.map(JSONValue.string)),
                "environmentVariable": .string(account.environmentVariable),
            ])
        }
        return .object(["keys": .array(keys), "secretService": .object(["available": .bool(store.secretServiceAvailable)]), "file": .string(store.fileURL.path)])
    }

    /// The human text for a successful result.
    public static func describe(_ result: JSONValue) -> String {
        if case .array(let keys) = result["keys"] {
            var lines = keys.map { key -> String in
                let name = key["name"]?.string ?? "", source = key["resolvedFrom"]?.string
                var line = "\(name): " + (source.map { "set (from \($0))" } ?? "not set")
                if case .array(let errors) = key["errors"], !errors.isEmpty { line += "; could not check: " + errors.compactMap(\.string).joined(separator: "; ") }
                return line
            }
            if result["secretService"]?["available"]?.bool != true { lines.append("Secret Service: secret-tool is not installed; keys are kept in \(result["file"]?.string ?? "the key file")") }
            return lines.joined(separator: "\n") + "\n"
        }
        if let stored = result["storedIn"]?.string {
            return "Stored the \(result["key"]?.string ?? "") key in \(stored == "file" ? "the key file (Secret Service was not available)" : "Secret Service").\n" + (result["note"]?.string.map { "Note: \($0).\n" } ?? "")
        }
        if result["deleted"]?.bool == true { return "Removed the \(result["key"]?.string ?? "") key.\n" + (result["note"]?.string.map { "Note: \($0).\n" } ?? "") }
        return ""
    }

    /// The most a key may be, in bytes. A longer input is refused, never truncated.
    public static let maxKeyBytes = 4096

    /// stdin: a hidden prompt on a terminal, the whole pipe otherwise (at most 4 KiB).
    public static let readFromStandardInput: Reader = { try readInput(from: 0) }

    /// Reads one key from `descriptor`. On a terminal: echo is switched off (and the original mode
    /// put back, with a warning if that fails) and one line is read; otherwise everything up to end
    /// of file is. Reads are bounded in bytes and byte by byte through `read(2)`; end of file and a
    /// read error are different outcomes, and the bytes must be valid UTF-8.
    static func readInput(from descriptor: Int32) throws -> String {
        let data: Data
        if isatty(descriptor) == 1 {
            let unsafe = CLIError("tty_unsafe", "Cannot turn terminal echo off, so the key was not read.", next: "printf %s \"$KEY\" | vizier key set gemini --stdin")
            var original = termios()
            guard tcgetattr(descriptor, &original) == 0 else { throw unsafe }
            var quiet = original
            quiet.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(descriptor, TCSAFLUSH, &quiet) == 0 else { throw unsafe }
            FileHandle.standardError.write(Data("API key (input hidden): ".utf8))
            defer {
                if tcsetattr(descriptor, TCSAFLUSH, &original) != 0 {
                    FileHandle.standardError.write(Data("\nCould not restore terminal echo; run `stty echo`.\n".utf8))
                } else { FileHandle.standardError.write(Data("\n".utf8)) }
            }
            data = try readBounded(descriptor, untilNewline: true)
        } else {
            data = try readBounded(descriptor, untilNewline: false)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError("invalid_key", "The input is not valid UTF-8, so it is not an API key; nothing was stored.", next: "vizier key --help")
        }
        return text
    }

    private static func readBounded(_ descriptor: Int32, untilNewline: Bool) throws -> Data {
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            // A terminal line is taken a byte at a time so nothing after the newline is consumed.
            let n = untilNewline ? Glibc.read(descriptor, &byte, 1) : Glibc.read(descriptor, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw CLIError("read_failed", "Reading the key failed (errno \(errno)); nothing was stored.", next: "vizier key --help")
            }
            if n == 0 { break }  // end of file
            if untilNewline {
                if byte[0] == 10 { break }
                data.append(byte[0])
            } else {
                data.append(contentsOf: chunk.prefix(n))
            }
            if data.count > maxKeyBytes {
                throw CLIError("invalid_key", "The input is too long to be an API key; nothing was stored.", next: "vizier key --help")
            }
        }
        return data
    }
}

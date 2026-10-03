import VizierEngine
import Foundation

/// `Vizier --store-key <account>` reads an API key from stdin into the keychain. The installed
/// binary runs it (scripts/install.sh), so the keychain item's access list names Vizier. The key
/// never goes on a command line, is never read from a terminal where it would echo, and is never
/// printed.
enum KeyCommand {
    static func run(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--store-key") else { return nil }
        let account = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        guard !account.isEmpty, !account.hasPrefix("-") else {
            return fail("usage: Vizier --store-key <account>, with the key on stdin", code: 64)
        }
        guard isatty(STDIN_FILENO) == 0 else {
            return fail("pipe the key on stdin; Vizier won't read it from a terminal", code: 64)
        }
        let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return fail("no key on stdin; nothing stored", code: 65) }
        do {
            try Keychain.store(key, account: account)
        } catch {
            return fail("could not store the \(account) key: \(error.description)", code: 1)
        }
        print("stored the \(account) key in the keychain")
        return 0
    }

    private static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("Vizier: \(message)\n".utf8))
        return code
    }
}

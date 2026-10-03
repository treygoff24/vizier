/// Where API keys are kept. `read` returns nil for an account with nothing stored and throws when
/// the backend itself fails (a locked keychain, an unreachable service), so a caller can tell
/// "no key" from "could not look". macOS: `KeychainStore`. Linux implementations live with the
/// Linux adapters.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    func store(_ value: String, account: String) throws
}

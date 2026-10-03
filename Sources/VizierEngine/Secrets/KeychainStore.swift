#if canImport(Security)
/// The login keychain as a `SecretStore`: `Keychain`, unchanged, behind the protocol.
public struct KeychainStore: SecretStore {
    public init() {}

    public func read(_ account: String) throws -> String? {
        try Keychain.read(account)
    }

    public func store(_ value: String, account: String) throws {
        try Keychain.store(value, account: account)
    }
}
#endif

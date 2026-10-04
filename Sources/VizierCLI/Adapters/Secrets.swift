import Foundation
import Glibc
import VizierEngine

// The Linux secret store chain (D12, A6): environment variable, then Secret Service through
// `secret-tool`, then a 0600 file in the config directory. `SecretStore.read` is synchronous and
// throws on a backend failure (nil is "absent"); the chain keeps going past a failing backend so a
// file-stored key still resolves on a box with a broken keyring, and throws the failure only when
// nothing else answered.

public enum SecretError: Error, CustomStringConvertible, Equatable {
    /// The backend could not be asked, or refused (a locked keyring, no Secret Service on the bus).
    case backend(String)
    /// The key file is readable by others, or not ours.
    case unsafeFile(String)
    case unknownAccount(String)
    /// The Secret Service backend cannot store (no `secret-tool`).
    case unavailable(String)

    public var description: String {
        switch self {
        case .backend(let message), .unsafeFile(let message), .unavailable(let message): message
        case .unknownAccount(let account): "unknown key '\(account)'; use elevenlabs or gemini"
        }
    }

    /// What may be shown to the user or put in JSON for any error from a secret backend: the
    /// messages of `SecretError` are fixed text written here, anything else is only classified.
    /// A helper's stderr or an arbitrary error description is never carried through.
    public static func publicDescription(_ error: any Error) -> String {
        (error as? SecretError)?.description ?? "the secret backend failed"
    }
}

/// The keys Vizier knows, with the environment variable that overrides each.
public enum SecretAccount: String, CaseIterable, Sendable {
    case elevenlabs, gemini

    public var environmentVariable: String {
        switch self {
        case .elevenlabs: "VIZIER_ELEVENLABS_API_KEY"
        case .gemini: "VIZIER_GEMINI_API_KEY"
        }
    }

    public var displayName: String {
        switch self {
        case .elevenlabs: "ElevenLabs"
        case .gemini: "Gemini"
        }
    }
}

public enum SecretBackend: String, Sendable, Equatable, Codable {
    case environment, secretService = "secret-service", file
}

/// Runs asynchronous work to completion and waits for it. The secret store protocol is
/// synchronous, so this blocks the caller while the work runs as a detached task on Swift's
/// cooperative thread pool. Call it only from a thread that is not one of that pool's: the snapshot
/// refresher's dispatch queue, or the main thread of a one-shot CLI command. Never from code running
/// on the cooperative pool (a nonisolated async function, a `Task` that is not on the main actor):
/// the caller would hold a pool thread while waiting for a task that needs one, and with enough
/// such callers at once every pool thread waits and nothing runs again.
enum Blocking {
    private final class Box<T: Sendable>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, any Error>?
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        Task.detached {
            do { box.result = .success(try await work()) }
            catch { box.result = .failure(error) }
            box.semaphore.signal()
        }
        box.semaphore.wait()
        return try box.result!.get()
    }
}

/// Runs a short helper and waits for it, for at most `timeout` (a locked keyring waiting on a
/// prompt is cut off there). It runs on the calling thread and needs nothing from the cooperative
/// pool, so `secret-tool` store, lookup and clear finish even while every pool thread is busy.
enum BlockingProcess {
    static func run(_ argv: [String], stdin: Data? = nil, environment: [String: String], timeout: Duration = .seconds(5)) throws -> ProcessResult {
        try ProcessRunner.runSync(argv, stdin: stdin, environment: environment, timeout: timeout, outputLimit: 64 * 1024)
    }
}

/// Environment variables: `VIZIER_ELEVENLABS_API_KEY`, `VIZIER_GEMINI_API_KEY`. Read-only.
public struct EnvironmentSecretStore: SecretStore {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func read(_ account: String) throws -> String? {
        guard let known = SecretAccount(rawValue: account) else { return nil }
        guard let value = environment[known.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func store(_ value: String, account: String) throws {
        throw SecretError.unavailable("environment variables are read-only; set them in the daemon's environment")
    }
}

/// What a Secret Service search for one key found: items whose collection is unlocked, and items
/// that exist but are locked. Never the values.
public struct SecretServiceSearch: Sendable, Equatable {
    public var unlocked: Int
    public var locked: Int
    public init(unlocked: Int, locked: Int) {
        self.unlocked = unlocked
        self.locked = locked
    }
}

/// Tells "no such item" from "the item is there but its collection is locked" (A6): `secret-tool
/// lookup` answers both with exit 1, and only the first is an absent key.
public protocol SecretServiceLocator: Sendable {
    func search(account: String) async throws -> SecretServiceSearch
}

/// `org.freedesktop.Secret.Service.SearchItems` with the attributes Vizier stores its keys under.
/// It lists object paths only; no secret is requested or returned.
public struct DBusSecretServiceLocator: SecretServiceLocator {
    public var timeout: Duration
    public init(timeout: Duration = .seconds(5)) { self.timeout = timeout }

    public func search(account: String) async throws -> SecretServiceSearch {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let once = SearchOnce(continuation)
            Task {
                do {
                    let connection = try await DBusConnection.open()
                    let reply = try await connection.call(
                        destination: "org.freedesktop.secrets", path: "/org/freedesktop/secrets",
                        interface: "org.freedesktop.Secret.Service", member: "SearchItems",
                        arguments: [.array("{ss}", [
                            .structure([.string("service"), .string(SecretToolStore.service)]),
                            .structure([.string("account"), .string(account)]),
                        ])])
                    func count(_ value: DBusValue?) -> Int? { if case .array(_, let items)? = value { items.count } else { nil } }
                    guard reply.count == 2, let unlocked = count(reply[0]), let locked = count(reply[1]) else { throw DBusFailure.malformed }
                    once.finish(.success(SecretServiceSearch(unlocked: unlocked, locked: locked)))
                } catch { once.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.finish(.failure(SecretError.backend("Secret Service did not answer in time (is the keyring locked?)")))
            }
        }
    }

    private final class SearchOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SecretServiceSearch, any Error>?
        init(_ continuation: CheckedContinuation<SecretServiceSearch, any Error>) { self.continuation = continuation }
        func finish(_ result: Result<SecretServiceSearch, any Error>) {
            lock.lock(); let taken = continuation; continuation = nil; lock.unlock()
            taken?.resume(with: result)
        }
    }
}

/// Secret Service (GNOME Keyring, KWallet's bridge, KeePassXC) through `secret-tool`. The value
/// travels on stdin, never argv. A lookup first asks the bus whether the item exists and whether
/// it is locked; nothing the tool prints on stderr is ever passed on.
public struct SecretToolStore: SecretStore {
    public static let service = "net.praxient.vizier"
    private let environment: [String: String]
    private let locator: any SecretServiceLocator

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, locator: (any SecretServiceLocator)? = nil) {
        self.environment = environment
        self.locator = locator ?? DBusSecretServiceLocator()
    }

    public var isInstalled: Bool { ProcessRunner.resolve("secret-tool", environment: environment) != nil }

    private func attributes(_ account: String) -> [String] { ["service", Self.service, "account", account] }

    /// A fixed message: the operation, a timeout or the exit status. The tool's stderr and stdout
    /// can carry anything (a stored value, a path, a user name) and are dropped.
    private func failure(_ result: ProcessResult, action: String) -> SecretError {
        if result.timedOut { return .backend("Secret Service did not answer to \(action) in time (is the keyring locked?)") }
        return .backend("secret-tool \(action) failed (exit status \(result.exitCode ?? -1))")
    }

    private func run(_ argv: [String], stdin: Data? = nil) throws -> ProcessResult {
        do { return try BlockingProcess.run(argv, stdin: stdin, environment: environment) }
        catch { throw SecretError.backend("secret-tool could not be run") }
    }

    public func read(_ account: String) throws -> String? {
        guard isInstalled else { return nil }
        let locator = locator
        let found: SecretServiceSearch
        do { found = try Blocking.run { try await locator.search(account: account) } }
        catch let error as SecretError { throw error }
        catch { throw SecretError.backend("Secret Service could not be asked (is a keyring running on the session bus?)") }
        guard found.unlocked > 0 else {
            if found.locked > 0 { throw SecretError.backend("Secret Service has the key but its keyring is locked; unlock it (or the key cannot be read)") }
            return nil
        }
        let result = try run(["secret-tool", "lookup"] + attributes(account))
        guard result.exitCode == 0 && !result.timedOut else { throw failure(result, action: "lookup") }
        let value = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func store(_ value: String, account: String) throws {
        guard isInstalled else { throw SecretError.unavailable("secret-tool is not installed") }
        let label = "Vizier \(SecretAccount(rawValue: account)?.displayName ?? account) API key"
        let result = try run(["secret-tool", "store", "--label=\(label)"] + attributes(account), stdin: Data(value.utf8))
        guard result.succeeded else { throw failure(result, action: "store") }
    }

    public func delete(_ account: String) throws {
        guard isInstalled else { return }
        let result = try run(["secret-tool", "clear"] + attributes(account))
        guard result.succeeded else { throw failure(result, action: "clear") }
    }
}

/// `$XDG_CONFIG_HOME/vizier/keys.json`: a 0600 file in a 0700 directory, `{"gemini": "...", ...}`.
///
/// Every access goes through one directory descriptor opened with `O_NOFOLLOW | O_DIRECTORY` and
/// checked with `fstat` (a directory, ours), whose mode is then forced to 0700 with `fchmod` and
/// checked again. The file is opened relative to that descriptor with `O_NOFOLLOW` and judged by
/// `fstat` on the open descriptor (regular, ours, no group or other bits, bounded size), so a path
/// swapped for a symlink or another file between the check and the read cannot redirect either.
/// Writes go to a temp file and `renameat` in the same directory descriptor.
public struct FileSecretStore: SecretStore {
    public let url: URL
    private static let maxBytes = 1 << 20
    private static let fileName = "keys.json"

    public init(directory: URL) {
        url = directory.appending(path: Self.fileName)
    }

    private var directoryURL: URL { url.deletingLastPathComponent() }

    /// The opened config directory, or nil when it does not exist and `create` is false. The caller closes it.
    private func openDirectory(create: Bool) throws -> Int32? {
        let path = directoryURL.path
        if create {
            try? FileManager.default.createDirectory(at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(path, 0o700) != 0 && errno != EEXIST { throw SecretError.unsafeFile("cannot create \(path)") }
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT && !create { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw SecretError.unsafeFile("\(path) is not a real directory (a symlink or a file is in its place)") }
            throw SecretError.unsafeFile("cannot open \(path)")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            Glibc.close(fd)
            throw SecretError.unsafeFile("\(path) is not a directory owned by you")
        }
        if info.st_mode & 0o7777 != 0o700 {
            guard fchmod(fd, 0o700) == 0, fstat(fd, &info) == 0, info.st_mode & 0o077 == 0 else {
                Glibc.close(fd)
                throw SecretError.unsafeFile("\(path) is accessible by others and could not be fixed; run: chmod 700 \(path)")
            }
        }
        return fd
    }

    /// Refuses a file that is not a regular file of ours with mode 0600 (or tighter).
    private func contents(in directory: Int32) throws -> [String: String]? {
        // O_NONBLOCK: a FIFO put in the file's place must be refused, not waited on.
        let fd = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw SecretError.unsafeFile("\(url.path) is a symlink, not a regular file owned by you") }
            throw SecretError.unsafeFile("cannot read \(url.path)")
        }
        defer { Glibc.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw SecretError.unsafeFile("\(url.path) is not a regular file owned by you")
        }
        guard info.st_mode & 0o077 == 0 else {
            throw SecretError.unsafeFile("\(url.path) is readable by others (mode \(String(info.st_mode & 0o7777, radix: 8))); run: chmod 600 \(url.path)")
        }
        guard info.st_size <= Self.maxBytes else { throw SecretError.unsafeFile("\(url.path) is too large to be a key file") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Glibc.read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw SecretError.unsafeFile("cannot read \(url.path)") }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            if data.count > Self.maxBytes { throw SecretError.unsafeFile("\(url.path) is too large to be a key file") }
        }
        if data.isEmpty { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw SecretError.unsafeFile("\(url.path) is not a JSON object of strings")
        }
        return object
    }

    public func read(_ account: String) throws -> String? {
        guard let directory = try openDirectory(create: false) else { return nil }
        defer { Glibc.close(directory) }
        guard let contents = try contents(in: directory) else { return nil }
        guard let value = contents[account]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func store(_ value: String, account: String) throws {
        let directory = try openDirectory(create: true)!
        defer { Glibc.close(directory) }
        var current = try contents(in: directory) ?? [:]
        current[account] = value
        try write(current, in: directory)
    }

    public func delete(_ account: String) throws {
        guard let directory = try openDirectory(create: false) else { return }
        defer { Glibc.close(directory) }
        guard var current = try contents(in: directory), current[account] != nil else { return }
        current[account] = nil
        try write(current, in: directory)
    }

    private func write(_ contents: [String: String], in directory: Int32) throws {
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys, .prettyPrinted])
        // A temp file made 0600 before its first byte, then renamed over the old one.
        let temp = ".keys.json.\(UUID().uuidString).tmp"
        let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecretError.unsafeFile("cannot create a temporary file next to \(url.path)") }
        var failed = false
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Glibc.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; failed = true; return }
                offset += n
            }
        }
        if fsync(fd) != 0 { failed = true }
        Glibc.close(fd)
        guard !failed, renameat(directory, temp, directory, Self.fileName) == 0 else {
            unlinkat(directory, temp, 0)
            throw SecretError.unsafeFile("cannot write \(url.path)")
        }
        _ = fsync(directory)
    }
}

/// What a lookup of one key found, without the key.
public struct SecretStatus: Sendable, Equatable {
    public var account: String
    /// The first backend that has a value, or nil when none does.
    public var resolvedFrom: SecretBackend?
    /// Every backend that has a value (a key in two places is worth saying).
    public var presentIn: [SecretBackend]
    /// Backends that could not be asked, and why.
    public var errors: [String]
}

/// The chain the daemon and `vizier key` use.
public struct LinuxSecretStore: SecretStore {
    private let environmentStore: EnvironmentSecretStore
    private let secretService: SecretToolStore
    private let file: FileSecretStore
    /// For tests: skip Secret Service entirely.
    private let useSecretService: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, configDirectory: URL, useSecretService: Bool = true,
                secretServiceLocator: (any SecretServiceLocator)? = nil) {
        environmentStore = EnvironmentSecretStore(environment: environment)
        secretService = SecretToolStore(environment: environment, locator: secretServiceLocator)
        file = FileSecretStore(directory: configDirectory)
        self.useSecretService = useSecretService
    }

    public var fileURL: URL { file.url }
    public var secretServiceAvailable: Bool { useSecretService && secretService.isInstalled }

    private var backends: [(SecretBackend, any SecretStore)] {
        var list: [(SecretBackend, any SecretStore)] = [(.environment, environmentStore)]
        if useSecretService { list.append((.secretService, secretService)) }
        list.append((.file, file))
        return list
    }

    public func read(_ account: String) throws -> String? {
        var failure: (any Error)?
        for (_, backend) in backends {
            do { if let value = try backend.read(account) { return value } }
            catch { failure = failure ?? error }
        }
        if let failure { throw failure }
        return nil
    }

    public func store(_ value: String, account: String) throws {
        _ = try storeReporting(value, account: account)
    }

    /// Stores to Secret Service when it takes the key, else to the file; says which.
    @discardableResult
    public func storeReporting(_ value: String, account: String) throws -> SecretBackend {
        guard SecretAccount(rawValue: account) != nil else { throw SecretError.unknownAccount(account) }
        if secretServiceAvailable {
            do { try secretService.store(value, account: account); return .secretService }
            catch {}  // locked or no service on the bus: the file is the fallback
        }
        try file.store(value, account: account)
        return .file
    }

    /// Removes the key from Secret Service and the file. The environment is not ours to change.
    public func delete(_ account: String) throws {
        guard SecretAccount(rawValue: account) != nil else { throw SecretError.unknownAccount(account) }
        var failure: (any Error)?
        if secretServiceAvailable { do { try secretService.delete(account) } catch { failure = error } }
        do { try file.delete(account) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    public func status(_ account: String) -> SecretStatus {
        var present: [SecretBackend] = [], errors: [String] = []
        for (name, backend) in backends {
            do { if try backend.read(account) != nil { present.append(name) } }
            catch { errors.append("\(name.rawValue): \(SecretError.publicDescription(error))") }
        }
        return SecretStatus(account: account, resolvedFrom: present.first, presentIn: present, errors: errors)
    }
}

/// What the take session reads keys from: an in-memory snapshot of the real chain, refreshed off
/// the main actor (at daemon start, on a timer, and when `vizier key set|delete` sends
/// `keys_changed`). `read` never touches a backend, so a stalled keyring cannot block the main
/// actor; a backend failure is remembered per key and thrown from `read` as it was found (A6).
public final class SnapshotSecretStore: SecretStore, @unchecked Sendable {
    private enum Entry { case value(String?), failure(String) }

    private let source: any SecretStore
    private let accounts: [String]
    private let queue = DispatchQueue(label: "net.praxient.vizier.secrets", qos: .utility)
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var refreshing = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(source: any SecretStore, accounts: [String] = SecretAccount.allCases.map(\.rawValue)) {
        self.source = source
        self.accounts = accounts
    }

    /// True once a refresh has finished at least once.
    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }

    public func read(_ account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard loaded else { throw SecretError.backend("the keys are still being loaded; try again in a moment") }
        switch entries[account] {
        case .value(let value)?: return value
        case .failure(let message)?: throw SecretError.backend(message)
        case nil: return nil
        }
    }

    /// Writes go to the real chain (`vizier key` does not use this type; the daemon never writes).
    public func store(_ value: String, account: String) throws {
        try source.store(value, account: account)
    }

    /// Re-reads every key from the chain on a helper thread and swaps the snapshot in. A refresh
    /// asked for while one is running is folded into one more pass after it; the call returns when
    /// the pass that was running (or this one) has finished.
    public func refresh() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiters.append(continuation)
            if refreshing { again = true; lock.unlock(); return }
            refreshing = true
            lock.unlock()
            pass()
        }
    }

    private func pass() {
        queue.async { [self] in
            var fresh: [String: Entry] = [:]
            for account in accounts {
                do { fresh[account] = .value(try source.read(account)) }
                catch { fresh[account] = .failure(SecretError.publicDescription(error)) }
            }
            lock.lock()
            entries = fresh
            loaded = true
            if again {
                again = false
                lock.unlock()
                pass()
                return
            }
            refreshing = false
            let done = waiters
            waiters = []
            lock.unlock()
            for waiter in done { waiter.resume() }
        }
    }
}

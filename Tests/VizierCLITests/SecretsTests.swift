import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

/// A fake `secret-tool` backed by a folder of files: `store` keeps its stdin per account, `lookup`
/// prints it (exit 1 and silent when absent), `clear` removes it. Creating `locked` in the fake's
/// folder makes every call fail the way a locked keyring does. Every call's argv is logged by FakeBins.
private func installSecretTool(_ bins: FakeBins) -> String {
    let vault = "\(bins.directory)/vault"
    try! FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
    bins.installScript("secret-tool", """
    cmd=$1; shift
    for a in "$@"; do acct=$a; done
    if [ -e '\(bins.directory)/locked' ]; then echo "secret-tool: Cannot get secret of a locked object" >&2; exit 1; fi
    case "$cmd" in
    lookup) if [ -f '\(vault)'/"$acct" ]; then cat '\(vault)'/"$acct"; exit 0; fi; exit 1;;
    store) cat > '\(vault)'/"$acct"; exit 0;;
    clear) /bin/rm -f '\(vault)'/"$acct"; exit 0;;
    esac
    exit 2
    """)
    return vault
}

/// What the Secret Service bus would say about the fake vault: no item is (0, 0), an item is
/// unlocked (1, 0) or, with `locked` present, locked (0, 1); `bus-down` is a bus that cannot be asked.
struct FakeLocator: SecretServiceLocator {
    let directory: String
    init(_ bins: FakeBins) { directory = bins.directory }

    func search(account: String) async throws -> SecretServiceSearch {
        if FileManager.default.fileExists(atPath: "\(directory)/bus-down") { throw SecretError.backend("no bus") }
        guard FileManager.default.fileExists(atPath: "\(directory)/vault/\(account)") else { return SecretServiceSearch(unlocked: 0, locked: 0) }
        return FileManager.default.fileExists(atPath: "\(directory)/locked") ? SecretServiceSearch(unlocked: 0, locked: 1) : SecretServiceSearch(unlocked: 1, locked: 0)
    }
}

private func configDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory() + "vizier-secrets-\(UUID().uuidString)/vizier")
}

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    precondition(lstat(url.path, &info) == 0)
    return info.st_mode & 0o7777
}

// A hang fails the test in a minute instead of holding the CI job until it is cancelled.
@Suite(.timeLimit(.minutes(1))) struct SecretsTests {
    @Test func theChainResolvesEnvironmentThenSecretServiceThenFile() async throws {
        let bins = FakeBins(); let vault = installSecretTool(bins)
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileSecretStore(directory: directory).store("file-key", account: "gemini")
        try Data("service-key".utf8).write(to: URL(fileURLWithPath: "\(vault)/gemini"))
        let withEnv = LinuxSecretStore(environment: bins.environment(["VIZIER_GEMINI_API_KEY": "env-key"]), configDirectory: directory, secretServiceLocator: FakeLocator(bins))
        #expect(try await offThePool { try withEnv.read("gemini") } == "env-key")
        let noEnv = LinuxSecretStore(environment: bins.environment(), configDirectory: directory, secretServiceLocator: FakeLocator(bins))
        #expect(try await offThePool { try noEnv.read("gemini") } == "service-key")
        try FileManager.default.removeItem(atPath: "\(vault)/gemini")
        #expect(try await offThePool { try noEnv.read("gemini") } == "file-key")
        // The status names the first source and every source holding the key, never the key.
        try Data("service-key".utf8).write(to: URL(fileURLWithPath: "\(vault)/gemini"))
        let status = try await offThePool { withEnv.status("gemini") }
        #expect(status.resolvedFrom == .environment)
        #expect(status.presentIn == [.environment, .secretService, .file])
        #expect(!"\(status)".contains("env-key") && !"\(status)".contains("service-key") && !"\(status)".contains("file-key"))
    }

    @Test func anAbsentKeyIsNilAndALockedKeyringThrowsUnlessAnotherSourceAnswers() async throws {
        let bins = FakeBins(); _ = installSecretTool(bins)
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = LinuxSecretStore(environment: bins.environment(), configDirectory: directory, secretServiceLocator: FakeLocator(bins))
        #expect(try await offThePool { try store.read("elevenlabs") } == nil)  // the bus lists no item: absent
        // An item the bus lists but whose keyring is locked is a failure, not an absent key;
        // `secret-tool lookup` exits 1 for both, which is why the bus is asked.
        try Data("service-key".utf8).write(to: URL(fileURLWithPath: "\(bins.directory)/vault/elevenlabs"))
        try Data().write(to: URL(fileURLWithPath: "\(bins.directory)/locked"))
        await #expect(throws: SecretError.self) { try await offThePool { try store.read("elevenlabs") } }
        await #expect(throws: SecretError.self) { try await offThePool { try store.read("elevenlabs") } }
        // Locked with nothing stored for this key is still just absent.
        #expect(try await offThePool { try store.read("gemini") } == nil)
        // A file-stored key still resolves while the keyring is locked.
        try FileSecretStore(directory: directory).store("file-key", account: "elevenlabs")
        #expect(try await offThePool { try store.read("elevenlabs") } == "file-key")
        // The service alone: the failure is the answer, not nil.
        let service = SecretToolStore(environment: bins.environment(), locator: FakeLocator(bins))
        await #expect(throws: SecretError.self) { try await offThePool { try service.read("elevenlabs") } }
    }

    @Test func theFileStoreRefusesWideModesAndWritesPrivately() throws {
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = FileSecretStore(directory: directory)
        try file.store("k", account: "gemini")
        #expect(mode(directory) == 0o700 && mode(file.url) == 0o600)
        #expect(try file.read("gemini") == "k")
        #expect(chmod(file.url.path, 0o644) == 0)
        #expect(throws: SecretError.self) { try file.read("gemini") }
        #expect(throws: SecretError.self) { try file.store("other", account: "elevenlabs") }
        #expect(chmod(file.url.path, 0o600) == 0)
        try file.delete("gemini")
        #expect(try file.read("gemini") == nil)
    }

    @Test func storingPrefersSecretServiceSendsTheKeyOnStdinAndFallsBackToTheFile() async throws {
        let bins = FakeBins(); let vault = installSecretTool(bins)
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = LinuxSecretStore(environment: bins.environment(), configDirectory: directory, secretServiceLocator: FakeLocator(bins))
        let secret = "sk-test-secret-value-123"
        #expect(try await offThePool { try store.storeReporting(secret, account: "gemini") } == .secretService)
        #expect(try String(contentsOfFile: "\(vault)/gemini", encoding: .utf8) == secret)
        let calls = bins.argv("secret-tool")
        #expect(calls.count == 1 && calls[0].first == "store" && calls[0].contains("net.praxient.vizier"))
        #expect(!calls.flatMap { $0 }.contains { $0.contains(secret) })  // never argv
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "keys.json").path))
        // A locked keyring: the file takes it.
        try Data().write(to: URL(fileURLWithPath: "\(bins.directory)/locked"))
        #expect(try await offThePool { try store.storeReporting(secret, account: "elevenlabs") } == .file)
        #expect(try FileSecretStore(directory: directory).read("elevenlabs") == secret)
        // No secret-tool at all: the file again.
        let bare = FakeBins()
        let plain = LinuxSecretStore(environment: bare.environment(), configDirectory: directory, secretServiceLocator: FakeLocator(bare))
        #expect(try plain.storeReporting("another", account: "gemini") == .file)
        #expect(throws: SecretError.self) { try plain.storeReporting("x", account: "openai") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct KeyCommandTests {
    @Test func setStatusAndDeleteNeverPrintTheKey() async throws {
        let bins = FakeBins(); _ = installSecretTool(bins)
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let secret = "AIza-never-print-me-987"
        let env = bins.environment()
        let set = try await offThePool { KeyCommand.run(args: ["action": .string("set"), "account": .string("gemini")], environment: env, configDirectory: directory, secretServiceLocator: FakeLocator(bins), readKey: { secret + "\n" }) }
        #expect(set.ok && set.result?["storedIn"] == .string("secret-service"))
        let status = try await offThePool { KeyCommand.run(args: ["action": .string("status")], environment: env, configDirectory: directory, secretServiceLocator: FakeLocator(bins)) }
        #expect(status.ok)
        let shown = KeyCommand.describe(status.result!) + KeyCommand.describe(set.result!)
        let encoded = String(decoding: try Wire.line(set) + (try Wire.line(status)), as: UTF8.self)
        #expect(!shown.contains(secret) && !encoded.contains(secret))
        #expect(shown.contains("Gemini: set (from secret-service)") && shown.contains("ElevenLabs: not set"))
        // An environment variable wins, and set says so.
        let overridden = try await offThePool { KeyCommand.run(args: ["action": .string("set"), "account": .string("gemini")], environment: bins.environment(["VIZIER_GEMINI_API_KEY": "env-key"]), configDirectory: directory, secretServiceLocator: FakeLocator(bins), readKey: { secret }) }
        #expect(overridden.result?["note"]?.string?.contains("VIZIER_GEMINI_API_KEY") == true)
        let removed = try await offThePool { KeyCommand.run(args: ["action": .string("delete"), "account": .string("gemini")], environment: env, configDirectory: directory, secretServiceLocator: FakeLocator(bins)) }
        #expect(removed.ok)
        #expect(try await offThePool { KeyCommand.run(args: ["action": .string("status"), "account": .string("gemini")], environment: env, configDirectory: directory, secretServiceLocator: FakeLocator(bins)) }.result?["keys"] != nil)
        let after = LinuxSecretStore(environment: env, configDirectory: directory, secretServiceLocator: FakeLocator(bins))
        let left = try await offThePool { try after.read("gemini") }
        #expect(left == nil, "left: \(left ?? "nil") argv: \(bins.argv("secret-tool"))")
    }

    @Test func emptyOrMalformedInputStoresNothing() throws {
        let bins = FakeBins(); _ = installSecretTool(bins)
        let directory = configDirectory(); defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        for bad in ["", "  \n", "two words", "line1\nline2", String(repeating: "x", count: 600)] {
            let reply = KeyCommand.run(args: ["action": .string("set"), "account": .string("gemini")], environment: bins.environment(), configDirectory: directory, secretServiceLocator: FakeLocator(bins), readKey: { bad })
            #expect(!reply.ok && ["empty_key", "invalid_key"].contains(reply.error?.code ?? ""))
            #expect(bad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !"\(reply.error?.message ?? "") \(reply.error?.next ?? "")".contains(bad))
        }
        #expect(bins.argv("secret-tool").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func parsingRefusesAKeyOnTheCommandLineWithoutEchoingIt() throws {
        let secret = "sk-typed-on-the-command-line"
        do {
            _ = try Invocation.parse(["key", "set", secret])
            Issue.record("a key argument was accepted")
        } catch let error as CLIError {
            #expect(error.code == "usage" && !error.message.contains(secret) && !error.next.contains(secret))
        }
        do { _ = try Invocation.parse(["key", "set", "gemini", secret]); Issue.record("extra argument accepted") } catch let error as CLIError { #expect(!error.message.contains(secret)) }
        let ok = try Invocation.parse(["key", "set", "gemini", "--stdin", "--json"])
        #expect(ok.command == "key" && ok.args["account"] == .string("gemini") && ok.args["action"] == .string("set") && ok.json)
        #expect(try Invocation.parse(["key", "status"]).args["account"] == nil)
        #expect(throws: CLIError.self) { try Invocation.parse(["key", "set"]) }
    }
}

/// `secret-tool` runs on the caller's thread, so a key is stored even while every cooperative thread
/// is taken. The pool is filled in a child process of this test runner, so nothing else waits.
@Suite(.timeLimit(.minutes(1))) struct SecretToolWithoutThePoolTests {
    private static let childVariable = "VIZIER_SATURATED_POOL_CHILD_PATH"

    private struct NoBus: SecretServiceLocator {
        func search(account: String) async throws -> SecretServiceSearch { throw SecretError.backend("no bus") }
    }

    /// The child: more blocked tasks than the pool will have threads, queued before the store. A
    /// store that needed a pool thread would wait until they give up after 8 s (libdispatch adds
    /// about one thread a second while all of them are blocked).
    @Test(.enabled(if: ProcessInfo.processInfo.environment[childVariable] != nil, "only runs as the saturated-pool test's child"))
    func aKeyIsStoredWhileEveryPoolThreadIsTakenChild() throws {
        let path = try #require(ProcessInfo.processInfo.environment[Self.childVariable])
        let gate = DispatchSemaphore(value: 0)
        let blockers = 256
        for _ in 0..<blockers { Task.detached { _ = gate.wait(timeout: .now() + 8) } }
        defer { for _ in 0..<blockers { gate.signal() } }
        let store = SecretToolStore(environment: ["PATH": path], locator: NoBus())
        let started = ContinuousClock.now
        try store.store("sk-saturated-pool-key", account: "gemini")
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(3), "storing waited \(elapsed) for a cooperative thread")
    }

    @Test func aKeyIsStoredWhileEveryPoolThreadIsTaken() async throws {
        let bins = FakeBins(); let vault = installSecretTool(bins)
        let runner = CommandLine.arguments[0]
        try #require(FileManager.default.isExecutableFile(atPath: runner), "the test runner can start itself: \(runner)")
        let environment = ProcessInfo.processInfo.environment.merging([Self.childVariable: bins.directory]) { $1 }
        let child = try await ProcessRunner.run(
            [runner, "--testing-library", "swift-testing", "--filter", "aKeyIsStoredWhileEveryPoolThreadIsTakenChild"],
            environment: environment, timeout: .seconds(20))
        let output = child.stdoutText + child.stderrText
        // The child ran the test (an empty selection also exits 0) and it passed.
        #expect(output.contains("Test aKeyIsStoredWhileEveryPoolThreadIsTakenChild() passed"), "\(output.suffix(2000))")
        #expect(child.exitCode == 0 && !child.timedOut)
        #expect((try? String(contentsOfFile: "\(vault)/gemini", encoding: .utf8)) == "sk-saturated-pool-key")
    }
}

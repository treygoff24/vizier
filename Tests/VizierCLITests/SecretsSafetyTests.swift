import Foundation
import Glibc
import Testing
import VizierEngine
@testable import VizierCLI

private func scratch() -> URL {
    URL(fileURLWithPath: "/tmp/vzsec-\(UUID().uuidString.prefix(8))")
}

private func modeBits(_ path: String) -> mode_t {
    var info = stat()
    precondition(stat(path, &info) == 0)
    return info.st_mode & 0o7777
}

/// The keys.json directory and file are checked on the descriptors that are then used.
@Suite struct SecretsFileSafetyTests {
    @Test func aSymlinkedConfigDirectoryIsRefusedForReadAndWriteAndNothingIsWrittenThroughIt() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = root.appending(path: "vizier")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = FileSecretStore(directory: link)
        #expect(throws: SecretError.self) { try store.store("k", account: "gemini") }
        #expect(throws: SecretError.self) { try store.read("gemini") }
        #expect(throws: SecretError.self) { try store.delete("gemini") }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true, "something was written through the symlink")
    }

    @Test func aDirectoryWithForeignModeBitsIsFixedToOwnerOnly() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "vizier")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(modeBits(directory.path) == 0o755)
        let store = FileSecretStore(directory: directory)
        try store.store("secret-value", account: "gemini")
        #expect(modeBits(directory.path) == 0o700)
        #expect(modeBits(store.url.path) == 0o600)
        // A read alone also closes a directory that was opened up since.
        #expect(chmod(directory.path, 0o777) == 0)
        #expect(try store.read("gemini") == "secret-value")
        #expect(modeBits(directory.path) == 0o700)
    }

    @Test func aFileSubstitutedForTheKeyFileIsRefused() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "vizier")
        let store = FileSecretStore(directory: directory)
        try store.store("real-key", account: "gemini")
        // A symlink to another 0600 file that holds valid JSON: not followed.
        let decoy = root.appending(path: "decoy.json")
        try Data("{\"gemini\": \"decoy-key\"}".utf8).write(to: decoy)
        #expect(chmod(decoy.path, 0o600) == 0)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: decoy)
        #expect(throws: SecretError.self) { try store.read("gemini") }
        #expect(throws: SecretError.self) { try store.store("other", account: "elevenlabs") }
        // A directory in the file's place is not a regular file.
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: SecretError.self) { try store.read("gemini") }
        // A fifo would block a path-based read forever; it is refused without opening for data.
        try FileManager.default.removeItem(at: store.url)
        #expect(mkfifo(store.url.path, 0o600) == 0)
        #expect(throws: SecretError.self) { try store.read("gemini") }
    }
}

/// A failing helper's stderr is never put in any message the user or a script sees.
@Suite struct SecretsStderrTests {
    private let planted = "SYNTHETIC-STDERR-SECRET-7731"

    @Test func aFailingSecretToolsStderrAppearsInNoKeyStatusOrSetupOutput() async throws {
        let bins = FakeBins()
        try FileManager.default.createDirectory(atPath: "\(bins.directory)/vault", withIntermediateDirectories: true)
        // The bus lists an unlocked item (so a lookup is tried), and every tool call fails noisily.
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(bins.directory)/vault/gemini"))
        bins.installScript("secret-tool", "echo '\(planted) at /home/someone/.local/share/keyrings' >&2; exit 1")
        bins.add("systemctl", body: "echo '\(planted)' >&2; exit 1", reads: false)
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "vizier")
        let env = bins.environment()
        let locator = FakeLocator(bins)

        var everything = ""
        for action in ["status", "delete", "set"] {
            var args: [String: JSONValue] = ["action": .string(action)]
            if action != "status" { args["account"] = .string("gemini") }
            let reply = KeyCommand.run(args: args, environment: env, configDirectory: directory, secretServiceLocator: locator, readKey: { "AIza-key" })
            everything += String(decoding: try Wire.line(reply), as: UTF8.self)
            if let result = reply.result { everything += KeyCommand.describe(result) }
            if let error = reply.error { everything += "\(error.message) \(error.next)" }
        }
        // The failure was real (a backend error reached the output) but carries only fixed words.
        #expect(everything.contains("secret-tool"), "the failure should be reported: \(everything)")
        #expect(!everything.contains(planted) && !everything.contains("/home/someone"), "stderr leaked: \(everything)")

        // The store's own error, directly.
        do { _ = try SecretToolStore(environment: env, locator: locator).read("gemini"); Issue.record("the failing tool was not reported") }
        catch { #expect(!"\(error)".contains(planted)) }

        // And `vizier setup --autostart` when systemctl fails.
        let setupRoot = scratch(); defer { try? FileManager.default.removeItem(at: setupRoot) }
        let result = await Setup.run(Setup.Options(autostart: true), environment: Setup.Environment(
            variables: bins.environment(["DISPLAY": ":99"]), configDirectory: setupRoot.appending(path: "config"), dataDirectory: setupRoot.appending(path: "data"),
            executable: "/usr/bin/vizier", systemdUserDirectory: setupRoot.appending(path: "systemd/user"),
            desktop: DesktopSession(display: .x11, family: .other, currentDesktop: ""), useSecretService: false, distro: .debian))
        let shown = Setup.describe(result) + String(decoding: try Wire.line(Reply(id: 1, result: result)), as: UTF8.self)
        #expect(result["autostart"]?["error"]?.string?.contains("failed") == true)
        #expect(!shown.contains(planted), "systemctl stderr leaked into setup output")
    }
}

/// The session's view of the keys: a snapshot that never touches a backend when read.
@Suite struct SnapshotSecretStoreTests {
    @Test func readsComeFromTheSnapshotAndNeverWaitOnTheBackend() async throws {
        let slow = StalledSecretStore(stall: 0.6)
        let snapshot = SnapshotSecretStore(source: slow)
        // Before the first refresh there is an honest failure, immediately.
        let begun = ContinuousClock.now
        #expect(throws: SecretError.self) { try snapshot.read("gemini") }
        #expect(begun.duration(to: .now) < .milliseconds(100))
        let refreshing = Task { await snapshot.refresh() }
        // While the backend stalls the read still answers at once.
        try await Task.sleep(for: .milliseconds(50))
        let reading = ContinuousClock.now
        #expect(throws: SecretError.self) { try snapshot.read("gemini") }
        #expect(reading.duration(to: .now) < .milliseconds(100))
        await refreshing.value
        #expect(try snapshot.read("gemini") == "test-key")
        #expect(snapshot.isLoaded)
    }

    @Test func aBackendFailureIsRememberedPerKeyAndFixedWordsOnly() async throws {
        struct Failing: SecretStore {
            func read(_ account: String) throws -> String? {
                if account == "gemini" { throw SecretError.backend("Secret Service has the key but its keyring is locked") }
                return nil
            }
            func store(_ value: String, account: String) throws {}
        }
        let snapshot = SnapshotSecretStore(source: Failing())
        await snapshot.refresh()
        #expect(throws: SecretError.self) { try snapshot.read("gemini") }
        #expect(try snapshot.read("elevenlabs") == nil)
    }
}

/// `vizier key set` reads bytes, bounded, and says which way it failed.
@Suite struct KeyInputTests {
    private func pipeWith(_ bytes: [UInt8]) -> Int32 {
        var fds: [Int32] = [0, 0]
        precondition(pipe(&fds) == 0)
        // Small enough to sit in the pipe buffer, so writing before reading cannot block.
        precondition(bytes.count <= 60_000)
        _ = bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, bytes.count) }
        close(fds[1])
        return fds[0]
    }

    @Test func aPipeIsReadToEndOfFileAsUTF8() throws {
        let fd = pipeWith(Array("AIza-sy-example\n".utf8)); defer { close(fd) }
        #expect(try KeyCommand.readInput(from: fd) == "AIza-sy-example\n")
    }

    @Test func invalidUTF8AndOversizeInputAreRefusedWithoutBeingStored() throws {
        let invalid = pipeWith([0x41, 0xFF, 0xFE, 0x42]); defer { close(invalid) }
        do { _ = try KeyCommand.readInput(from: invalid); Issue.record("invalid UTF-8 accepted") }
        catch let error as CLIError { #expect(error.code == "invalid_key") }
        // The cap is in bytes: this is 2100 characters but 4200 bytes.
        let wide = pipeWith(Array(String(repeating: "é", count: 2_100).utf8)); defer { close(wide) }
        do { _ = try KeyCommand.readInput(from: wide); Issue.record("oversize input accepted") }
        catch let error as CLIError { #expect(error.code == "invalid_key") }
        // Exactly at the cap is fine.
        let edge = pipeWith([UInt8](repeating: 0x61, count: KeyCommand.maxKeyBytes)); defer { close(edge) }
        #expect(try KeyCommand.readInput(from: edge).utf8.count == KeyCommand.maxKeyBytes)
    }

    @Test func aReadErrorIsNotTakenForEndOfFile() throws {
        do { _ = try KeyCommand.readInput(from: 987_654); Issue.record("a bad descriptor read as an empty key") }
        catch let error as CLIError { #expect(error.code == "read_failed") }
        // An empty pipe is a real end of file: an empty string, which `set` then rejects as empty_key.
        let empty = pipeWith([]); defer { close(empty) }
        #expect(try KeyCommand.readInput(from: empty) == "")
    }

    @Test func aKeyLongerThanTheLimitInBytesIsRefusedByTheCommandToo() throws {
        let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let wide = String(repeating: "é", count: 300)  // 300 characters, 600 bytes
        let reply = KeyCommand.run(args: ["action": .string("set"), "account": .string("gemini")], environment: ["PATH": "/nonexistent"], configDirectory: root.appending(path: "vizier"), useSecretService: false, readKey: { wide })
        #expect(!reply.ok && reply.error?.code == "invalid_key")
    }

    @Test func aTerminalIsReadOneLineWithEchoOffAndTheModeIsRestored() throws {
        // Glibc's overlay does not export the pty calls (they need _XOPEN_SOURCE); look them up.
        func symbol<T>(_ name: String, _: T.Type) -> T {
            unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: 0), name)!, to: T.self)
        }
        let openpt = symbol("posix_openpt", (@convention(c) (Int32) -> Int32).self)
        let grant = symbol("grantpt", (@convention(c) (Int32) -> Int32).self)
        let unlock = symbol("unlockpt", (@convention(c) (Int32) -> Int32).self)
        let slaveName = symbol("ptsname", (@convention(c) (Int32) -> UnsafeMutablePointer<CChar>?).self)
        let master = openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grant(master) == 0 && unlock(master) == 0)
        let slave = open(try #require(slaveName(master)), O_RDWR | O_NOCTTY)
        try #require(slave >= 0)
        defer { close(slave) }
        var before = termios()
        try #require(tcgetattr(slave, &before) == 0)
        try #require(before.c_lflag & tcflag_t(ECHO) != 0, "the pty should start with echo on")

        // The user types the key and a newline, then more that must not be consumed.
        // (Typed after the prompt: switching echo off discards earlier typeahead.)
        let typed = Array("sk-typed-secret-123\nleftover".utf8)
        let typist = Thread {
            Thread.sleep(forTimeInterval: 0.3)
            _ = typed.withUnsafeBytes { write(master, $0.baseAddress, typed.count) }
        }
        typist.start()
        let key = try KeyCommand.readInput(from: slave)
        #expect(key == "sk-typed-secret-123")

        // Echo was off while typing: the terminal never echoed the key back to its master side.
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &buffer, buffer.count)
        let echoed = n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : ""
        #expect(!echoed.contains("sk-typed"), "the key was echoed: \(echoed)")
        var after = termios()
        try #require(tcgetattr(slave, &after) == 0)
        #expect(after.c_lflag & tcflag_t(ECHO) != 0, "echo was not restored")
    }
}

@Suite @MainActor struct RecorderCommandSplittingTests {
    @Test func theRecorderCommandIsSplitOnSpacesAndTabsOnlyWithQuotesStayingLiteral() {
        let words = LinuxRuntime.recorderCommand(environment: ["VIZIER_RECORDER_COMMAND": "arecord\t-D  \"hw:0,0\" 'x y' $HOME \\n"])
        #expect(words == ["arecord", "-D", "\"hw:0,0\"", "'x", "y'", "$HOME", "\\n"])
    }
}

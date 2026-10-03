import Foundation
import Glibc
import Testing
@testable import VizierCLI

/// A private session bus with a fake `org.freedesktop.secrets` on it, so the real `SearchItems`
/// call (its `a{ss}` argument and its two `ao` results) goes over a real D-Bus wire. Needs
/// `dbus-daemon` and a system python3 with dbus-python and PyGObject; skipped without them, and
/// when the portal mock suite owns the bus address.
private enum PrivateBus {
    static let python = "/usr/bin/python3"
    static let available: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dbus-daemon"),
              FileManager.default.isExecutableFile(atPath: python) else { return false }
        // Looked for on disk: starting a probe process while the suite's traits are evaluated hangs.
        let modules = ["/usr/lib/python3/dist-packages/dbus", "/usr/lib/python3/dist-packages/gi"]
        return modules.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }()

    /// A child started with `posix_spawn` (Foundation's `Process` spins a dispatch worker here when
    /// stopped), its stdout readable through `firstOutput`.
    final class Child {
        let pid: pid_t
        private let output: Int32

        init(_ path: String, _ arguments: [String], environment: [String: String]) throws {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
            output = fds[0]
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            defer { posix_spawn_file_actions_destroy(&actions); close(fds[1]) }
            var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var child: pid_t = 0
            guard posix_spawn(&child, path, &actions, nil, argv, envp) == 0 else { throw POSIXError(.ENOEXEC) }
            pid = child
        }

        /// What the child wrote first, waiting up to `seconds` for it.
        func firstOutput(seconds: Int32 = 10) -> String {
            var poller = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, seconds * 1000) > 0 else { return "" }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(output, &buffer, buffer.count)
            return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : ""
        }

        func stop() {
            kill(pid, SIGKILL)  // SIGTERM can sit blocked: a spawned child inherits the test thread's signal mask
            var status: Int32 = 0
            for _ in 0..<100 where waitpid(pid, &status, WNOHANG) == 0 { Thread.sleep(forTimeInterval: 0.02) }
            close(output)
        }
    }

    /// Items by account: "unlocked" or "locked". Everything else has no item.
    static let service = """
    import sys, json, dbus, dbus.service, dbus.mainloop.glib
    from gi.repository import GLib
    log, table = sys.argv[1], json.loads(sys.argv[2])
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName('org.freedesktop.secrets', bus)
    class Service(dbus.service.Object):
        @dbus.service.method('org.freedesktop.Secret.Service', in_signature='a{ss}', out_signature='aoao')
        def SearchItems(self, attributes):
            attributes = {str(k): str(v) for k, v in attributes.items()}
            with open(log, 'a') as out: out.write(json.dumps(attributes, sort_keys=True) + '\\n')
            state = table.get(attributes.get('account', ''))
            if attributes.get('service') != 'net.praxient.vizier' or state is None: return ([], [])
            path = dbus.ObjectPath('/org/freedesktop/secrets/collection/login/1')
            return ([path], []) if state == 'unlocked' else ([], [path])
    Service(bus, '/org/freedesktop/secrets')
    print('ready', flush=True)
    GLib.MainLoop().run()
    """
}

@Suite(.serialized, .enabled(if: PrivateBus.available && ProcessInfo.processInfo.environment["VIZIER_PORTAL_MOCK"] == nil))
struct SecretsBusTests {
    @Test func theSecretServiceSearchTellsAnUnlockedItemFromALockedOneFromNone() async throws {
        let root = URL(fileURLWithPath: "/tmp/vzbus-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "searches.log").path

        let daemon = try PrivateBus.Child("/usr/bin/dbus-daemon", ["--session", "--nofork", "--print-address=1", "--address=unix:path=\(root.appending(path: "bus").path)"], environment: ["PATH": "/usr/bin:/bin"])
        defer { daemon.stop() }
        let address = daemon.firstOutput().trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(address.hasPrefix("unix:"), "the private bus did not start")

        let fake = try PrivateBus.Child(PrivateBus.python, ["-c", PrivateBus.service, log, #"{"gemini": "unlocked", "elevenlabs": "locked"}"#],
                                        environment: ["DBUS_SESSION_BUS_ADDRESS": address, "PATH": "/usr/bin:/bin"])
        defer { fake.stop() }
        try #require(fake.firstOutput().hasPrefix("ready"), "the fake Secret Service did not start")

        let previous = getenv("DBUS_SESSION_BUS_ADDRESS").map { String(cString: $0) }
        setenv("DBUS_SESSION_BUS_ADDRESS", address, 1)
        defer { if let previous { setenv("DBUS_SESSION_BUS_ADDRESS", previous, 1) } else { unsetenv("DBUS_SESSION_BUS_ADDRESS") } }

        let locator = DBusSecretServiceLocator(timeout: .seconds(10))
        #expect(try await locator.search(account: "gemini") == SecretServiceSearch(unlocked: 1, locked: 0))
        #expect(try await locator.search(account: "elevenlabs") == SecretServiceSearch(unlocked: 0, locked: 1))
        #expect(try await locator.search(account: "nothing") == SecretServiceSearch(unlocked: 0, locked: 0))
        // The attributes on the wire are the ones `secret-tool store` wrote the item under.
        let sent = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(sent.contains(#"{"account": "gemini", "service": "net.praxient.vizier"}"#), "searches seen: \(sent)")
    }
}

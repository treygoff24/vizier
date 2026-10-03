#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import VizierCLI

private struct PortalSnapshot: Decodable, Sendable {
    struct Selection: Decodable, Sendable {
        let types: UInt32
        let persist_mode: UInt32
        let restore_token: String?
    }
    let events: [String]
    let keys: [[Int32]]
    let clipboard: String
    let held: [Int32]
    let key_methods: [String]
    let close_held: [Int32]
    let closed: [String]
    let ownerships: Int
    let forged: Int
    let forged_responses: Int
    let done: Bool
    let registered: Bool
    let select: Selection?
}

@MainActor private final class PortalCounter: Sendable {
    var toggles = 0
    var cancels = 0
    func toggle() { MainActor.preconditionIsolated(); toggles += 1 }
    func cancel() { MainActor.preconditionIsolated(); cancels += 1 }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VIZIER_PORTAL_MOCK"] != nil))
struct PortalTests {
    private func bus() async throws -> DBusConnection {
        let env = ProcessInfo.processInfo.environment
        // Fail closed: never drive a real desktop portal from tests.
        try #require(env["VIZIER_PORTAL_MOCK"] == env["DBUS_SESSION_BUS_ADDRESS"])
        let connection = try await DBusConnection.open()
        // Verify the mock control interface before any call that could request consent.
        _ = try await connection.call(interface: "net.praxient.vizier.Mock", member: "Snapshot")
        return connection
    }
    private func configure(_ bus: DBusConnection, _ options: [String: DBusValue]) async throws {
        _ = try await bus.call(interface: "net.praxient.vizier.Mock", member: "Configure", arguments: [.dictionary(options)])
    }
    private func command(_ bus: DBusConnection, _ member: String, _ args: [DBusValue] = []) async throws {
        _ = try await bus.call(interface: "net.praxient.vizier.Mock", member: member, arguments: args)
    }
    private func snapshot(_ bus: DBusConnection) async throws -> PortalSnapshot {
        let values = try await bus.call(interface: "net.praxient.vizier.Mock", member: "Snapshot")
        let json = try #require(values.first?.string)
        return try JSONDecoder().decode(PortalSnapshot.self, from: Data(json.utf8))
    }
    private func state() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vizier-portal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Portal mock condition never became true")
    }

    @Test func idleConnectionsDoNotWakePeriodically() async throws {
        let first = try await bus()
        let second = try await bus()
        func switches() -> Int {
            let root = "/proc/self/task"
            return ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).reduce(0) { total, tid in
                let status = (try? String(contentsOfFile: root + "/" + tid + "/status", encoding: .utf8)) ?? ""
                let line = status.split(separator: "\n").first { $0.hasPrefix("voluntary_ctxt_switches:") }
                return total + (line.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let before = switches()
        try await Task.sleep(for: .seconds(2))
        let delta = switches() - before
        print("Portal idle voluntary context switches over 2 seconds: \(delta)")
        #expect(delta < 50)
        // Keep both connections alive across the measurement.
        #expect(first.uniqueName != second.uniqueName)
    }

    @Test func typedTransportRoundTrip() async throws {
        let bus = try await bus()
        let dictionary: [String: DBusValue] = [
            "string": .string("synthetic λ"), "path": .objectPath("/synthetic/path"),
            "bool": .bool(true), "uint": .uint32(42), "wide": .uint64(12345678901), "signed": .int32(-47),
            "array": .array("s", [.string("one"), .string("two")]),
            "structure": .structure([.string("toggle"), .dictionary(["trigger": .string("CTRL+ALT+space")])]),
            "nested": .dictionary(["enabled": .bool(false)]),
        ]
        let reply = try await bus.call(interface: "net.praxient.vizier.Mock", member: "Echo", arguments: [.dictionary(dictionary)])
        #expect(reply == [.dictionary(dictionary)])
    }

    @Test func presenceDoesNotClaimConsentAndMissingInterfaceIsUnavailable() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        let present = await remote.probe()
        #expect(!present.available)
        #expect(present.detail.contains("RemoteDesktop v2 present"))
        #expect(present.detail.contains("Consent not granted"))
        #expect(try await snapshot(bus).registered)
        try await configure(bus, ["missing_interface": .bool(true)])
        let absent = await remote.probe()
        #expect(!absent.available)
        #expect(!absent.detail.contains("v2 present"))
    }

    @Test func responseBeforeReplyClipboardFDAndTokenPersistence() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await remote.prepare()
        #expect(await remote.probe().available)
        let payload = "Synthetic clipboard λ\n" + String(repeating: "generated ", count: 20000)
        try await remote.publish(payload)
        #expect(!(try await snapshot(bus)).done)
        #expect(try await snapshot(bus).ownerships == 1)
        try await command(bus, "ReadClipboard", [.string("text/plain")])
        try await eventually { try await snapshot(bus).done }
        let first = try await snapshot(bus)
        #expect(first.clipboard == payload)
        #expect(first.select?.types == 1)
        #expect(first.select?.persist_mode == 2)
        #expect(first.select?.restore_token == nil)
        let events = first.events
        let requestClipboard = try #require(events.firstIndex(of: "RequestClipboard"))
        let start = try #require(events.firstIndex(of: "Start"))
        #expect(requestClipboard < start)
        let tokenFile = directory.appendingPathComponent("portal.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let token = PortalTokenStore(directory: directory).read()
        #expect(token == "synthetic-restore-token")
        await remote.stop()
        try await remote.prepare()
        #expect(try await snapshot(bus).select?.restore_token == "synthetic-restore-token")
        await remote.stop()
    }

    @Test func keyOrderingAndAmbiguousFailureNeverThrowsForFallback() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await remote.prepare()
        try await remote.send(.ctrlV)
        try await remote.send(.ctrlShiftV)
        let expected: [[Int32]] = [[0xffe3,1],[0x76,1],[0x76,0],[0xffe3,0],[0xffe3,1],[0xffe1,1],[0x76,1],[0x76,0],[0xffe1,0],[0xffe3,0]]
        #expect(try await snapshot(bus).keys == expected)
        try await configure(bus, ["fail_key": .uint32(12)]) // second call of this chord records before failing
        try await remote.send(.ctrlV)
        #expect(try await snapshot(bus).keys == expected + [[0xffe3,1],[0x76,1],[0x76,0],[0xffe3,0]])
        #expect(!(await remote.probe()).available)
        await #expect(throws: PortalFailure.self) { try await remote.send(.ctrlV) }
        await remote.stop()
    }

    @Test func shortcutsRebindAndActivateOnMainActor() async throws {
        let bus = try await bus()
        let counter = PortalCounter()
        let shortcuts = PortalGlobalShortcuts(connection: bus, toggleTrigger: "CTRL+ALT+d", cancelTrigger: "CTRL+ALT+c")
        #expect(!(await shortcuts.probe()).available)
        try await shortcuts.start(onToggle: { counter.toggle() }, onCancel: { counter.cancel() })
        #expect(await shortcuts.probe().available)
        try await command(bus, "Activate", [.string("toggle")])
        try await command(bus, "Activate", [.string("cancel")])
        try await eventually {
            let toggles = await counter.toggles
            let cancels = await counter.cancels
            return toggles == 1 && cancels == 1
        }
        // Inspect the actual serialized shortcut tuples, not just registration success.
        let values = try await bus.call(interface: "net.praxient.vizier.Mock", member: "Snapshot")
        let json = try #require(values.first?.string)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let bindings = try #require(object["bindings"] as? [[Any]])
        #expect(bindings.count == 2)
        #expect(bindings[0][0] as? String == "toggle")
        #expect((bindings[0][1] as? [String: String])?["preferred_trigger"] == "CTRL+ALT+d")
        #expect((bindings[1][1] as? [String: String])?["preferred_trigger"] == "CTRL+ALT+c")
        await shortcuts.stop()
        try await shortcuts.start(onToggle: { counter.toggle() }, onCancel: { counter.cancel() })
        #expect(try await snapshot(bus).events.filter { $0 == "BindShortcuts" }.count == 2)
        await shortcuts.stop()
    }

    @Test func sessionClosureRevokesDeliveryAndHotkeys() async throws {
        let remoteBus = try await bus()
        let hotkeyBus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: remoteBus, stateDirectory: directory)
        let counter = PortalCounter()
        let shortcuts = PortalGlobalShortcuts(connection: hotkeyBus)
        try await remote.prepare()
        try await shortcuts.start(onToggle: { counter.toggle() }, onCancel: { counter.cancel() })
        try await command(remoteBus, "CloseSessions")
        try await command(hotkeyBus, "CloseSessions")
        try await eventually {
            let remoteReady = await remote.probe().available
            let shortcutsReady = await shortcuts.probe().available
            return !remoteReady && !shortcutsReady
        }
        await #expect(throws: PortalFailure.self) { try await remote.publish("synthetic") }
        await #expect(throws: PortalFailure.self) { try await remote.send(.ctrlV) }
        try await command(hotkeyBus, "Activate", [.string("toggle")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await counter.toggles == 0)
        await remote.stop(); await shortcuts.stop()
    }

    @Test func deniedConsentAndDeliveryNeverStartsDialog() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        await #expect(throws: PortalFailure.self) { try await remote.publish("synthetic") }
        await #expect(throws: PortalFailure.self) { try await remote.send(.ctrlV) }
        #expect(try await snapshot(bus).events.isEmpty)
        try await configure(bus, ["deny_start": .bool(true)])
        await #expect(throws: PortalFailure.self) { try await remote.prepare() }
        #expect(!(await remote.probe()).available)
        #expect(await remote.probe().detail.contains("denied or cancelled"))
        #expect(PortalTokenStore(directory: directory).read() == nil)
        try await configure(bus, ["deny_start": .bool(false), "deny_clipboard": .bool(true)])
        await #expect(throws: PortalFailure.self) { try await remote.prepare() }
        #expect(!(await remote.probe()).available)
        #expect(await remote.probe().detail.contains("clipboard consent"))
        await remote.stop()
    }

    @Test func portalRestartInvalidatesAndRegistersAgain() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await remote.prepare()
        try await command(bus, "Restart")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!(await remote.probe()).available)
        #expect(try await snapshot(bus).registered)
        try await remote.prepare()
        #expect(await remote.probe().available)
        await remote.stop()
    }

    @Test func registryAbsenceExplainsGNOMERequirement() async throws {
        let bus = try await bus()
        try await configure(bus, ["no_registry": .bool(true)])
        let shortcuts = PortalGlobalShortcuts(connection: bus)
        let probe = await shortcuts.probe()
        #expect(!probe.available)
        #expect(probe.detail.contains("Registry.Register unavailable or rejected"))
        #expect(probe.detail.contains("net.praxient.vizier.desktop"))
    }
    @Test func publicationRequiresOwnershipNotJustMethodReply() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await remote.prepare()
        try await configure(bus, ["no_ownership": .bool(true)])
        await #expect(throws: PortalFailure.self) { try await remote.publish("synthetic") }
        #expect(!(await remote.probe()).available)
        #expect(try await snapshot(bus).closed.contains { $0.contains("/session/") })
        await remote.stop()
        try await configure(bus, ["no_ownership": .bool(false), "false_ownership": .bool(true)])
        try await remote.prepare()
        await #expect(throws: PortalFailure.self) { try await remote.publish("synthetic") }
        await remote.stop()
    }

    @Test func foreignSignalsCannotRevokeActivateOrGrantConsent() async throws {
        let remoteBus = try await bus()
        let hotkeyBus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: remoteBus, stateDirectory: directory)
        let shortcuts = PortalGlobalShortcuts(connection: hotkeyBus)
        let counter = PortalCounter()
        try await remote.prepare()
        try await shortcuts.start(onToggle: { counter.toggle() }, onCancel: { counter.cancel() })
        try await command(remoteBus, "Forge")
        try await command(hotkeyBus, "Forge")
        try await eventually { try await snapshot(remoteBus).forged == 3 }
        try await eventually { try await snapshot(hotkeyBus).forged == 3 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await remote.probe().available)
        #expect(await shortcuts.probe().available)
        #expect(await counter.toggles == 0)
        await remote.stop(); await shortcuts.stop()
        try await configure(remoteBus, ["deny_start": .bool(true), "forge_start_response": .bool(true)])
        await #expect(throws: PortalFailure.self) { try await remote.prepare() }
        #expect(!(await remote.probe()).available)
        #expect(try await snapshot(remoteBus).forged_responses == 1)
        await remote.stop()
    }

    @Test func toggleOnlyBindingRemainsUsable() async throws {
        let bus = try await bus()
        let counter = PortalCounter()
        try await configure(bus, ["toggle_only": .bool(true)])
        let shortcuts = PortalGlobalShortcuts(connection: bus)
        try await shortcuts.start(onToggle: { counter.toggle() }, onCancel: { counter.cancel() })
        let probe = await shortcuts.probe()
        #expect(probe.available)
        #expect(probe.detail.contains("cancel is not bound"))
        try await command(bus, "Activate", [.string("toggle")])
        try await command(bus, "Activate", [.string("cancel")])
        try await eventually { await counter.toggles == 1 }
        #expect(await counter.cancels == 0)
        await shortcuts.stop()
    }

    @Test func explicitKeysymRefusalFallsBackBeforeAnyKeyWasSent() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await configure(bus, ["refuse_keysym": .bool(true)])
        try await remote.prepare()
        try await remote.send(.ctrlShiftV)
        let result = try await snapshot(bus)
        #expect(result.keys == [[29,1],[42,1],[47,1],[47,0],[42,0],[29,0]])
        #expect(result.key_methods.allSatisfy { $0 == "NotifyKeyboardKeycode" })
        #expect(await remote.probe().available)
        await remote.stop()
    }

    @Test func invalidationDuringChordReleasesKeysAndClosesSession() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await remote.prepare()
        let send = Task { try await remote.send(.ctrlShiftV) }
        try await eventually { !(try await snapshot(bus)).held.isEmpty }
        send.cancel()
        _ = try await send.value
        let result = try await snapshot(bus)
        #expect(result.held.isEmpty)
        #expect(result.close_held.isEmpty)
        #expect(result.closed.contains { $0.contains("/session/") })
        #expect(!(await remote.probe()).available)
        await remote.stop()
        try await remote.prepare()
        let next = Task { try await remote.send(.ctrlShiftV) }
        try await eventually { !(try await snapshot(bus)).held.isEmpty }
        try await command(bus, "CloseSessions")
        _ = try await next.value
        #expect(try await snapshot(bus).held.isEmpty)
        await remote.stop()
    }

    @Test func receivedFileDescriptorIsCloseOnExec() async throws {
        let bus = try await bus()
        let values = try await bus.call(interface: "net.praxient.vizier.Mock", member: "FD")
        let value = try #require(values.first)
        guard case .unixFD(let fd) = value else { Issue.record("Missing received descriptor"); return }
        defer { _ = Glibc.close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func futureOptionsDoNotDestroyClipboardSubscription() async throws {
        let bus = try await bus()
        let directory = try state()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = PortalRemoteDesktop(connection: bus, stateDirectory: directory)
        try await configure(bus, ["unknown_options": .bool(true)])
        try await remote.prepare()
        try await remote.publish("synthetic")
        #expect(await remote.probe().available)
        try await command(bus, "ReadClipboard", [.string("UTF8_STRING")])
        try await eventually { try await snapshot(bus).done }
        #expect(try await snapshot(bus).clipboard == "synthetic")
        try await command(bus, "StaleTransfer")
        try await eventually { !(try await snapshot(bus)).done }
        await remote.stop()
    }

    @Test func concurrentRegistrationWaitsForOneFlight() async throws {
        let bus = try await bus()
        try await configure(bus, ["register_delay_ms": .uint32(100)])
        let client = PortalClient(connection: bus)
        async let remote = client.version("org.freedesktop.portal.RemoteDesktop")
        async let clipboard = client.version("org.freedesktop.portal.Clipboard")
        #expect(try await remote == 2)
        #expect(try await clipboard == 1)
        let result = try await snapshot(bus)
        #expect(result.registered)
        #expect(result.events.filter { $0 == "Register" }.count == 1)
    }

    @Test func unexpectedRequestHandleClosesReturnedDialog() async throws {
        let bus = try await bus()
        let client = PortalClient(connection: bus)
        try await configure(bus, ["different_request": .bool(true)])
        await #expect(throws: PortalFailure.self) {
            _ = try await client.request("org.freedesktop.portal.GlobalShortcuts", "CreateSession", options: ["session_handle_token": .string("synthetic")])
        }
        #expect(try await snapshot(bus).closed.contains { $0.hasSuffix("_legacy") })
    }

    @Test func cancelledMatchesAreRemovedOnSuppliedConnection() async throws {
        let bus = try await bus()
        func rules() async throws -> UInt32 {
            let values = try await bus.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus.Debug.Stats", member: "GetConnectionStats", arguments: [.string(bus.uniqueName)])
            return try #require(values.first?.dictionary?["MatchRules"]?.uint32)
        }
        let before = try await rules()
        for _ in 0..<20 {
            let signals = try await bus.match(interface: "net.praxient.vizier.Mock", member: "Unused")
            signals.cancel()
        }
        #expect(try await rules() == before)
    }

}
#endif

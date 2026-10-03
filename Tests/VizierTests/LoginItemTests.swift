import Foundation
import ServiceManagement
import Testing
@testable import Vizier

@Suite struct LoginItemTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    @Test func theSystemApplicationsFolderIsAnInstall() {
        #expect(LoginItem.isInstalledLocation(URL(filePath: "/Applications/Vizier.app"), home: home))
    }

    @Test func theUsersApplicationsFolderIsAnInstall() {
        #expect(LoginItem.isInstalledLocation(home.appending(path: "Applications/Vizier.app"), home: home))
    }

    @Test func buildFoldersAreNeverAnInstall() {
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Users/someone/Code/vizier/build/Vizier.app"), home: home))
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Users/someone/Code/vizier/.build/release/Vizier.app"), home: home))
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Users/someone/Downloads/Vizier.app"), home: home))
    }

    @Test func onlyVizierDirectlyInsideAnApplicationsFolderCounts() {
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Applications/Other.app"), home: home))
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Applications/Utilities/Vizier.app"), home: home))
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Applications/Vizier.app/Contents/MacOS"), home: home))
        #expect(!LoginItem.isInstalledLocation(URL(filePath: "/Volumes/Vizier/Applications/Vizier.app"), home: home))
    }

    @Test func aLinkInApplicationsThatPointsAtABuildFolderIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "vizier-login-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        let build = root.appending(path: "build/Vizier.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = applications.appending(path: "Vizier.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: build)
        // A real copy in the same folder is accepted (precondition: the check can say yes here)...
        let real = root.appending(path: "other-home/Applications/Vizier.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        #expect(LoginItem.isInstalledLocation(real, home: root.appending(path: "other-home", directoryHint: .isDirectory)))
        // ...but the link, which resolves into build/, is not.
        #expect(!LoginItem.isInstalledLocation(link, home: root))
    }

    // Open at Login after a move: Dictum.app became Vizier.app on 2026-10-03.
    private let here = "/Users/someone/Applications/Vizier.app"

    @Test func anEnabledLoginItemRegisteredElsewhereIsRegisteredAgain() {
        #expect(LoginItem.needsRepoint(status: .enabled, recordedPath: "/Users/someone/Applications/Dictum.app", currentPath: here))
        // Builds before the rename recorded no path.
        #expect(LoginItem.needsRepoint(status: .enabled, recordedPath: nil, currentPath: here))
    }

    @Test func anEnabledLoginItemAlreadyAtThisPathIsLeftAlone() {
        #expect(!LoginItem.needsRepoint(status: .enabled, recordedPath: here, currentPath: here))
    }

    @Test func aLoginItemThatIsOffStaysOff() {
        #expect(!LoginItem.needsRepoint(status: .notRegistered, recordedPath: nil, currentPath: here))
        #expect(!LoginItem.needsRepoint(status: .requiresApproval, recordedPath: "/Applications/Dictum.app", currentPath: here))
    }
}

/// A stand-in for `SMAppService.mainApp`: it records each call, and fails a call while told to.
final class FakeLoginService: LoginItemService {
    struct Refused: Error {}
    var status: SMAppService.Status
    var registerFails = false
    private(set) var calls: [String] = []

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        calls.append("register")
        if registerFails { throw Refused() }
        status = .enabled
    }

    func unregister() throws {
        calls.append("unregister")
        status = .notRegistered
    }
}

/// Repointing Open at Login after the bundle moved, against a fake service and a throwaway
/// defaults domain: each `launch` is one app launch's `repointIfMoved`.
@Suite struct LoginItemRepointTests {
    private let here = "/Users/someone/Applications/Vizier.app"
    private let suite = "vizier-login-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let service = FakeLoginService(status: .enabled)

    init() { defaults = UserDefaults(suiteName: suite)! }

    private var context: LoginItem.Context {
        LoginItem.Context(service: service, defaults: defaults, installed: true, currentPath: here)
    }

    private func launch() -> [String] {
        let before = service.calls.count
        LoginItem.repointIfMoved(context)
        return Array(service.calls.dropFirst(before))
    }

    @Test func aRepointThatWorksRecordsThePathAndLeavesNothingPending() {
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(launch() == ["unregister", "register"])
        #expect(service.status == .enabled)
        #expect(defaults.string(forKey: "loginItemRegisteredPath") == here)
        #expect(!defaults.bool(forKey: LoginItem.pendingRepointKey))
        #expect(launch() == [])
    }

    @Test func aRegisterThatFailsAfterTheUnregisterIsRetriedOnTheNextLaunch() {
        defer { defaults.removePersistentDomain(forName: suite) }
        service.registerFails = true
        #expect(launch() == ["unregister", "register"])
        // The login item is now off, which needsRepoint alone would never touch again.
        #expect(service.status == .notRegistered)
        #expect(!LoginItem.needsRepoint(status: service.status, recordedPath: nil, currentPath: here))
        #expect(defaults.bool(forKey: LoginItem.pendingRepointKey))
        // Still failing: tried again, still pending.
        #expect(launch() == ["register"])
        #expect(defaults.bool(forKey: LoginItem.pendingRepointKey))
        service.registerFails = false
        #expect(launch() == ["register"])
        #expect(service.status == .enabled)
        #expect(defaults.string(forKey: "loginItemRegisteredPath") == here)
        #expect(!defaults.bool(forKey: LoginItem.pendingRepointKey))
        #expect(launch() == [])
    }

    @Test func turningOpenAtLoginOffCancelsAPendingRepoint() {
        defer { defaults.removePersistentDomain(forName: suite) }
        service.registerFails = true
        _ = launch()
        #expect(defaults.bool(forKey: LoginItem.pendingRepointKey))
        LoginItem.setEnabled(false, context)
        #expect(!defaults.bool(forKey: LoginItem.pendingRepointKey))
        service.registerFails = false
        #expect(launch() == [])
        #expect(service.status == .notRegistered)
    }
}

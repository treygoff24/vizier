import Foundation
import Testing
@testable import VizierEngine

@Suite struct VizierPathsTests {
    private let home = URL(filePath: "/home/someone", directoryHint: .isDirectory)

    @Test func linuxFollowsXDGAndFallsBackToTheHomeDefaults() {
        #expect(VizierPaths.xdgConfig(environment: [:], home: home).path == "/home/someone/.config/vizier")
        #expect(VizierPaths.xdgData(environment: [:], home: home).path == "/home/someone/.local/share/vizier")
        #expect(VizierPaths.xdgConfig(environment: ["XDG_CONFIG_HOME": "/etc/xc"], home: home).path == "/etc/xc/vizier")
        #expect(VizierPaths.xdgData(environment: ["XDG_DATA_HOME": "/srv/xd"], home: home).path == "/srv/xd/vizier")
        #expect(VizierPaths.xdgRuntime(environment: ["XDG_RUNTIME_DIR": "/run/user/1000"])?.path == "/run/user/1000/vizier")
    }

    @Test func aRelativeOrEmptyXDGValueIsIgnoredAsTheSpecSays() {
        #expect(VizierPaths.xdgConfig(environment: ["XDG_CONFIG_HOME": "relative/dir"], home: home).path == "/home/someone/.config/vizier")
        #expect(VizierPaths.xdgData(environment: ["XDG_DATA_HOME": ""], home: home).path == "/home/someone/.local/share/vizier")
        #expect(VizierPaths.xdgRuntime(environment: ["XDG_RUNTIME_DIR": "run/user"]) == nil)
        #expect(VizierPaths.xdgRuntime(environment: [:]) == nil)
    }

    @Test func theStandardStoresReadThePathsTable() {
        #expect(ConfigStore.standard.directory == VizierPaths.config)
        #expect(HistoryStore.standardDatabaseURL == VizierPaths.data.appending(path: "history.sqlite"))
        #expect(TakeStore.standard.root == VizierPaths.data.appending(path: "Takes"))
        #if os(macOS)
        // The Mac's folders are where the app has always kept them.
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        #expect(VizierPaths.config == userHome.appending(path: ".config/vizier"))
        #expect(VizierPaths.data == userHome.appending(path: "Library/Application Support/Vizier"))
        #expect(VizierPaths.runtime == nil)
        #endif
    }
}

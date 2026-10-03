import AVFoundation
import AppKit
import ApplicationServices

enum PermissionState: Equatable {
    case notAsked, granted, denied
}

/// The two permissions Vizier needs: Microphone, to hear you, and Accessibility, to see the hotkey
/// and paste into other apps. A protocol so onboarding is testable and renders without asking.
protocol PermissionsProbe {
    func microphone() -> PermissionState
    func requestMicrophone() async -> Bool
    func accessibilityGranted() -> Bool
    /// Shows macOS's own Accessibility prompt, which offers to open System Settings.
    func promptAccessibility()
    func openSettings(_ pane: PermissionPane)
    /// Shows Vizier's app bundle in the Finder, so it can be dragged into the Accessibility list.
    func revealApp()
}

enum PermissionPane {
    case microphone, accessibility

    var url: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

struct SystemPermissions: PermissionsProbe {
    func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func accessibilityGranted() -> Bool { AXIsProcessTrusted() }

    func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openSettings(_ pane: PermissionPane) { NSWorkspace.shared.open(pane.url) }

    func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
}

/// A scripted probe for tests and `--render-ui`.
final class FakePermissions: PermissionsProbe {
    var micState: PermissionState
    var micGrantsOnRequest: Bool
    var accessibility: Bool
    private(set) var accessibilityPrompts = 0
    private(set) var opened: [PermissionPane] = []

    init(mic: PermissionState = .notAsked, micGrantsOnRequest: Bool = true, accessibility: Bool = false) {
        micState = mic
        self.micGrantsOnRequest = micGrantsOnRequest
        self.accessibility = accessibility
    }

    func microphone() -> PermissionState { micState }
    func requestMicrophone() async -> Bool {
        micState = micGrantsOnRequest ? .granted : .denied
        return micGrantsOnRequest
    }
    func accessibilityGranted() -> Bool { accessibility }
    func promptAccessibility() { accessibilityPrompts += 1 }
    func openSettings(_ pane: PermissionPane) { opened.append(pane) }
    private(set) var reveals = 0
    func revealApp() { reveals += 1 }
}

/// The permissions as the UI shows them. Accessibility has no callback when it is granted, so the
/// onboarding step polls `refresh()` while it is on screen.
@Observable
final class PermissionsModel {
    private(set) var microphone: PermissionState
    private(set) var accessibility: Bool
    @ObservationIgnored private let probe: any PermissionsProbe

    init(probe: any PermissionsProbe) {
        self.probe = probe
        microphone = probe.microphone()
        accessibility = probe.accessibilityGranted()
    }

    var allGranted: Bool { microphone == .granted && accessibility }

    func refresh() {
        microphone = probe.microphone()
        accessibility = probe.accessibilityGranted()
    }

    func requestMicrophone() async {
        _ = await probe.requestMicrophone()
        refresh()
    }

    func promptAccessibility() { probe.promptAccessibility() }
    func openSettings(_ pane: PermissionPane) { probe.openSettings(pane) }
    func revealApp() { probe.revealApp() }
}

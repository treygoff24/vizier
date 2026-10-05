import Foundation

/// A one-shot copy of this executable reads COSMIC's app ID without starting a daemon,
/// reading config/history, or retaining window titles. The child has a two-second timeout.
public struct CosmicFocusReader: FocusReader {
    private let env: HelperEnvironment
    private let executable: String

    public init(env: HelperEnvironment = HelperEnvironment(), executable: String? = nil) {
        self.env = env
        // Resolved once, when the reader is built, which is at daemon start: it names the binary on disk then.
        // After a package upgrade the running daemon still runs the new file's --cosmic-focused-app until it
        // restarts, so that flag's output must stay stable. If the readlink fails, "vizier" is found on PATH,
        // which could be a different install.
        self.executable = executable ?? ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? "vizier")
    }

    public func focusedWindow() async -> FocusedWindow? {
        var variables = env.variables
        variables.removeValue(forKey: "WAYLAND_DEBUG")
        guard let result = try? await ProcessRunner.run([executable, "--cosmic-focused-app"], environment: variables,
                                                       timeout: .seconds(3), outputLimit: 4096), result.succeeded else { return nil }
        return Self.parse(result.stdoutText)
    }

    static func parse(_ output: String) -> FocusedWindow? {
        let app = output.trimmingCharacters(in: .newlines)
        guard !app.isEmpty, app.utf8.count <= 1024,
              !app.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { return nil }
        return FocusedWindow(appName: app, pid: nil, isTerminal: TerminalList.isTerminal(app))
    }
}

/// COSMIC's virtual keyboard protocol may report success while emitting the wrong keys.
/// Its default route therefore uses a running ydotoold, without requiring VIZIER_YDOTOOL.
/// Re-read focus just before injection; unknown focus leaves the transcript on the clipboard.
public struct CosmicKeySender: KeySender {
    public let name = "ydotool-cosmic"
    private let env: HelperEnvironment
    private let focus: any FocusReader

    public init(env: HelperEnvironment = HelperEnvironment(), focus: (any FocusReader)? = nil) {
        self.env = env
        self.focus = focus ?? CosmicFocusReader(env: env)
    }

    public func probe() async -> AdapterProbe { await YdotoolKeySender(env: env).probe() }

    public func send(_ chord: PasteChord) async throws {
        guard let window = await focus.focusedWindow(), let terminal = window.isTerminal else {
            throw AdapterError("COSMIC focus is unavailable; paste the clipboard manually")
        }
        try await YdotoolKeySender(env: env).send(terminal ? .ctrlShiftV : .ctrlV)
    }
}

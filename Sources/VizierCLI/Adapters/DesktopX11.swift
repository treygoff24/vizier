import Foundation

/// X11 clipboard: `xclip -selection clipboard` (xsel as the fallback tool). Both fork a server
/// that holds the selection until another client replaces it.
public struct X11ClipboardWriter: ClipboardReadable {
    public enum Tool: String, Sendable { case xclip, xsel }
    public let tool: Tool
    private let env: HelperEnvironment

    public var name: String { tool.rawValue }

    public init(tool: Tool, env: HelperEnvironment = HelperEnvironment()) {
        self.tool = tool
        self.env = env
    }

    /// The first of xclip, xsel that is installed, or nil.
    public static func installed(env: HelperEnvironment) -> X11ClipboardWriter? { allInstalled(env: env).first }

    /// Every one of xclip, xsel that is installed, in preference order: xsel is a real fallback
    /// when xclip is installed but fails.
    public static func allInstalled(env: HelperEnvironment) -> [X11ClipboardWriter] {
        [Tool.xclip, .xsel].filter { env.resolve($0.rawValue) != nil }.map { X11ClipboardWriter(tool: $0, env: env) }
    }

    var readbackArgv: [String] {
        switch tool {
        case .xclip: ["xclip", "-selection", "clipboard", "-o"]
        case .xsel: ["xsel", "--clipboard", "--output"]
        }
    }

    var argv: [String] {
        switch tool {
        case .xclip: ["xclip", "-selection", "clipboard", "-in"]
        case .xsel: ["xsel", "--clipboard", "--input"]
        }
    }

    public func probe() async -> AdapterProbe {
        guard env.resolve(tool.rawValue) != nil else { return Helper.missing(name, tool: tool.rawValue, env: env) }
        guard let display = env.variables["DISPLAY"], !display.isEmpty else {
            return AdapterProbe(name: name, available: false, detail: "DISPLAY is not set, so there is no X server to reach",
                                fix: "start the daemon from the graphical session (systemctl --user import-environment DISPLAY)")
        }
        return AdapterProbe(name: name, available: true, detail: "\(tool.rawValue) on DISPLAY \(display)")
    }

    public func publish(_ text: String) async throws {
        try await Helper.publish(argv, text: text, environment: env.variables, readback: readbackArgv)
    }

    public func readBack(maxBytes: Int) async -> String? {
        await Helper.read(readbackArgv, environment: env.variables, maxBytes: maxBytes)
    }
}

/// `xdotool key --clearmodifiers ctrl+v` (or ctrl+shift+v) through XTEST.
public struct XdotoolKeySender: KeySender {
    public let name = "xdotool"
    private let env: HelperEnvironment

    public init(env: HelperEnvironment = HelperEnvironment()) { self.env = env }

    public func probe() async -> AdapterProbe {
        guard env.resolve("xdotool") != nil else { return Helper.missing(name, tool: "xdotool", env: env) }
        guard let display = env.variables["DISPLAY"], !display.isEmpty else {
            return AdapterProbe(name: name, available: false, detail: "DISPLAY is not set, so there is no X server to reach",
                                fix: "start the daemon from the graphical session (systemctl --user import-environment DISPLAY)")
        }
        // One cheap call that injects nothing: proves the helper can reach the X server.
        guard let reach = try? await ProcessRunner.run(["xdotool", "getmouselocation"], environment: env.variables, timeout: .seconds(2), killGrace: .milliseconds(200), outputLimit: 1024),
              reach.succeeded else {
            return AdapterProbe(name: name, available: false, detail: "xdotool cannot reach the X server on DISPLAY \(display)",
                                fix: "check DISPLAY and XAUTHORITY in the daemon's environment (systemctl --user import-environment DISPLAY XAUTHORITY)")
        }
        return AdapterProbe(name: name, available: true, detail: "xdotool on DISPLAY \(display)")
    }

    public func send(_ chord: PasteChord) async throws {
        try await Helper.send(["xdotool", "key", "--clearmodifiers", chord.rawValue], environment: env.variables)
    }
}

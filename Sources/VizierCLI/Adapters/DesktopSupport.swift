import Foundation
import Glibc

/// A failure of a clipboard writer or key sender, with a message that is safe to log (it never
/// carries the text that was being published).
public struct AdapterError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A clipboard writer that can also read the selection back, which is how a publication is
/// proven and how the paster checks the text is still there right before the chord.
public protocol ClipboardReadable: ClipboardWriter {
    /// The text the clipboard holds now, or nil when it cannot be read (no owner, helper failed) or
    /// holds more than `maxBytes`.
    func readBack(maxBytes: Int) async -> String?
}

/// The helper ran and may have emitted keys. Never retry another injector.
struct KeyDeliveryError: Error, CustomStringConvertible {
    let description: String
}

enum Helper {
    /// Pauses between readback attempts after a publish; the first read is immediate. A server
    /// that forked takes the selection within a few milliseconds, so this is a bound, not a wait.
    static let readbackSchedule: [Duration] = [.zero, .milliseconds(30), .milliseconds(60), .milliseconds(120), .milliseconds(250), .milliseconds(400)]

    /// Publishes `text` through a helper that serves the clipboard after it returns (xclip, xsel,
    /// wl-copy). The text goes in on stdin, never argv. The helper taking its stdin is not proof it
    /// owns the selection, so after it is spawned the clipboard is read back (`readback` argv) until
    /// it holds exactly `text`. When it never does, the helper's process group is terminated and
    /// this throws: the caller must not claim the clipboard.
    static func publish(
        _ argv: [String], text: String, environment: [String: String], readback: [String],
        schedule: [Duration] = Helper.readbackSchedule
    ) async throws {
        let result: DetachedResult
        do {
            result = try await ProcessRunner.spawnDetached(argv, stdin: Data(text.utf8), environment: environment)
        } catch {
            throw AdapterError("\(argv[0]): \(error)")
        }
        func fail(_ message: String) -> AdapterError {
            terminate(result)
            return AdapterError(message)
        }
        guard result.inputDelivered else { throw fail("\(argv[0]) did not read the text") }
        if let code = result.exitCode, code != 0 { throw fail("\(argv[0]) exited with status \(code)") }
        if let signal = result.signal { throw fail("\(argv[0]) was killed by signal \(signal)") }
        for pause in schedule {
            if pause > .zero { try? await Task.sleep(for: pause) }
            if await read(readback, environment: environment, maxBytes: text.utf8.count + 16) == text { return }
        }
        throw fail("\(argv[0]) did not take the clipboard (the selection does not hold the text)")
    }

    /// The clipboard as `readback` prints it, or nil when that fails or it is longer than
    /// `maxBytes`, so a huge foreign selection costs nothing.
    static func read(_ readback: [String], environment: [String: String], maxBytes: Int) async -> String? {
        guard let result = try? await ProcessRunner.run(
            readback, environment: environment, timeout: .seconds(2), killGrace: .milliseconds(200),
            outputLimit: maxBytes),
              result.succeeded, !result.truncated else { return nil }
        return result.stdoutText
    }

    /// Stops a helper that was started for a publication that failed: its process group (the
    /// helper and the server it forked), which is its own group by construction.
    static func terminate(_ helper: DetachedResult) {
        guard helper.pid > 1 else { return }
        _ = kill(-helper.pid, SIGTERM)
        if helper.stillRunning { _ = kill(helper.pid, SIGTERM) }
    }

    /// Reports unsuccessful helpers without allowing a second injector to retry partial keys.
    static func send(_ argv: [String], environment: [String: String], timeout: Duration = .seconds(3)) async throws {
        do {
            let result = try await ProcessRunner.run(argv, environment: environment, timeout: timeout, outputLimit: 8 * 1024)
            guard result.succeeded else { throw KeyDeliveryError(description: "\(argv[0]) failed after starting; paste may have partially landed") }
        } catch let error as KeyDeliveryError {
            throw error
        } catch {
            throw AdapterError("\(argv[0]): \(error)")
        }
    }

    static func missing(_ name: String, tool: String, env: HelperEnvironment, packages: [String]? = nil, names: [DistroFamily: [String]] = [:]) -> AdapterProbe {
        AdapterProbe(
            name: name, available: false, detail: "\(tool) is not installed",
            fix: env.distro.install(packages ?? [tool], names: names))
    }
}

import Foundation
import VizierEngine

// Desktop notifications for the daemon (A2 presentation, D13's "a notification says..."). The
// preferred road is org.freedesktop.Notifications over the session bus; `notify-send` is the
// fallback; with neither, nothing is shown and the take is unaffected. A notification carries only
// a phase, a mode name and the take's remark: never transcript text.

public struct DesktopNotification: Sendable, Equatable {
    public var summary: String
    public var body: String
    /// 0 keeps it up until replaced; -1 lets the server decide.
    public var timeoutMs: Int32

    public init(summary: String, body: String, timeoutMs: Int32) {
        self.summary = summary
        self.body = body
        self.timeoutMs = timeoutMs
    }
}

public protocol NotificationSink: Sendable {
    /// Shows `notification`, replacing the one with id `replacing` when given. Returns the server's
    /// id for it (nil when the road cannot say), and throws when it could not be shown.
    func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32?
}

public struct NotificationUnavailable: Error, CustomStringConvertible {
    public var description: String { "no notification service is reachable" }
}

#if os(Linux)
/// `org.freedesktop.Notifications.Notify` on the session bus. Urgency is left at the server's
/// default (normal): the hint is a D-Bus byte, which the bus wrapper does not carry.
public actor DBusNotificationSink: NotificationSink {
    private var connection: DBusConnection?
    private var failedToOpen = false

    public init(connection: DBusConnection? = nil) { self.connection = connection }

    public func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32? {
        if connection == nil {
            guard !failedToOpen else { throw NotificationUnavailable() }
            do { connection = try await DBusConnection.open() }
            catch { failedToOpen = true; throw error }
        }
        guard let connection else { throw NotificationUnavailable() }
        let reply = try await connection.call(
            destination: "org.freedesktop.Notifications", path: "/org/freedesktop/Notifications",
            interface: "org.freedesktop.Notifications", member: "Notify",
            arguments: [
                .string("Vizier"), .uint32(id ?? 0), .string("audio-input-microphone"),
                .string(notification.summary), .string(notification.body),
                .array("s", []), .dictionary([:]), .int32(notification.timeoutMs),
            ])
        return reply.first?.uint32
    }
}
#endif

/// `notify-send`, with `--print-id`/`--replace-id` where the installed version has them.
public struct NotifySendSink: NotificationSink {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32? {
        guard ProcessRunner.resolve("notify-send", environment: environment) != nil else { throw NotificationUnavailable() }
        let base = ["notify-send", "--app-name=Vizier", "--icon=audio-input-microphone", "--expire-time=\(max(notification.timeoutMs, 0))"]
        let text = [notification.summary, notification.body]
        var attempts = [base + ["--print-id"] + (id.map { ["--replace-id=\($0)"] } ?? []) + text]
        attempts.append(base + text)  // an older libnotify without the id options
        for argv in attempts {
            let result = try await ProcessRunner.run(argv, environment: environment, timeout: .seconds(3), outputLimit: 1024)
            if result.succeeded {
                return UInt32(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        throw NotificationUnavailable()
    }
}

/// Tries each sink in order until one shows the notification.
public struct FallbackNotificationSink: NotificationSink {
    private let sinks: [any NotificationSink]

    public init(_ sinks: [any NotificationSink]) { self.sinks = sinks }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> FallbackNotificationSink {
        #if os(Linux)
        FallbackNotificationSink([DBusNotificationSink(), NotifySendSink(environment: environment)])
        #else
        FallbackNotificationSink([NotifySendSink(environment: environment)])
        #endif
    }

    public func notify(_ notification: DesktopNotification, replacing id: UInt32?) async throws -> UInt32? {
        var last: (any Error)?
        for sink in sinks {
            do { return try await sink.notify(notification, replacing: id) } catch { last = error }
        }
        throw last ?? NotificationUnavailable()
    }
}

#if !canImport(os)
import Foundation

// A stand-in for `os.Logger` where Apple's `os` module does not exist (Linux). The call shape matches
// what the engine uses, and the privacy rule holds as it does under `os.Logger`: every interpolated
// value is replaced by `<private>` unless it is marked `.public`, or is a number or a Bool with the
// default `.auto` privacy. Lines go to stderr (the daemon's journal). The level floor comes from
// VIZIER_LOG_LEVEL (debug, info, notice, warning, error, fault; default notice).

public enum LogPrivacy: Sendable {
    case `public`, `private`, sensitive, auto
}

public enum LogFloatFormat: Sendable {
    case fixed(precision: Int)
}

public struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public var text: String

    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: Interpolation) { text = stringInterpolation.text }

    public struct Interpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) { text += literal }

        /// Any value. Under `.auto`, numbers and Bools are public and everything else is private.
        public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: LogPrivacy = .auto) {
            let value = value()
            switch privacy {
            case .public:
                text += String(describing: value)
            case .private, .sensitive:
                text += "<private>"
            case .auto:
                text += Self.isScalar(value) ? String(describing: value) : "<private>"
            }
        }

        public mutating func appendInterpolation(
            _ value: @autoclosure () -> Double, format: LogFloatFormat, privacy: LogPrivacy = .auto
        ) {
            guard case .fixed(let precision) = format else { return }
            let shown = String(format: "%.\(max(0, precision))f", value())
            switch privacy {
            case .public, .auto: text += shown
            case .private, .sensitive: text += "<private>"
            }
        }

        private static func isScalar<T>(_ value: T) -> Bool {
            value is any BinaryInteger || value is any BinaryFloatingPoint || value is Bool
        }
    }
}

public struct Logger: Sendable {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, notice, warning, error, fault

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .warning: "warning"
            case .error: "error"
            case .fault: "fault"
            }
        }

        static func parse(_ name: String?) -> Level {
            switch name?.lowercased() {
            case "debug": .debug
            case "info": .info
            case "warning", "warn": .warning
            case "error": .error
            case "fault": .fault
            default: .notice
            }
        }
    }

    /// The floor read from VIZIER_LOG_LEVEL once, when the process first logs.
    static let floorLevel: Level = Level.parse(ProcessInfo.processInfo.environment["VIZIER_LOG_LEVEL"])

    public let subsystem: String
    public let category: String
    let floor: Level
    let emit: @Sendable (String) -> Void

    public init(subsystem: String, category: String) {
        self.init(subsystem: subsystem, category: category, floor: Logger.floorLevel) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    init(subsystem: String, category: String, floor: Level, emit: @escaping @Sendable (String) -> Void) {
        self.subsystem = subsystem
        self.category = category
        self.floor = floor
        self.emit = emit
    }

    public func debug(_ message: LogMessage) { write(.debug, message) }
    public func info(_ message: LogMessage) { write(.info, message) }
    public func notice(_ message: LogMessage) { write(.notice, message) }
    public func warning(_ message: LogMessage) { write(.warning, message) }
    public func error(_ message: LogMessage) { write(.error, message) }
    public func fault(_ message: LogMessage) { write(.fault, message) }

    private func write(_ level: Level, _ message: LogMessage) {
        guard level >= floor else { return }
        emit("vizier[\(category)] \(level.label): \(message.text)")
    }
}
#endif

import Foundation

/// JSON values keep the wire schema explicit without passing non-Sendable `Any` across actors.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([String: JSONValue].self) { self = .object(x) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let x) = self { x[key] } else { nil } }
    public var string: String? { if case .string(let x) = self { x } else { nil } }
    public var number: Double? { if case .number(let x) = self { x } else { nil } }
    public var bool: Bool? { if case .bool(let x) = self { x } else { nil } }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(Self.self, from: Wire.encoder().encode(value))
    }
}

public struct Request: Codable, Sendable {
    public var v: Int
    public var id: Int
    public var cmd: String
    public var args: [String: JSONValue]
    public init(v: Int = 1, id: Int = 1, cmd: String, args: [String: JSONValue] = [:]) {
        self.v = v; self.id = id; self.cmd = cmd; self.args = args
    }
}

public struct CLIError: Error, Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var next: String
    public init(_ code: String, _ message: String, next: String) {
        self.code = code; self.message = message; self.next = next
    }
    public var exitCode: Int32 {
        switch code {
        case "usage", "unknown_command", "invalid_args", "bad_version", "invalid_request", "request_too_large": 2
        case "daemon_not_running": 3
        case "already_recording", "not_recording", "busy_finalizing", "startup_not_ready", "shutting_down", "already_running", "daemon_busy": 4
        default: 1
        }
    }
}

public struct Reply: Codable, Sendable, Equatable {
    public var v = 1
    public var id: Int
    public var ok: Bool
    public var result: JSONValue?
    public var error: CLIError?
    public init(id: Int, result: JSONValue) { self.id = id; ok = true; self.result = result }
    public init(id: Int, error: CLIError) { self.id = id; ok = false; self.error = error }
    public var exitCode: Int32 {
        if let error { return error.exitCode }
        if result?["healthy"]?.bool == false { return 5 }
        return 0
    }
}

public enum Wire {
    public static let requestLimit = 64 * 1024
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value); data.append(10); return data
    }
}

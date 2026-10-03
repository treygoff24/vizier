#if os(Linux)
import Foundation
import Glibc

/// The subset needed by desktop portals. File descriptors returned by calls are duplicated;
/// the recipient owns the duplicate and must close it.
public indirect enum DBusValue: Sendable, Equatable {
    case string(String), objectPath(String), uint32(UInt32), uint64(UInt64), int32(Int32), bool(Bool)
    case unixFD(Int32), variant(DBusValue), dictionary([String: DBusValue])
    case array(String, [DBusValue]), structure([DBusValue]), unsupported(String)

    var signature: String {
        switch self {
        case .unsupported(let signature): signature
        case .string: "s"
        case .objectPath: "o"
        case .uint32: "u"
        case .uint64: "t"
        case .int32: "i"
        case .bool: "b"
        case .unixFD: "h"
        case .variant: "v"
        case .dictionary: "a{sv}"
        case .array(let signature, _): "a" + signature
        case .structure(let values): "(" + values.map(\.signature).joined() + ")"
        }
    }
    public var string: String? {
        switch self { case .string(let s), .objectPath(let s): s; case .variant(let v): v.string; default: nil }
    }
    public var uint32: UInt32? {
        switch self { case .uint32(let n): n; case .variant(let v): v.uint32; default: nil }
    }
    public var bool: Bool? {
        switch self { case .bool(let b): b; case .variant(let v): v.bool; default: nil }
    }
    public var dictionary: [String: DBusValue]? {
        switch self { case .dictionary(let d): d; case .variant(let v): v.dictionary; default: nil }
    }
}

public enum DBusFailure: Error, Sendable, CustomStringConvertible {
    case libraryUnavailable, symbolUnavailable(String), operation(Int32), method(Int32, String?), malformed, disconnected
    var unsupportedMethod: Bool {
        guard case .method(_, let name) = self else { return false }
        return name == "org.freedesktop.DBus.Error.UnknownMethod" || name == "org.freedesktop.DBus.Error.NotSupported"
    }
    public var description: String {
        switch self {
        case .libraryUnavailable: "libsystemd.so.0 is unavailable"
        case .symbolUnavailable(let name): "libsystemd is missing \(name)"
        case .method(let code, _): "D-Bus method failed (errno \(-code))"
        case .operation(let code): "D-Bus operation failed (errno \(-code))"
        case .malformed: "Unexpected D-Bus message"
        case .disconnected: "Session bus disconnected"
        }
    }
}

private typealias BusPointer = UnsafeMutableRawPointer
private typealias SignalCallback = @convention(c) (BusPointer?, BusPointer?, BusPointer?) -> Int32

/// All function pointers are non-variadic. The library stays loaded until every bus is released.
private final class SDBus: @unchecked Sendable {
    let library: BusPointer
    let openUser: @convention(c) (UnsafeMutablePointer<BusPointer?>?) -> Int32
    let newCall: @convention(c) (BusPointer?, UnsafeMutablePointer<BusPointer?>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let append: @convention(c) (BusPointer?, CChar, UnsafeRawPointer?) -> Int32
    let openContainer: @convention(c) (BusPointer?, CChar, UnsafePointer<CChar>?) -> Int32
    let closeContainer: @convention(c) (BusPointer?) -> Int32
    let call: @convention(c) (BusPointer?, BusPointer?, UInt64, BusPointer?, UnsafeMutablePointer<BusPointer?>?) -> Int32
    let read: @convention(c) (BusPointer?, CChar, BusPointer?) -> Int32
    let enter: @convention(c) (BusPointer?, CChar, UnsafePointer<CChar>?) -> Int32
    let exitContainer: @convention(c) (BusPointer?) -> Int32
    let peek: @convention(c) (BusPointer?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let skip: @convention(c) (BusPointer?, UnsafePointer<CChar>?) -> Int32
    let addMatch: @convention(c) (BusPointer?, UnsafeMutablePointer<BusPointer?>?, UnsafePointer<CChar>?, SignalCallback?, BusPointer?) -> Int32
    let process: @convention(c) (BusPointer?, UnsafeMutablePointer<BusPointer?>?) -> Int32
    let getFD: @convention(c) (BusPointer?) -> Int32
    let getEvents: @convention(c) (BusPointer?) -> Int32
    let getTimeout: @convention(c) (BusPointer?, UnsafeMutablePointer<UInt64>?) -> Int32
    let getSender: @convention(c) (BusPointer?) -> UnsafePointer<CChar>?
    let slotUnref: @convention(c) (BusPointer?) -> BusPointer?
    let flushCloseUnref: @convention(c) (BusPointer?) -> BusPointer?
    let errorFree: @convention(c) (BusPointer?) -> Void
    let uniqueName: @convention(c) (BusPointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let messageUnref: @convention(c) (BusPointer?) -> BusPointer?

    init() throws {
        guard let handle = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL) else { throw DBusFailure.libraryUnavailable }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else { throw DBusFailure.symbolUnavailable(name) }
            return unsafeBitCast(p, to: T.self)
        }
        do {
            openUser = try symbol("sd_bus_open_user", type(of: openUser))
            newCall = try symbol("sd_bus_message_new_method_call", type(of: newCall))
            append = try symbol("sd_bus_message_append_basic", type(of: append))
            openContainer = try symbol("sd_bus_message_open_container", type(of: openContainer))
            closeContainer = try symbol("sd_bus_message_close_container", type(of: closeContainer))
            call = try symbol("sd_bus_call", type(of: call))
            read = try symbol("sd_bus_message_read_basic", type(of: read))
            enter = try symbol("sd_bus_message_enter_container", type(of: enter))
            exitContainer = try symbol("sd_bus_message_exit_container", type(of: exitContainer))
            peek = try symbol("sd_bus_message_peek_type", type(of: peek))
            skip = try symbol("sd_bus_message_skip", type(of: skip))
            addMatch = try symbol("sd_bus_add_match", type(of: addMatch))
            process = try symbol("sd_bus_process", type(of: process))
            getFD = try symbol("sd_bus_get_fd", type(of: getFD))
            getEvents = try symbol("sd_bus_get_events", type(of: getEvents))
            getTimeout = try symbol("sd_bus_get_timeout", type(of: getTimeout))
            getSender = try symbol("sd_bus_message_get_sender", type(of: getSender))
            slotUnref = try symbol("sd_bus_slot_unref", type(of: slotUnref))
            flushCloseUnref = try symbol("sd_bus_flush_close_unref", type(of: flushCloseUnref))
            errorFree = try symbol("sd_bus_error_free", type(of: errorFree))
            uniqueName = try symbol("sd_bus_get_unique_name", type(of: uniqueName))
            messageUnref = try symbol("sd_bus_message_unref", type(of: messageUnref))
            library = handle
        } catch { dlclose(handle); throw error }
    }
    deinit { dlclose(library) }
    func check(_ result: Int32) throws { if result < 0 { throw DBusFailure.operation(result) } }
    func container(_ message: BusPointer, _ type: CChar, _ signature: String, body: () throws -> Void) throws {
        try check(openContainer(message, type, signature))
        try body()
        try check(closeContainer(message))
    }
    func encode(_ value: DBusValue, into message: BusPointer) throws {
        func basic<T>(_ type: CChar, _ value: T) throws {
            var value = value
            try withUnsafePointer(to: &value) { try check(append(message, type, $0)) }
        }
        switch value {
        case .unsupported: throw DBusFailure.malformed
        case .string(let s), .objectPath(let s):
            guard !s.utf8.contains(0) else { throw DBusFailure.malformed }
            try s.withCString { try check(append(message, value.signature == "s" ? 115 : 111, $0)) }
        case .uint32(let n): try basic(117, n)
        case .uint64(let n): try basic(116, n)
        case .int32(let n): try basic(105, n)
        case .bool(let b): try basic(98, Int32(b ? 1 : 0))
        case .unixFD(let fd): try basic(104, fd)
        case .variant(let v): try container(message, 118, v.signature) { try encode(v, into: message) }
        case .dictionary(let d):
            try container(message, 97, "{sv}") {
                for key in d.keys.sorted() {
                    try container(message, 101, "sv") {
                        try encode(.string(key), into: message)
                        try encode(.variant(d[key]!), into: message)
                    }
                }
            }
        case .array(let signature, let values):
            try container(message, 97, signature) {
                for v in values {
                    // An array of `{..}` takes dict entries: a pair is encoded as one, not as a struct.
                    if signature.hasPrefix("{"), case .structure(let pair) = v {
                        try container(message, 101, pair.map(\.signature).joined()) { for item in pair { try encode(item, into: message) } }
                    } else { try encode(v, into: message) }
                }
            }
        case .structure(let values):
            try container(message, 114, values.map(\.signature).joined()) { for v in values { try encode(v, into: message) } }
        }
    }
    func decodeAll(_ message: BusPointer) throws -> [DBusValue] {
        var values: [DBusValue] = []
        while let value = try decode(message) { values.append(value) }
        return values
    }
    func decode(_ message: BusPointer) throws -> DBusValue? {
        var type: CChar = 0
        var contents: UnsafePointer<CChar>?
        let result = peek(message, &type, &contents)
        try check(result)
        if result == 0 { return nil }
        func basic<T>(_ type: CChar, _ initial: T) throws -> T {
            var value = initial
            try withUnsafeMutablePointer(to: &value) { try check(read(message, type, $0)) }
            return value
        }
        switch type {
        case 115, 111:
            let p: UnsafePointer<CChar>? = try basic(type, Optional<UnsafePointer<CChar>>.none)
            guard let p else { throw DBusFailure.malformed }
            return type == 115 ? .string(String(cString: p)) : .objectPath(String(cString: p))
        case 117: return .uint32(try basic(type, UInt32(0)))
        case 116: return .uint64(try basic(type, UInt64(0)))
        case 105: return .int32(try basic(type, Int32(0)))
        case 98: return .bool(try basic(type, Int32(0)) != 0)
        case 104:
            let fd = fcntl(try basic(type, Int32(-1)), F_DUPFD_CLOEXEC, 3)
            guard fd >= 0 else { throw DBusFailure.operation(-errno) }
            return .unixFD(fd)
        case 97, 118, 114, 101:
            let signature = contents.map { String(cString: $0) } ?? ""
            try check(enter(message, type, signature))
            let values = try decodeAll(message)
            try check(exitContainer(message))
            if type == 118 {
                guard values.count == 1 else { throw DBusFailure.malformed }
                return .variant(values[0])
            }
            if type == 97 && signature == "{sv}" {
                var d: [String: DBusValue] = [:]
                for entry in values {
                    guard case .structure(let pair) = entry, pair.count == 2, let key = pair[0].string else { throw DBusFailure.malformed }
                    if case .variant(let v) = pair[1] { d[key] = v } else { throw DBusFailure.malformed }
                }
                return .dictionary(d)
            }
            return type == 97 ? .array(signature, values) : .structure(values)
        default:
            // Skip extensions we don't interpret rather than corrupt the remaining cursor.
            try check(skip(message, String(UnicodeScalar(UInt8(bitPattern: type)))))
            return .unsupported(String(UnicodeScalar(UInt8(bitPattern: type))))
        }
    }
}

private final class SignalBox: @unchecked Sendable {
    let library: SDBus
    let sender: String
    let continuation: AsyncThrowingStream<[DBusValue], Error>.Continuation
    var slot: BusPointer? // touched exclusively on the connection queue
    init(_ library: SDBus, sender: String, _ continuation: AsyncThrowingStream<[DBusValue], Error>.Continuation) {
        self.library = library; self.sender = sender; self.continuation = continuation
    }
}

private let signalCallback: SignalCallback = { message, userdata, _ in
    guard let message, let userdata else { return 0 }
    let box = Unmanaged<SignalBox>.fromOpaque(userdata).takeUnretainedValue()
    // Directed signals bypass the daemon's match rules. Authenticate locally as well.
    guard let sender = box.library.getSender(message), String(cString: sender) == box.sender else { return 0 }
    do { box.continuation.yield(try box.library.decodeAll(message)) }
    catch { return 0 } // One malformed extension cannot destroy a live subscription.
    return 0
}

public struct DBusSignals: Sendable {
    public let stream: AsyncThrowingStream<[DBusValue], Error>
    private let cancelMatch: @Sendable () -> Void
    fileprivate init(_ stream: AsyncThrowingStream<[DBusValue], Error>, cancel: @escaping @Sendable () -> Void) {
        self.stream = stream; cancelMatch = cancel
    }
    public func cancel() { cancelMatch() }
}

/// All native operations and readiness callbacks run on one serial utility queue.
public final class DBusConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.praxient.vizier.dbus")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let library: SDBus
    private let bus: BusPointer
    public let uniqueName: String
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var signals: [UUID: SignalBox] = [:]
    private var failed = false

    private init() throws {
        library = try SDBus()
        var pointer: BusPointer?
        try library.check(library.openUser(&pointer))
        guard let pointer else { throw DBusFailure.disconnected }
        bus = pointer
        var name: UnsafePointer<CChar>?
        do {
            try library.check(library.uniqueName(bus, &name))
            guard let name else { throw DBusFailure.disconnected }
            uniqueName = String(cString: name)
        } catch { _ = library.flushCloseUnref(bus); throw error }
        queue.setSpecific(key: queueKey, value: true)
        queue.async { [weak self] in self?.pump() }
    }
    public static func open() async throws -> DBusConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try DBusConnection()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    deinit {
        reader?.cancel(); writer?.cancel(); timer?.cancel()
        let boxes = Array(signals.values)
        let api = library
        let pointer = bus
        let release = {
            for box in boxes { box.continuation.finish(); box.slot = api.slotUnref(box.slot) }
            _ = api.flushCloseUnref(pointer)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { release() } else { queue.sync(execute: release) }
    }
    private func fail() {
        failed = true
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        timer?.cancel(); timer = nil
        for box in signals.values { box.continuation.finish(throwing: DBusFailure.disconnected) }
    }
    private func arm() {
        guard !failed else { return }
        let fd = library.getFD(bus)
        let events = library.getEvents(bus)
        var timeout = UInt64.max
        guard fd >= 0, events >= 0, library.getTimeout(bus, &timeout) >= 0 else { fail(); return }
        if events & POLLIN != 0 {
            if reader == nil {
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.pump() }
                reader = source; source.resume()
            }
        } else { reader?.cancel(); reader = nil }
        if events & POLLOUT != 0 {
            if writer == nil {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.pump() }
                writer = source; source.resume()
            }
        } else { writer?.cancel(); writer = nil }
        timer?.cancel(); timer = nil
        if timeout != UInt64.max {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: DispatchTime(uptimeNanoseconds: timeout * 1000), repeating: .never)
            source.setEventHandler { [weak self] in self?.pump() }
            timer = source; source.resume()
        }
    }
    private func pump() {
        guard !failed else { return }
        for _ in 0..<64 {
            let result = library.process(bus, nil)
            if result < 0 { fail(); return }
            if result == 0 { arm(); return }
        }
        // Drain already buffered messages without a permanent polling timer.
        queue.async { [weak self] in self?.pump() }
    }
    public func call(destination: String = "org.freedesktop.portal.Desktop", path: String = "/org/freedesktop/portal/desktop", interface: String, member: String, arguments: [DBusValue] = []) async throws -> [DBusValue] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { pump() }
                do {
                    guard !failed else { throw DBusFailure.disconnected }
                    var message: BusPointer?
                    try library.check(library.newCall(bus, &message, destination, path, interface, member))
                    guard let message else { throw DBusFailure.malformed }
                    defer { _ = library.messageUnref(message) }
                    for value in arguments { try library.encode(value, into: message) }
                    var reply: BusPointer?
                    defer { _ = library.messageUnref(reply) }
                    // Do not expose service-provided error text. Recognized names permit safe fallback.
                    let error = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
                    error.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
                    defer { error.deallocate() }
                    let result = library.call(bus, message, 5_000_000, error, &reply)
                    // sd_bus_error contains two pointers followed by an int (24 bytes on 64-bit Linux).
                    let errorName = error.load(as: UnsafePointer<CChar>?.self).map { String(cString: $0) }
                    // The error may own both strings. Free it with its optional native symbol.
                    library.errorFree(error)
                    if result < 0 { throw DBusFailure.method(result, errorName) }
                    guard let reply else { throw DBusFailure.malformed }
                    continuation.resume(returning: try library.decodeAll(reply))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func nameOwner(_ name: String) async throws -> String {
        if name == "org.freedesktop.DBus" || name.hasPrefix(":") { return name }
        let reply = try await call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus", interface: "org.freedesktop.DBus", member: "GetNameOwner", arguments: [.string(name)])
        guard let owner = reply.first?.string, owner.hasPrefix(":") else { throw DBusFailure.malformed }
        return owner
    }
    public func match(sender: String = "org.freedesktop.portal.Desktop", path: String? = nil, interface: String, member: String, argument0: String? = nil) async throws -> DBusSignals {
        let sender = try await nameOwner(sender)
        let parts = [sender, interface, member] + [path, argument0].compactMap { $0 }
        guard parts.allSatisfy({ !$0.contains("'") && !$0.contains("\\") && !$0.utf8.contains(0) }) else { throw DBusFailure.malformed }
        var rule = "type='signal',sender='\(sender)',interface='\(interface)',member='\(member)'"
        if let path { rule += ",path='\(path)'" }
        if let argument0 { rule += ",arg0='\(argument0)'" }
        let matchRule = rule
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                defer { pump() }
                let (stream, sink) = AsyncThrowingStream<[DBusValue], Error>.makeStream()
                let box = SignalBox(library, sender: sender, sink)
                let id = UUID()
                do {
                    try library.check(library.addMatch(bus, &box.slot, matchRule, signalCallback, Unmanaged.passUnretained(box).toOpaque()))
                    signals[id] = box
                    let cancel: @Sendable () -> Void = { [weak self] in
                        sink.finish()
                        self?.queue.async { [weak self] in self?.removeMatch(id) }
                    }
                    sink.onTermination = { [weak self] _ in
                        self?.queue.async { [weak self] in self?.removeMatch(id) }
                    }
                    continuation.resume(returning: DBusSignals(stream, cancel: cancel))
                } catch { _ = library.slotUnref(box.slot); sink.finish(); continuation.resume(throwing: error) }
            }
        }
    }
    private func removeMatch(_ id: UUID) {
        guard let box = signals.removeValue(forKey: id) else { return }
        box.slot = library.slotUnref(box.slot)
        pump()
    }
}
#endif

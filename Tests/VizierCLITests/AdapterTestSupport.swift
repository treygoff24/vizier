import Foundation
import Glibc
@testable import VizierCLI

/// Runs `body` on a thread of its own and waits for it without holding a cooperative thread.
///
/// For calls that block their thread until async work finishes on the cooperative pool: a Secret
/// Service lookup does (`Blocking.run` parks the caller on a semaphore while a detached task asks
/// the bus). The CLI makes those calls from the main thread and the daemon from its refresh
/// queue. A sync test makes them from a pool thread, and with enough such tests running at once
/// every pool thread is parked waiting for a task that needs one. On a 4-vCPU CI runner the
/// whole VizierCLITests run then stopped, every test started and none finished.
func offThePool<T: Sendable>(_ body: @escaping () throws -> T) async throws -> T {
    let work = OffThePoolBody(body)
    return try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try work.run() }) }
        thread.name = "vizier-tests.off-the-pool"
        thread.start()
    }
}

/// The body `offThePool` hands to its thread. The caller stays suspended until the thread has
/// finished with it, so the body never runs concurrently with the code that made it.
private final class OffThePoolBody<T>: @unchecked Sendable {
    let run: () throws -> T
    init(_ run: @escaping () throws -> T) { self.run = run }
}

/// A temp directory of fake helper executables. Each fake appends its argv (one line per
/// argument, then a `--` line) to `<name>.argv` and its stdin to `<name>.stdin`, writes
/// `$YDOTOOL_SOCKET` to `<name>.sock`, then runs `body`.
final class FakeBins {
    let directory: String

    init() {
        // A unix socket path holds about 100 bytes, and fixtures bind sockets in here: a long
        // $TMPDIR (macOS-style or a nested sandbox) falls back to a short root under /tmp.
        let preferred = NSTemporaryDirectory() + "vizier-fakebins-\(UUID().uuidString)"
        directory = preferred.utf8.count + "/vizier-input/socket".utf8.count < SocketFixture.pathLimit
            ? preferred : "/tmp/vzfb-\(UUID().uuidString.prefix(8))"
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // The fakes' own tools, so PATH can be this directory alone: a real xclip or wtype on the
        // machine running the tests must never be found in place of an absent fake.
        for tool in ["cat", "sleep"] { try! FileManager.default.createSymbolicLink(atPath: "\(directory)/\(tool)", withDestinationPath: "/usr/bin/\(tool)") }
    }

    deinit { try? FileManager.default.removeItem(atPath: directory) }

    func add(_ name: String, body: String = "exit 0", reads: Bool = true) {
        let stdin = reads ? "cat >> '\(directory)/\(name).stdin'" : ""
        let script = """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\n' "$a"; done; echo --; } >> '\(directory)/\(name).argv'
        printf '%s' "$YDOTOOL_SOCKET" > '\(directory)/\(name).sock'
        \(stdin)
        \(body)
        """
        let path = "\(directory)/\(name)"
        // Close-on-exec, so a helper spawned by a concurrent test never inherits this write
        // descriptor (that makes exec of the new file fail with ETXTBSY).
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o755)
        precondition(descriptor >= 0)
        let bytes = Array(script.utf8)
        precondition(write(descriptor, bytes, bytes.count) == bytes.count)
        close(descriptor)
    }

    /// Where the fake clipboard keeps the selection; a test replaces it by writing here.
    var clipboardFile: String { "\(directory)/clip.store" }
    var clipboard: String? { try? String(contentsOfFile: clipboardFile, encoding: .utf8) }
    func setClipboard(_ text: String) { try! text.write(toFile: clipboardFile, atomically: true, encoding: .utf8) }

    /// A fake xclip or xsel: with `-o`/`--output` it prints the fake clipboard, otherwise it takes the
    /// text on stdin (kept in `<name>.stdin`) and, like the real ones, "forks a server" and exits 0.
    /// `delay`: seconds until the selection is actually taken. `acquires: false`: it never is.
    /// `hangs`: it stays running in the foreground instead (its pid goes to `<name>.pid`).
    func addClipboardTool(_ name: String, delay: Double = 0, acquires: Bool = true, hangs: Bool = false, failsWith: Int32? = nil) {
        let take = acquires
            ? (delay > 0 ? "( sleep \(delay); cat '\(directory)/\(name).in' > '\(clipboardFile)' ) &" : "cat '\(directory)/\(name).in' > '\(clipboardFile)'")
            : ":"
        let ending = hangs ? "echo $$ > '\(directory)/\(name).pid'; exec sleep 30" : "exit 0"
        let failure = failsWith.map { "echo failing >&2; exit \($0)" } ?? ":"
        installScript(name, """
        case "$*" in
        *" -o"|*--output*) cat '\(clipboardFile)' 2>/dev/null || exit 1; exit 0;;
        esac
        \(failure)
        cat > '\(directory)/\(name).in'
        cat '\(directory)/\(name).in' >> '\(directory)/\(name).stdin'
        \(take)
        \(ending)
        """)
    }

    /// A fake wl-paste: prints the fake clipboard.
    func addClipboardReader(_ name: String = "wl-paste") {
        installScript(name, "cat '\(clipboardFile)' 2>/dev/null || exit 1")
    }

    /// Installs `body` as an executable that first logs its argv like `add` does.
    func installScript(_ name: String, _ body: String) {
        let script = """
        #!/bin/sh
        { for a in "$@"; do printf '%s\\n' "$a"; done; echo --; } >> '\(directory)/\(name).argv'
        \(body)
        """
        let descriptor = open("\(directory)/\(name)", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o755)
        precondition(descriptor >= 0)
        let bytes = Array(script.utf8)
        precondition(write(descriptor, bytes, bytes.count) == bytes.count)
        close(descriptor)
    }

    func argv(_ name: String) -> [[String]] {
        guard let text = try? String(contentsOfFile: "\(directory)/\(name).argv", encoding: .utf8) else { return [] }
        var calls: [[String]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line == "--" { calls.append([]) } else { calls[calls.count - 1].append(String(line)) }
        }
        calls.removeLast()
        return calls
    }

    func stdin(_ name: String) -> String? { try? String(contentsOfFile: "\(directory)/\(name).stdin", encoding: .utf8) }
    func socketSeen(_ name: String) -> String? { try? String(contentsOfFile: "\(directory)/\(name).sock", encoding: .utf8) }

    /// The environment the adapters run helpers in: only the fakes plus the base tools.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        ["PATH": directory].merging(extra) { $1 }
    }

    func env(_ extra: [String: String] = [:], distro: DistroFamily = .debian) -> HelperEnvironment {
        HelperEnvironment(variables: environment(extra), distro: distro)
    }
}

/// An environment where none of the real helpers resolve.
func emptyEnv(_ extra: [String: String] = [:], distro: DistroFamily = .debian) -> HelperEnvironment {
    let dir = NSTemporaryDirectory() + "vizier-emptybin"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return HelperEnvironment(variables: ["PATH": dir].merging(extra) { $1 }, distro: distro)
}

/// A listening or merely bound unix socket in a temp directory, for the ydotool socket checks.
final class SocketFixture {
    /// `sun_path` is a fixed array; a path must fit with its terminating NUL.
    static let pathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    let path: String
    private var descriptor: Int32

    /// `stream`: a listening stream socket; otherwise a bound datagram socket (what ydotoold uses).
    init(in directory: String, name: String = ".ydotool_socket", stream: Bool = false) {
        path = "\(directory)/\(name)"
        precondition(path.utf8.count < Self.pathLimit, "socket path is \(path.utf8.count) bytes; sun_path holds \(Self.pathLimit - 1): \(path)")
        descriptor = socket(AF_UNIX, stream ? Int32(SOCK_STREAM.rawValue) : Int32(SOCK_DGRAM.rawValue), 0)
        precondition(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(bound == 0)
        if stream { precondition(listen(descriptor, 4) == 0) }
    }

    deinit { close(descriptor) }
}

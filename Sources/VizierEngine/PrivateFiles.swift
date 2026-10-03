import Darwin
import Foundation

/// Vizier's data and settings folders hold dictations, audio, vocabulary, and replacements, so they
/// are made 0700 and their files 0600. A folder or file an older build made with the default
/// 0755 or 0644 loses its group and other access when Vizier opens it; the owner's own bits stay
/// as they are, and nothing owned by another user is touched.
public enum PrivateFiles {
    public static let directoryMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600

    /// Creates `url` and any missing parents as 0700, and tightens `url` when it already existed.
    public static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: directoryMode)])
        tighten(url)
    }

    /// Creates an empty 0600 file at `url` unless something is already there.
    public static func createFileIfMissing(_ url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        if descriptor >= 0 { close(descriptor) }
    }

    /// Sets a file this build just wrote to 0600.
    public static func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: fileMode)], ofItemAtPath: url.path)
    }

    /// Takes group and other access off an existing file or folder this user owns. Best effort: a
    /// failure leaves the item as an earlier build left it, which still works.
    public static func tighten(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_uid == getuid() else { return }
        let mode = info.st_mode & 0o7777
        if mode & 0o077 != 0 { _ = chmod(url.path, mode & ~0o077) }
    }
}

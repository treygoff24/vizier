import Darwin
import Foundation
import VizierEngine

/// Decides whether a folder named on the command line (`--render-ui`, `--preview-surfaces`) would
/// touch real Vizier data. Symlinks are resolved first. The settings and data folders are refused
/// along with everything inside them, compared by path component so `Vizier-copy` is not mistaken
/// for `Vizier`; the home folder itself is refused, but a folder inside it is fine.
enum RealDataGuard {
    static func refuses(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let resolved = folder.resolvingSymlinksInPath().pathComponents
        let home = home.resolvingSymlinksInPath()
        // The new folders and the Dictum-era ones, which hold the data until the migration moves them.
        let inside = UserDataMigration.folders.flatMap { [home.appending(path: $0.new), home.appending(path: $0.old)] }
        if resolved == home.pathComponents { return true }
        return inside.contains { root in
            let rootComponents = root.resolvingSymlinksInPath().pathComponents
            return resolved.count >= rootComponents.count && Array(resolved.prefix(rootComponents.count)) == rootComponents
        }
    }

    /// The first of `children` (paths relative to `folder`, such as `history.sqlite` or
    /// `config/vizier.jsonc`) that a command must not write, or nil when every one is safe. A
    /// safe folder can still hold a child that leads into real data, so each child, and each
    /// folder between `folder` and it, is refused when it is a symlink, a file with a second hard
    /// link, anything but a plain file or folder, or a path inside real data. A child that is an
    /// existing folder is checked all the way down, since the commands write below it. A child
    /// that does not exist yet is fine: the command creates it. The check runs before the writes,
    /// so it does not stop a link made in between; it is a guard against mistakes and leftovers.
    static func refusedChild(in folder: URL, writing children: [String],
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let base = folder.resolvingSymlinksInPath()
        for child in children {
            var url = base
            for component in child.split(separator: "/") {
                url = url.appending(path: String(component))
                if unsafe(url, home: home) { return child }
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            // The enumerator lists a symlink without following it, as a path relative to `url`.
            let below = FileManager.default.enumerator(atPath: url.path)
            while let item = below?.nextObject() as? String {
                if unsafe(url.appending(path: item), home: home) { return child + "/" + item }
            }
        }
        return nil
    }

    private static func unsafe(_ url: URL, home: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno != ENOENT }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFREG: if info.st_nlink > 1 { return true }
        default: return true
        }
        return refuses(url, home: home)
    }
}

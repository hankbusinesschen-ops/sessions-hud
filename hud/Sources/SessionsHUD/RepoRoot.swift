import Foundation

/// Walk up from a cwd to the nearest directory containing `.git` (file or
/// directory, so worktrees and submodules both resolve). Shared between the
/// compact-list grouping logic and the "recent project roots" list used by
/// the launcher popover.
enum RepoRoot {
    /// Returns the short label (basename) used for grouping. Falls back to
    /// `~` when cwd is nil/empty, or to the cwd's own basename if no git
    /// ancestor exists.
    static func label(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        if let path = absolutePath(for: cwd) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Returns the absolute path of the nearest ancestor directory that
    /// contains a `.git` entry, or nil if none is found before hitting `/`.
    static func absolutePath(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git").path
            if fm.fileExists(atPath: git) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

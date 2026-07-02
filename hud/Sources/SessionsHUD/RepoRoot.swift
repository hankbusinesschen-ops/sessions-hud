import Foundation

/// Walk up from a cwd to the nearest directory containing `.git` (file or
/// directory, so worktrees and submodules both resolve). Used by the
/// compact-list grouping logic. Results are memoized — a cwd's repo root
/// essentially never changes within an app run, and grouping is recomputed
/// on every list render.
enum RepoRoot {
    private static let cacheLock = NSLock()
    private static var labelCache: [String: String] = [:]

    /// Returns the short label (basename) used for grouping. Falls back to
    /// `~` when cwd is nil/empty, or to the cwd's own basename if no git
    /// ancestor exists.
    static func label(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        cacheLock.lock()
        let cached = labelCache[cwd]
        cacheLock.unlock()
        if let cached { return cached }
        let path = absolutePath(for: cwd) ?? cwd
        let label = URL(fileURLWithPath: path).lastPathComponent
        cacheLock.lock()
        labelCache[cwd] = label
        cacheLock.unlock()
        return label
    }

    /// Returns the absolute path of the nearest ancestor directory that
    /// contains a `.git` entry, or nil if none is found before hitting `/`.
    private static func absolutePath(for cwd: String) -> String? {
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

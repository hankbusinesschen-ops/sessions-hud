import Foundation

/// Process-liveness checks used by the session sweep.
enum Liveness {
    /// One `ps` invocation for the whole registry: returns the subset of
    /// `pids` that exist AND still look like a claude-ish process. The comm
    /// check guards against PID reuse — a recycled PID belonging to some
    /// unrelated process must not keep a dead session on the list.
    static func aliveClaudePids<C: Collection>(_ pids: C) -> Set<Int32> where C.Element == Int32 {
        guard !pids.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "pid=,comm=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return Set(pids) // can't check — keep everything rather than mass-drop
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return Set(pids) }

        var alive: Set<Int32> = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let base = (String(parts[1]).trimmingCharacters(in: .whitespaces) as NSString)
                .lastPathComponent.lowercased()
            if base.contains("claude") || base.contains("node") || base.contains("bun") {
                alive.insert(pid)
            }
        }
        return alive
    }
}

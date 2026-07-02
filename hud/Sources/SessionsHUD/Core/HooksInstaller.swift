import Foundation

/// Installs / removes the Claude Code integration: the hook script copy,
/// the settings.json hook entries, and the statusline quota tee. Shared by
/// `install.sh` (via the `--install-hooks` CLI flag) and the in-app
/// onboarding button, so there is exactly one implementation.
enum HooksInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd",
        "PreToolUse", "PostToolUse",
        "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact",
    ]

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionsHUD", isDirectory: true)
    }
    static var scriptDest: URL { supportDir.appendingPathComponent("post-event.sh") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
    static var statuslineURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/statusline-command.sh")
    }

    private static let teeBegin = "# --- begin sessions-hud tee ---"
    private static let teeEnd = "# --- end sessions-hud tee ---"

    // MARK: - Install

    /// Returns human-readable log lines. Throws only on unrecoverable errors
    /// (unreadable settings.json etc.).
    @discardableResult
    static func install() throws -> [String] {
        var log: [String] = []
        try copyHookScript(&log)
        try mergeSettings(&log)
        patchStatusline(&log)
        return log
    }

    @discardableResult
    static func uninstall() throws -> [String] {
        var log: [String] = []
        try removeSettingsEntries(&log)
        removeTee(&log)
        try? FileManager.default.removeItem(at: scriptDest)
        log.append("hook script: removed \(scriptDest.path)")
        return log
    }

    // MARK: - Hook script copy

    /// The bundled script ships in Contents/Resources; dev builds can point
    /// SESSIONSHUD_HOOK_SRC at the repo copy.
    static func bundledScript() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SESSIONSHUD_HOOK_SRC"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "post-event", withExtension: "sh")
    }

    private static func copyHookScript(_ log: inout [String]) throws {
        guard let src = bundledScript() else {
            throw InstallError("找不到 post-event.sh（bundle Resources 或 SESSIONSHUD_HOOK_SRC）")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: scriptDest.path) {
            try fm.removeItem(at: scriptDest)
        }
        try fm.copyItem(at: src, to: scriptDest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptDest.path)
        log.append("hook script: \(scriptDest.path)")
    }

    // MARK: - settings.json

    /// Idempotent merge: every event gets exactly one post-event.sh command
    /// pointing at `scriptDest`; stale entries (old repo paths, duplicates)
    /// are replaced. Unrelated hooks are preserved untouched.
    private static func mergeSettings(_ log: inout [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original: Data
        if fm.fileExists(atPath: settingsURL.path) {
            original = try Data(contentsOf: settingsURL)
        } else {
            original = Data("{}".utf8)
        }
        guard var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw InstallError("~/.claude/settings.json 不是有效的 JSON object，拒絕合併")
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for (ev, value) in hooks {
            hooks[ev] = stripOurCommands(from: value)
        }
        // POSIX single-quote escaping so a quote in the home path (O'Brien)
        // can't produce a syntactically broken hook command.
        let dest = scriptDest.path.replacingOccurrences(of: "'", with: "'\\''")
        for ev in events {
            var blocks = hooks[ev] as? [[String: Any]] ?? []
            blocks.append(["hooks": [["type": "command", "command": "'\(dest)' \(ev)"]]])
            hooks[ev] = blocks
        }
        json["hooks"] = hooks

        let updated = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if bothParseEqual(original, updated) {
            log.append("settings.json: 已是最新，未變更")
            return
        }
        log.append(backUpSettings(fm))
        try updated.write(to: settingsURL, options: .atomic)
        log.append("settings.json: 已更新")
    }

    /// Fixed-name backup (last-known-good) so ~/.claude doesn't accumulate
    /// timestamped copies. Returns the log line describing what happened.
    private static func backUpSettings(_ fm: FileManager) -> String {
        guard fm.fileExists(atPath: settingsURL.path) else {
            return "settings.json: 原檔不存在，跳過備份"
        }
        let backup = settingsURL.appendingPathExtension("sessionshud.bak")
        do {
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: backup)
            }
            try fm.copyItem(at: settingsURL, to: backup)
            return "settings.json: 備份於 \(backup.lastPathComponent)"
        } catch {
            return "settings.json: 備份失敗（\(error.localizedDescription)）"
        }
    }

    private static func removeSettingsEntries(_ log: inout [String]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any]
        else { return }
        for (ev, value) in hooks {
            hooks[ev] = stripOurCommands(from: value)
            if let arr = hooks[ev] as? [[String: Any]], arr.isEmpty {
                hooks.removeValue(forKey: ev)
            }
        }
        json["hooks"] = hooks
        let updated = try JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if bothParseEqual(data, updated) {
            log.append("settings.json: 沒有需要移除的 hooks")
            return
        }
        log.append(backUpSettings(fm))
        try updated.write(to: settingsURL, options: .atomic)
        log.append("settings.json: post-event.sh hooks 已移除")
    }

    /// True only for OUR hook commands: the new home under SessionsHUD/ or
    /// the legacy repo layout `…/hooks/post-event.sh`. A user's unrelated
    /// script that happens to be named post-event.sh must never match.
    static func isOurCommand(_ command: String) -> Bool {
        command.contains("SessionsHUD/post-event.sh")
            || command.contains("hooks/post-event.sh")
    }

    /// Drops every hook command referencing our post-event.sh from one
    /// event's block array; empty blocks are dropped too.
    private static func stripOurCommands(from value: Any) -> Any {
        guard let blocks = value as? [[String: Any]] else { return value }
        var out: [[String: Any]] = []
        for var block in blocks {
            guard let inner = block["hooks"] as? [[String: Any]] else {
                out.append(block)
                continue
            }
            let kept = inner.filter { hook in
                !isOurCommand((hook["command"] as? String) ?? "")
            }
            if kept.isEmpty {
                continue
            }
            block["hooks"] = kept
            out.append(block)
        }
        return out
    }

    /// settings.json round-trips through JSONSerialization, so compare
    /// parsed values, not bytes.
    private static func bothParseEqual(_ a: Data, _ b: Data) -> Bool {
        guard let pa = try? JSONSerialization.jsonObject(with: a) as? NSDictionary,
              let pb = try? JSONSerialization.jsonObject(with: b) as? NSDictionary
        else { return false }
        return pa == pb
    }

    // MARK: - Statusline tee

    private static var teeBlock: String {
        """
        \(teeBegin)
        (
            _shud_spool="$HOME/Library/Application Support/SessionsHUD/events"
            _shud_sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | tr -cd 'A-Za-z0-9._-')
            if [ -n "$_shud_sid" ]; then
                mkdir -p "$_shud_spool"
                printf '{"v":1,"event":"Statusline","ts":%s000000,"pid":0,"tty":"","term_program":"","payload":%s}\\n' \\
                    "$(date +%s)" "$input" > "$_shud_spool/.tmp.statusline.$$" \\
                    && mv -f "$_shud_spool/.tmp.statusline.$$" "$_shud_spool/statusline-$_shud_sid.json"
            fi
        ) >/dev/null 2>&1 &
        \(teeEnd)
        """
    }

    /// Replaces any previous tee (sentinel block, legacy daemon-curl block,
    /// or old ">>> <<<" sentinel style) with the spool version, inserted
    /// right after `input=$(cat)`. Missing statusline file is not an error —
    /// quota display is optional.
    private static func patchStatusline(_ log: inout [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: statuslineURL.path),
              var text = try? String(contentsOf: statuslineURL, encoding: .utf8)
        else {
            log.append("statusline: 未安裝自訂 statusline，略過（quota 顯示為選用功能）")
            return
        }
        let before = text
        text = removeSentinelBlock(text, begin: teeBegin, end: teeEnd)
        text = removeSentinelBlock(
            text,
            begin: "# >>> sessions-hud statusline tee >>>",
            end: "# <<< sessions-hud statusline tee <<<"
        )
        text = removeLegacyCurlTee(text)

        var lines = text.components(separatedBy: "\n")
        guard let anchor = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false } // skip comments
            return trimmed.replacingOccurrences(of: " ", with: "").contains("input=$(cat)")
        }) else {
            log.append("statusline: 找不到 input=$(cat) 行，未插入 tee — 請手動貼上 packaging/statusline-snippet.sh")
            if text != before {
                try? text.write(to: statuslineURL, atomically: true, encoding: .utf8)
            }
            return
        }
        lines.insert(teeBlock, at: anchor + 1)
        let updated = lines.joined(separator: "\n")
        if updated != before {
            try? updated.write(to: statuslineURL, atomically: true, encoding: .utf8)
            log.append("statusline: quota tee 已更新為 spool 版本")
        } else {
            log.append("statusline: 已是最新，未變更")
        }
    }

    private static func removeTee(_ log: inout [String]) {
        guard let text = try? String(contentsOf: statuslineURL, encoding: .utf8) else { return }
        let cleaned = removeSentinelBlock(text, begin: teeBegin, end: teeEnd)
        if cleaned != text {
            try? cleaned.write(to: statuslineURL, atomically: true, encoding: .utf8)
            log.append("statusline: tee 已移除")
        }
    }

    private static func removeSentinelBlock(_ text: String, begin: String, end: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let b = lines.firstIndex(where: { $0.contains(begin) }) {
            guard let e = lines[b...].firstIndex(where: { $0.contains(end) }) else { break }
            lines.removeSubrange(b...e)
        }
        return lines.joined(separator: "\n")
    }

    /// The pre-refactor tee was a hand-pasted `(printf … | curl … 39501…) &`
    /// pipeline with no sentinels — match on the URL and peel back to the
    /// start of the pipeline, plus its lead-in comment. Deleting anything
    /// less than the whole pipeline would leave the user's statusline script
    /// syntactically broken, so when the shape doesn't match exactly we
    /// leave the block alone (a dead fire-and-forget curl is harmless).
    private static func removeLegacyCurlTee(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var searchFrom = 0
        while let urlIdx = lines[searchFrom...].firstIndex(where: { $0.contains("39501/hook/statusline") }) {
            guard let range = legacyTeeRange(in: lines, urlLine: urlIdx) else {
                searchFrom = urlIdx + 1 // unrecognized shape — skip, keep script valid
                continue
            }
            lines.removeSubrange(range)
            searchFrom = range.lowerBound
        }
        return lines.joined(separator: "\n")
    }

    /// Validates the exact legacy pipeline shape: a `(printf` opener at most
    /// 6 lines above the URL line, with every line in between ending in a
    /// `\` continuation — anything else is not our block.
    private static func legacyTeeRange(in lines: [String], urlLine: Int) -> ClosedRange<Int>? {
        var start = -1
        var i = urlLine
        while i >= 0 && urlLine - i <= 6 {
            if lines[i].contains("(printf") {
                start = i
                break
            }
            i -= 1
        }
        guard start >= 0 else { return nil }
        for j in start..<urlLine {
            guard lines[j].hasSuffix("\\") else { return nil } // not one pipeline
        }
        var first = start
        if start > 0 {
            let prev = lines[start - 1].trimmingCharacters(in: .whitespaces)
            if prev.hasPrefix("#"), prev.contains("sessionsd") || prev.lowercased().contains("tee") {
                first = start - 1
            }
        }
        return first...urlLine
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

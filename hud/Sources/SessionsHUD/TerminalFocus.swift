import AppKit
import Foundation

/// Focuses the terminal window that owns a given session. We match on the
/// controlling tty (e.g. "/dev/ttys003") — the only identifier that uniquely
/// survives tab reordering and window moves in both Terminal.app and iTerm2.
enum TerminalFocus {
    /// Returns `nil` on success; a short user-facing message on failure.
    @discardableResult
    static func openInTerminal(tty: String?, termProgram: String?) -> String? {
        guard let tty, !tty.isEmpty else {
            return "沒有 tty 資訊，無法在終端聚焦（tmux / SSH / IDE 內建終端不支援）"
        }
        let script: String
        switch termProgram {
        case "iTerm.app", "iTerm":
            script = iTermScript(tty: tty)
        case "Apple_Terminal", nil:
            script = terminalAppScript(tty: tty)
        default:
            // Unknown terminal — try Terminal.app as a best-effort fallback.
            script = terminalAppScript(tty: tty)
        }
        if let err = runReturningError(script) {
            return "無法在終端聚焦：\(err)。請檢查系統設定 → 隱私權 → 自動化（Terminal / iTerm）"
        }
        return nil
    }

    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// Fire a no-op AppleScript once at first launch so macOS prompts for
    /// Automation consent up-front instead of silently failing the first time
    /// the user clicks the jump-to-terminal button. We target Terminal.app
    /// because it is preinstalled on every Mac — iTerm users will still see a
    /// second prompt the first time they jump into iTerm, which is acceptable.
    static func primeAutomationPermission() {
        let script = """
        tell application "Terminal"
            count windows
        end tell
        """
        _ = runReturningError(script)
    }

    private static func runReturningError(_ source: String) -> String? {
        var err: NSDictionary?
        let applescript = NSAppleScript(source: source)
        applescript?.executeAndReturnError(&err)
        if let err {
            NSLog("TerminalFocus: osascript failed: \(err)")
            return (err["NSAppleScriptErrorMessage"] as? String) ?? "osascript failed"
        }
        return nil
    }
}

import AppKit
import Foundation

/// Focuses the terminal window that started a given `cc` session. We match on
/// the controlling tty (e.g. "/dev/ttys003") that the wrapper captured at
/// register time — this is the only identifier that uniquely survives tab
/// reordering and window moves in both Terminal.app and iTerm2.
enum TerminalFocus {
    static func openInTerminal(tty: String?, termProgram: String?) {
        guard let tty, !tty.isEmpty else {
            NSSound.beep()
            return
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
        run(script)
    }

    private static func run(_ source: String) {
        var err: NSDictionary?
        let applescript = NSAppleScript(source: source)
        applescript?.executeAndReturnError(&err)
        if let err {
            NSLog("TerminalFocus: osascript failed: \(err)")
        }
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
}

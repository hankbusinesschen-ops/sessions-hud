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

    // MARK: - Launch new session

    /// Spawns a new wrapper session by asking Terminal.app (or iTerm2 when
    /// available) to open a window, cd into `cwd`, and exec `ccw`/`cxw`.
    /// This is the only path that works from a GUI app — the wrapper needs
    /// a controlling TTY and SwiftUI can't provide one directly.
    ///
    /// Returns nil on success; an error string on AppleScript failure.
    @discardableResult
    static func launchNewSession(
        flavor: WrapperFlavor,
        mode: PermissionMode,
        name: String,
        cwd: String
    ) -> String? {
        let command = buildShellCommand(flavor: flavor, mode: mode, name: name, cwd: cwd)
        let useITerm = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.googlecode.iterm2"
        }
        let script = useITerm
            ? iTermLaunchScript(command: command)
            : terminalLaunchScript(command: command)
        return runReturningError(script)
    }

    /// Build the shell command piped into `do script` / `create window …
    /// command`. We single-quote every user-supplied piece so spaces, Chinese
    /// characters, and even embedded single quotes are safe.
    static func buildShellCommand(
        flavor: WrapperFlavor,
        mode: PermissionMode,
        name: String,
        cwd: String
    ) -> String {
        var parts: [String] = [
            "cd \(shellEscape(cwd))",
            "\(flavor.rawValue) \(shellEscape(name))",
        ]
        // Only ccw gets the permission-mode flag; cxw/codex has no equivalent
        // surface in v1, and `--permission-mode default` is just noise.
        if flavor == .ccw, mode != .defaultMode {
            parts[1] += " -- --permission-mode \(mode.rawValue)"
        }
        return parts.joined(separator: " && ")
    }

    /// POSIX single-quote escape: `foo'bar` → `'foo'\''bar'`.
    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string escape: only `"` and `\` are special inside a
    /// double-quoted AppleScript literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func terminalLaunchScript(command: String) -> String {
        let escaped = appleScriptEscape(command)
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    private static func iTermLaunchScript(command: String) -> String {
        // Wrap in `/bin/sh -c '...'` so the whole chained command runs in one
        // shell invocation regardless of the user's login shell quirks.
        let sh = "/bin/sh -c " + shellEscape(command)
        let escaped = appleScriptEscape(sh)
        return """
        tell application "iTerm"
            activate
            create window with default profile command "\(escaped)"
        end tell
        """
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

enum WrapperFlavor: String, CaseIterable, Identifiable {
    case ccw
    case cxw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ccw: return "claude (ccw)"
        case .cxw: return "codex (cxw)"
        }
    }
}

/// Mirrors Claude Code's `--permission-mode` flag. cxw/codex has no
/// equivalent in v1 so we just skip the flag when flavor == .cxw.
enum PermissionMode: String, CaseIterable, Identifiable {
    case defaultMode = "default"
    case plan
    case acceptEdits
    case bypassPermissions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .defaultMode:       return "default"
        case .plan:              return "plan"
        case .acceptEdits:       return "auto edits"
        case .bypassPermissions: return "yolo"
        }
    }
}

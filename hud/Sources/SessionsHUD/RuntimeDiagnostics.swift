import Foundation

/// Local checks the HUD can run to guide users (daemon, hooks, statusline, ccw in PATH).
struct RuntimeDiagnostic: Identifiable, Equatable {
    let id: String
    let ok: Bool
    let label: String
    let detail: String
}

enum RuntimeDiagnostics {
    private static var homeClaude: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private static var settingsURL: URL { homeClaude.appendingPathComponent("settings.json") }
    private static var statuslineURL: URL { homeClaude.appendingPathComponent("statusline-command.sh") }

    /// Gathers file-based checks. Caller should merge in daemon state from `AppModel`.
    static func gatherFileBasedChecks() -> [RuntimeDiagnostic] {
        var out: [RuntimeDiagnostic] = []
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            if let s = try? String(contentsOf: settingsURL, encoding: .utf8) {
                let hasHook = s.contains("post-event.sh")
                out.append(
                    RuntimeDiagnostic(
                        id: "hooks",
                        ok: hasHook,
                        label: "Claude hooks",
                        detail: hasHook
                            ? "settings.json references post-event.sh"
                            : "merge packaging/merge-hooks.sh or re-run install.sh"
                    )
                )
            } else {
                out.append(
                    RuntimeDiagnostic(
                        id: "hooks",
                        ok: false,
                        label: "Claude hooks",
                        detail: "could not read ~/.claude/settings.json"
                    )
                )
            }
        } else {
            out.append(
                RuntimeDiagnostic(
                    id: "hooks",
                    ok: false,
                    label: "Claude hooks",
                    detail: "missing ~/.claude/settings.json"
                )
            )
        }

        if FileManager.default.fileExists(atPath: statuslineURL.path) {
            if let s = try? String(contentsOf: statuslineURL, encoding: .utf8) {
                let ok = s.contains("39501/hook/statusline")
                out.append(
                    RuntimeDiagnostic(
                        id: "statusline",
                        ok: ok,
                        label: "Statusline tee",
                        detail: ok
                            ? "statusline-command.sh posts to sessionsd"
                            : "add tee from packaging/patch-statusline.sh for ctx% / 5h% / 7d%"
                    )
                )
            } else {
                out.append(
                    RuntimeDiagnostic(
                        id: "statusline",
                        ok: false,
                        label: "Statusline tee",
                        detail: "could not read ~/.claude/statusline-command.sh"
                    )
                )
            }
        } else {
            // Missing file is common for users without a custom statusline — not a hard failure.
            out.append(
                RuntimeDiagnostic(
                    id: "statusline",
                    ok: true,
                    label: "Statusline tee",
                    detail: "未安裝（選用；HUD 的 ctx% / 5h% / 7d% 需 packaging/patch-statusline.sh）"
                )
            )
        }

        return out
    }
}

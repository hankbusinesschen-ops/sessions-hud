import AppKit
import Foundation

/// Watches session status transitions and fires an audible + dock-bounce alert
/// when a session needs approval or finishes. Silent on first sight so that
/// the initial list load doesn't blast noise.
///
/// Implementation note: we intentionally avoid UNUserNotificationCenter because
/// it requires a code-signed bundle with a stable bundle identifier, which we
/// don't have for `swift run` dev builds. The sound + dock attention bounce is
/// reliable on unsigned builds and covers the "something needs me" use case.
@MainActor
final class Notifier {
    private var lastStatuses: [String: SessionSummary.Status] = [:]
    private var seeded = false

    /// Muted via `defaults write com.sessionshud.hud mute -bool YES` if someone
    /// wants the visual-only experience.
    private var muted: Bool {
        UserDefaults.standard.bool(forKey: "mute")
    }

    func observe(_ sessions: [SessionSummary]) {
        defer {
            lastStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })
            seeded = true
        }
        guard seeded else { return }

        for s in sessions {
            let prev = lastStatuses[s.id]
            guard prev != s.status else { continue }
            handleTransition(from: prev, to: s.status, session: s)
        }
    }

    private func handleTransition(
        from: SessionSummary.Status?,
        to: SessionSummary.Status,
        session: SessionSummary
    ) {
        switch to {
        case .needsApproval:
            play("Glass")
            NSApp.requestUserAttention(.criticalRequest)
        case .done where from != .done:
            play("Hero")
            NSApp.requestUserAttention(.informationalRequest)
        default:
            break
        }
    }

    private func play(_ name: String) {
        guard !muted else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

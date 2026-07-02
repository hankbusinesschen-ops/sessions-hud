import Foundation

/// One monitored Claude Code session. Built locally from hook events and
/// persisted to a state snapshot between app launches.
struct SessionSummary: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var status: Status
    var cwd: String?
    var lastEventAt: Date
    /// PID of the claude process (from the hook's ancestor walk); 0 = unknown.
    var pid: Int32
    /// Controlling tty, e.g. "/dev/ttys003". Empty when the session runs
    /// without one (tmux, SSH, IDE-embedded terminals).
    var tty: String
    /// TERM_PROGRAM of the host terminal ("Apple_Terminal", "iTerm.app", …).
    var termProgram: String
    var pendingPrompt: PendingPrompt?
    var stats: SessionStats?
    var currentActivity: Activity?

    enum Status: String, Codable {
        case running
        case needsApproval = "needs_approval"
        case done
        case idle
        case unknown
    }
}

/// What the session is actively doing right now.
enum Activity: Codable, Equatable {
    case tool(name: String, since: Date)
    case subagent(name: String?, since: Date)
    case compacting(since: Date)

    var since: Date {
        switch self {
        case .tool(_, let s), .subagent(_, let s), .compacting(let s): return s
        }
    }
}

/// Quota snapshot fed by the statusline tee. nil until the user's statusline
/// script has fired at least once for this session.
struct SessionStats: Codable, Equatable {
    var modelDisplay: String?
    var ctxPct: Float?
    var fiveHrPct: Float?
    var sevenDayPct: Float?
    var updatedAt: Date
}

/// A prompt the session is blocked on. The HUD is watch-only: every variant
/// carries just the human-readable message — answering happens in the
/// terminal.
enum PendingPrompt: Codable, Equatable {
    case permission(message: String)
    case planApproval(message: String)
    case raw(message: String)

    var message: String {
        switch self {
        case .permission(let m), .planApproval(let m), .raw(let m):
            return m
        }
    }
}

extension SessionSummary.Status {
    var label: String {
        switch self {
        case .running:       return "running"
        case .needsApproval: return "needs OK"
        case .done:          return "done"
        case .idle:          return "idle"
        case .unknown:       return "?"
        }
    }
}

extension SessionSummary {
    /// True when this session is blocking on something the user has to resolve —
    /// either an explicit `needs_approval` status or any live pending_prompt.
    /// Drives sort priority, Attention Bar membership, and the pulsing dot.
    var needsAttention: Bool {
        if status == .needsApproval { return true }
        return pendingPrompt != nil
    }

    /// Lower = higher priority (sorted to top of the list).
    var sortPriority: Int {
        if needsAttention { return 0 }
        switch status {
        case .running:       return 1
        case .idle:          return 2
        case .done:          return 3
        case .needsApproval: return 0
        case .unknown:       return 4
        }
    }
}

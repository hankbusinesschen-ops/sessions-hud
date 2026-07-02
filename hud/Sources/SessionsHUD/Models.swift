import Foundation

struct SessionSummary: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: Status
    let cwd: String?
    let lastEventAt: Date
    let startedAt: Date
    let pendingPrompt: PendingPrompt?
    let stats: SessionStats?
    let currentActivity: Activity?

    enum Status: String, Decodable {
        case running
        case needsApproval = "needs_approval"
        case done
        case idle
        case exited
        case unknown
    }
}

/// What the session is actively doing right now. Tagged by "kind":
///
///   {"kind":"tool","name":"Bash","since":"2026-04-17T…"}
///   {"kind":"subagent","name":"Explore","since":"…"}        (name optional)
///   {"kind":"compacting","since":"…"}
enum Activity: Decodable, Equatable {
    case tool(name: String, since: Date)
    case subagent(name: String?, since: Date)
    case compacting(since: Date)

    private enum CodingKeys: String, CodingKey {
        case kind, name, since
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let since = try c.decode(Date.self, forKey: .since)
        switch kind {
        case "tool":
            self = .tool(name: try c.decode(String.self, forKey: .name), since: since)
        case "subagent":
            self = .subagent(name: try c.decodeIfPresent(String.self, forKey: .name), since: since)
        case "compacting":
            self = .compacting(since: since)
        default:
            self = .tool(name: kind, since: since) // forward-compat: render unknown kind as its tag
        }
    }

    var since: Date {
        switch self {
        case .tool(_, let s), .subagent(_, let s), .compacting(let s): return s
        }
    }
}

/// Quota snapshot fed by the statusline tee. nil until the user's statusline
/// script has fired at least once for this session. Each field is
/// independently optional because partial payloads are tolerated.
struct SessionStats: Decodable, Equatable {
    let modelDisplay: String?
    let ctxPct: Float?
    let fiveHrPct: Float?
    let sevenDayPct: Float?
    let updatedAt: Date
}

/// A prompt the session is blocked on. The HUD is watch-only: every variant
/// carries just the human-readable message — answering happens in the
/// terminal.
enum PendingPrompt: Decodable, Equatable {
    case permission(message: String)
    case planApproval(message: String)
    case question(message: String)
    case raw(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind, message, questions
    }

    /// Just enough of the old AskUserQuestion payload to surface its text.
    private struct QuestionText: Decodable {
        let question: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        switch kind {
        case "permission":
            self = .permission(message: message)
        case "plan_approval":
            self = .planApproval(message: message)
        case "question":
            let texts = try c.decodeIfPresent([QuestionText].self, forKey: .questions)
            self = .question(message: texts?.first?.question ?? message)
        case "raw":
            self = .raw(message: message)
        default:
            self = .raw(message: message.isEmpty ? "unknown prompt: \(kind)" : message)
        }
    }

    var message: String {
        switch self {
        case .permission(let m), .planApproval(let m), .question(let m), .raw(let m):
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
        case .exited:        return "exited"
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
        case .exited:        return 4
        case .needsApproval: return 0
        case .unknown:       return 5
        }
    }
}

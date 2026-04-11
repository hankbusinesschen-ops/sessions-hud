import Foundation

struct SessionSummary: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: Status
    let cwd: String?
    let lastEventAt: Date
    let startedAt: Date
    let messageCount: Int
    let wrapperId: String?
    let pendingPrompt: PendingPrompt?
    let stats: SessionStats?

    enum Status: String, Codable {
        case running
        case needsApproval = "needs_approval"
        case done
        case idle
        case exited
        case unknown
    }
}

/// Full session payload returned by `GET /sessions/:id`. Mirrors the daemon's
/// `Session` struct, minus the `#[serde(skip)]` fields.
struct SessionDetail: Codable, Equatable {
    let id: String
    let name: String
    let status: SessionSummary.Status
    let cwd: String?
    let transcriptPath: String?
    let startedAt: Date
    let lastEventAt: Date
    let messages: [SessionMessage]
    let wrapperId: String?
    let tty: String?
    let termProgram: String?
    let pendingPrompt: PendingPrompt?
    let stats: SessionStats?
}

/// Mirrors daemon's `SessionStats`. Populated by the statusline tee pipeline;
/// nil until the user's statusline script has fired at least once for this
/// session. Each field is independently optional because partial payloads are
/// tolerated on the daemon side.
struct SessionStats: Codable, Equatable {
    let modelDisplay: String?
    let ctxPct: Float?
    let fiveHrPct: Float?
    let sevenDayPct: Float?
    let updatedAt: Date
}

/// Mirrors the daemon's `PendingPrompt` enum. JSON shape:
///   {"kind":"permission","message":"..."}
///   {"kind":"plan_approval","message":"..."}
///   {"kind":"question","tool_use_id":"...","questions":[...]}
///   {"kind":"raw","message":"..."}
/// The daemon tags with "kind" and uses snake_case for field names; the
/// shared JSONDecoder has `convertFromSnakeCase` so the CodingKey raw values
/// here are camelCase as normal.
enum PendingPrompt: Codable, Equatable {
    case permission(message: String)
    case planApproval(message: String)
    case question(toolUseId: String, questions: [AskQuestion])
    case raw(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind, message, toolUseId, questions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "permission":
            self = .permission(message: try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        case "plan_approval":
            self = .planApproval(message: try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        case "question":
            self = .question(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                questions: try c.decode([AskQuestion].self, forKey: .questions)
            )
        case "raw":
            self = .raw(message: try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        default:
            self = .raw(message: "unknown prompt: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permission(let m):
            try c.encode("permission", forKey: .kind)
            try c.encode(m, forKey: .message)
        case .planApproval(let m):
            try c.encode("plan_approval", forKey: .kind)
            try c.encode(m, forKey: .message)
        case .question(let id, let qs):
            try c.encode("question", forKey: .kind)
            try c.encode(id, forKey: .toolUseId)
            try c.encode(qs, forKey: .questions)
        case .raw(let m):
            try c.encode("raw", forKey: .kind)
            try c.encode(m, forKey: .message)
        }
    }
}

struct AskQuestion: Codable, Equatable {
    let question: String
    let header: String
    let options: [AskOption]
    let multiSelect: Bool
}

struct AskOption: Codable, Equatable {
    let label: String
    let description: String
}

struct SessionMessage: Codable, Equatable, Identifiable {
    let role: String
    let kind: String       // "text" | "tool_use" | "tool_result"
    let text: String
    let timestamp: String?

    /// Stable enough for ForEach: (timestamp, role, text-hash). Messages are
    /// append-only in the daemon, so collisions are effectively impossible.
    var id: String {
        "\(timestamp ?? "")|\(role)|\(kind)|\(text.count)|\(text.hashValue)"
    }
}

extension SessionSummary.Status {
    var icon: String {
        switch self {
        case .running:       return "🟢"
        case .needsApproval: return "🟡"
        case .done:          return "✅"
        case .idle:          return "⚪"
        case .exited:        return "🔴"
        case .unknown:       return "⚫"
        }
    }

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

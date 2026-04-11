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

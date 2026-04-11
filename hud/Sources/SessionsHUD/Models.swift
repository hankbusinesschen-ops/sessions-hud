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

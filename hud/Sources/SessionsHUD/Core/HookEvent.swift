import Foundation

/// One spool file: the envelope written by hooks/post-event.sh (or the
/// statusline tee) wrapping the raw Claude Code hook payload.
struct HookEvent: Decodable {
    let v: Int
    /// Hook event name ("SessionStart", "PreToolUse", …) or "Statusline".
    let event: String
    /// Microseconds since the Unix epoch.
    let ts: Int64
    /// PID of the claude process; 0 = unknown (statusline tee).
    let pid: Int32
    /// "/dev/ttysNNN" or "".
    let tty: String
    /// TERM_PROGRAM of the host terminal or "".
    let termProgram: String
    let payload: Payload

    var date: Date { Date(timeIntervalSince1970: Double(ts) / 1_000_000) }

    enum CodingKeys: String, CodingKey {
        case v, event, ts, pid, tty
        case termProgram = "term_program"
        case payload
    }

    /// The subset of Claude Code's hook / statusline JSON the HUD consumes.
    /// Every field is optional — payload shape varies per event type.
    struct Payload: Decodable {
        let sessionId: String?
        let cwd: String?
        let message: String?
        let notificationType: String?
        let toolName: String?
        let subagentType: String?
        // Statusline-only:
        let model: ModelInfo?
        let contextWindow: UsedPct?
        let rateLimits: RateLimits?
        let workspace: Workspace?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd, message
            case notificationType = "notification_type"
            case toolName = "tool_name"
            case subagentType = "subagent_type"
            case model
            case contextWindow = "context_window"
            case rateLimits = "rate_limits"
            case workspace
        }

        struct ModelInfo: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }

        struct UsedPct: Decodable {
            let usedPercentage: Float?
            enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage" }
        }

        struct RateLimits: Decodable {
            let fiveHour: UsedPct?
            let sevenDay: UsedPct?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct Workspace: Decodable {
            let currentDir: String?
            enum CodingKeys: String, CodingKey { case currentDir = "current_dir" }
        }
    }
}

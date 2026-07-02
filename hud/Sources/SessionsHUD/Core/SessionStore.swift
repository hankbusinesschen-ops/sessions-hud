import Foundation

/// In-memory session registry: reduces hook events into `SessionSummary`
/// state. Pure logic — no timers, no I/O — so the reducer is unit-testable.
/// Threading is the caller's job (AppModel keeps it on the main actor).
final class SessionStore {
    private(set) var sessions: [String: SessionSummary] = [:]

    /// How long a `done` session keeps its "done" badge before decaying to
    /// idle (so a finished run is noticeable but doesn't stick forever).
    static let doneDecay: TimeInterval = 600
    /// Fallback removal for sessions we can't liveness-check (pid unknown).
    static let unknownPidCutoff: TimeInterval = 7200

    // MARK: - Reducer

    /// Hook events that may create a session row. Anything else only updates
    /// an existing session — an unrecognized event type must not spawn
    /// phantom "?" rows.
    private static let creatingEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "Notification", "Stop",
        "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "Statusline",
    ]

    /// Applies one event. Returns true when visible state changed.
    @discardableResult
    func apply(_ ev: HookEvent) -> Bool {
        guard let sid = ev.payload.sessionId, !sid.isEmpty else { return false }

        if ev.event == "SessionEnd" {
            return sessions.removeValue(forKey: sid) != nil
        }
        guard sessions[sid] != nil || Self.creatingEvents.contains(ev.event) else {
            return false
        }

        var s = sessions[sid] ?? SessionSummary(
            id: sid,
            name: Self.deriveName(cwd: ev.payload.cwd, sessionId: sid),
            status: .unknown,
            cwd: nil,
            lastEventAt: ev.date,
            pid: 0,
            tty: "",
            termProgram: ""
        )
        let before = s

        s.lastEventAt = max(s.lastEventAt, ev.date)
        // Host-context fields are last-writer-wins but never cleared by an
        // event that lacks them (the statusline tee sends pid 0 / empty tty).
        if ev.pid > 0 { s.pid = ev.pid }
        if !ev.tty.isEmpty { s.tty = ev.tty }
        if !ev.termProgram.isEmpty { s.termProgram = ev.termProgram }
        if let cwd = ev.payload.cwd ?? ev.payload.workspace?.currentDir, !cwd.isEmpty {
            if s.cwd != cwd {
                s.cwd = cwd
                s.name = Self.deriveName(cwd: cwd, sessionId: sid)
            }
        }

        switch ev.event {
        case "SessionStart", "UserPromptSubmit":
            s.status = .running
            s.pendingPrompt = nil
            s.currentActivity = nil

        case "Notification":
            switch ev.payload.notificationType {
            case "permission_prompt":
                s.status = .needsApproval
                let msg = ev.payload.message ?? ""
                s.pendingPrompt = msg.contains("approval for the plan")
                    ? .planApproval(message: msg)
                    : .permission(message: msg)
            case "idle_prompt":
                s.status = .idle
            default:
                if let msg = ev.payload.message, !msg.isEmpty {
                    s.status = .needsApproval
                    s.pendingPrompt = .raw(message: msg)
                }
            }

        case "Stop":
            s.status = .done
            s.pendingPrompt = nil
            s.currentActivity = nil

        case "PreToolUse":
            s.status = .running
            s.pendingPrompt = nil
            s.currentActivity = .tool(name: ev.payload.toolName ?? "tool", since: ev.date)

        case "PostToolUse":
            s.status = .running
            s.pendingPrompt = nil
            // Only clear the chip for the matching tool — a stray Post for an
            // earlier tool must not wipe a newer activity.
            if case .tool(let name, _) = s.currentActivity,
               name == (ev.payload.toolName ?? name) {
                s.currentActivity = nil
            }

        case "SubagentStart":
            s.status = .running
            s.currentActivity = .subagent(name: ev.payload.subagentType, since: ev.date)

        case "SubagentStop":
            if case .subagent = s.currentActivity {
                s.currentActivity = nil
            }

        case "PreCompact":
            s.currentActivity = .compacting(since: ev.date)

        case "PostCompact":
            if case .compacting = s.currentActivity {
                s.currentActivity = nil
            }

        case "Statusline":
            var stats = s.stats ?? SessionStats(updatedAt: ev.date)
            if let m = ev.payload.model?.displayName { stats.modelDisplay = m }
            if let p = ev.payload.contextWindow?.usedPercentage { stats.ctxPct = p }
            if let p = ev.payload.rateLimits?.fiveHour?.usedPercentage { stats.fiveHrPct = p }
            if let p = ev.payload.rateLimits?.sevenDay?.usedPercentage { stats.sevenDayPct = p }
            stats.updatedAt = ev.date
            s.stats = stats
            // Statusline redraws are not session activity — don't let them
            // keep a quiet session looking fresh.
            s.lastEventAt = before.lastEventAt

        default:
            break // unknown hook type: context fields above still updated
        }

        sessions[sid] = s
        return s != before
    }

    // MARK: - Sweep

    /// Periodic maintenance: decay stale `done` badges, drop sessions whose
    /// claude process is gone, and expire pid-less sessions after a long
    /// quiet period. `isAlive` is injected so tests can fake process state.
    @discardableResult
    func sweep(now: Date, isAlive: (Int32) -> Bool) -> Bool {
        var changed = false
        for (id, var s) in sessions {
            if s.status == .done, now.timeIntervalSince(s.lastEventAt) > Self.doneDecay {
                s.status = .idle
                sessions[id] = s
                changed = true
            }
            // Statusline updates deliberately don't advance lastEventAt, but
            // they do prove the session is alive — a statusline-only session
            // (pid unknown) must not flap out every cutoff period while its
            // quota is still refreshing.
            let lastSeen = max(s.lastEventAt, s.stats?.updatedAt ?? .distantPast)
            let dead = s.pid > 0
                ? !isAlive(s.pid)
                : now.timeIntervalSince(lastSeen) > Self.unknownPidCutoff
            if dead {
                sessions.removeValue(forKey: id)
                changed = true
            }
        }
        return changed
    }

    /// Drop one session from the registry (the HUD "forget" action). The
    /// underlying process keeps running; its next hook event re-adds it.
    @discardableResult
    func remove(id: String) -> Bool {
        sessions.removeValue(forKey: id) != nil
    }

    // MARK: - Snapshot

    func snapshotData() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        return try enc.encode(Array(sessions.values))
    }

    func loadSnapshot(_ data: Data) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let list = try? dec.decode([SessionSummary].self, from: data) else { return }
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: -

    private static func deriveName(cwd: String?, sessionId: String) -> String {
        if let cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return String(sessionId.prefix(8))
    }
}

extension SessionStats {
    init(updatedAt: Date) {
        self.init(modelDisplay: nil, ctxPct: nil, fiveHrPct: nil, sevenDayPct: nil, updatedAt: updatedAt)
    }
}

import Foundation
import Combine

enum ConnectionState: Equatable {
    case connecting
    case connected
    case disconnected
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var lastError: String?
    @Published var now: Date = Date()
    @Published var connectionState: ConnectionState = .connecting
    @Published var selectedId: String? {
        didSet {
            if selectedId == nil {
                selectedDetail = nil
                injectStatus = nil
            } else if selectedId != oldValue {
                selectedDetail = nil
                injectStatus = nil
                Task { await refreshSelected() }
            }
        }
    }
    @Published var selectedDetail: SessionDetail?
    @Published var injectDraft: String = ""
    @Published var injectStatus: String?

    private let notifier = Notifier()
    private var clockTimer: Timer?
    private var healthTimer: Timer?
    private var events: EventStreamClient?
    private let daemonBase: String = {
        ProcessInfo.processInfo.environment["SESSIONSD_URL"] ?? "http://127.0.0.1:39501"
    }()
    private func endpoint(_ path: String) -> URL {
        URL(string: "\(daemonBase)\(path)")!
    }

    deinit {
        clockTimer?.invalidate()
        healthTimer?.invalidate()
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        // chrono RFC3339 with fractional seconds, e.g. "2026-04-11T06:20:52.329571Z"
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = frac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            if let d = plain.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "bad date: \(s)"
            )
        }
        return d
    }()

    /// Distinct git-repo roots currently in use by any live session, ordered
    /// by most-recently-active first. Used as quick-pick in the launcher
    /// popover. Sessions whose cwd isn't inside a git repo are skipped —
    /// the launcher falls back to NSOpenPanel for those.
    var recentProjectRoots: [String] {
        let sorted = sessions.sorted { $0.lastEventAt > $1.lastEventAt }
        var seen: Set<String> = []
        var out: [String] = []
        for s in sorted {
            guard let root = RepoRoot.absolutePath(for: s.cwd) else { continue }
            if seen.insert(root).inserted {
                out.append(root)
            }
        }
        return out
    }

    func start() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // /health poll — SSE can wedge on sleep/wake, so treat HTTP as ground truth.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkHealth() }
        }
        Task { await refresh() }
        Task { await checkHealth() }

        let client = EventStreamClient(url: endpoint("/events"))
        events = client
        Task { [weak self] in
            // Capture once inside the Task so the closures below capture a
            // let (Sendable under Swift 6) instead of the mutable `self?`
            // reference that came in from the outer scope.
            let owner = self
            await client.start(
                onConnect: {
                    await owner?.onSseConnected()
                },
                onDisconnect: {
                    await owner?.setConnectionState(.disconnected)
                },
                onEvent: { ev in
                    await owner?.handleEvent(ev)
                }
            )
        }
    }

    private func onSseConnected() async {
        setConnectionState(.connected)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.refresh() }
            group.addTask { [weak self] in await self?.refreshSelected() }
        }
    }

    private func setConnectionState(_ state: ConnectionState) {
        guard self.connectionState != state else { return }
        self.connectionState = state
    }

    private func checkHealth() async {
        var req = URLRequest(url: endpoint("/health"))
        req.timeoutInterval = 2
        let ok: Bool
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            ok = http.map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            ok = false
        }
        setConnectionState(ok ? .connected : .disconnected)
    }

    private func handleEvent(_ ev: SseEvent) async {
        switch ev {
        case .sessionsChanged:
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.refresh() }
                if selectedId != nil {
                    group.addTask { [weak self] in await self?.refreshSelected() }
                }
            }
        case .sessionUpdated(let id):
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.refresh() }
                if id == selectedId {
                    group.addTask { [weak self] in await self?.refreshSelected() }
                }
            }
        case .unknown:
            break
        }
    }

    func refresh() async {
        do {
            var req = URLRequest(url: endpoint("/sessions"))
            req.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: req)
            // Daemon sorts by last_event_at desc; we resort on (sortPriority,
            // lastEventAt desc) so pending prompts float above grouped rows.
            let list = try decoder.decode([SessionSummary].self, from: data)
                .sorted { a, b in
                    if a.sortPriority != b.sortPriority {
                        return a.sortPriority < b.sortPriority
                    }
                    return a.lastEventAt > b.lastEventAt
                }
            if self.sessions != list {
                self.sessions = list
            }
            self.notifier.observe(list)
            self.lastError = nil
            setConnectionState(.connected)
        } catch {
            self.lastError = "daemon: \(error.localizedDescription)"
        }
    }

    /// Sessions the user has to act on — drives the Tier 0 Attention Bar.
    var attentionSessions: [SessionSummary] {
        sessions.filter { $0.needsAttention }
    }

    /// Sessions not in the Attention Bar — drives the grouped / flat list
    /// below.
    var routineSessions: [SessionSummary] {
        sessions.filter { !$0.needsAttention }
    }

    /// How many sessions are blocking on the user right now. Drives the
    /// menu-bar badge and the Cmd+J jump shortcut.
    var attentionCount: Int { attentionSessions.count }

    /// Select the next (or previous) session that `needsAttention`. Wraps at
    /// the ends. No-op when there's nothing waiting. Called from the
    /// Cmd+J / Shift+Cmd+J hidden buttons in `SessionListView`.
    func jumpToAttention(forward: Bool) {
        let pool = attentionSessions
        guard !pool.isEmpty else { return }
        let ids = pool.map(\.id)
        let currentIdx = selectedId.flatMap { ids.firstIndex(of: $0) }
        let nextIdx: Int = {
            guard let i = currentIdx else { return forward ? 0 : ids.count - 1 }
            return forward
                ? (i + 1) % ids.count
                : (i - 1 + ids.count) % ids.count
        }()
        selectedId = ids[nextIdx]
    }

    /// Fetch the full session payload for the currently selected id so Mode B
    /// can render the message history. Called on selection change and on each
    /// poll tick while a row remains selected.
    func refreshSelected() async {
        guard let id = selectedId else { return }
        do {
            var req = URLRequest(url: endpoint("/sessions/\(id)"))
            req.timeoutInterval = 2
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                // session disappeared — drop the detail but keep the selection
                // so the view can show a placeholder.
                self.selectedDetail = nil
                return
            }
            let detail = try decoder.decode(SessionDetail.self, from: data)
            if self.selectedDetail != detail {
                self.selectedDetail = detail
            }
        } catch {
            // Leave selectedDetail as-is; surface via injectStatus to avoid
            // stomping daemon-list error.
            self.injectStatus = "detail: \(error.localizedDescription)"
        }
    }

    /// POST the given text to `/sessions/<id>/input`. On success, the daemon
    /// writes the bytes into the wrapper's unix socket, which the `cc` PTY
    /// forwards as keystrokes into the underlying child process.
    func injectInput(sessionId: String, text: String) async {
        var req = URLRequest(url: endpoint("/sessions/\(sessionId)/input"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.injectStatus = "inject failed: HTTP \(http.statusCode)"
            } else {
                self.injectStatus = nil
            }
        } catch {
            self.injectStatus = "inject error: \(error.localizedDescription)"
        }
    }

    /// Respond to a fixed 3-choice prompt (Permission / PlanApproval) by
    /// injecting the numeric shortcut + CR. `choice` is 1-based: 1=Yes,
    /// 2=Yes-always (or 2nd plan mode), 3=No (or 3rd plan mode).
    func respondToPrompt(id: String, choice: Int) async {
        guard (1...9).contains(choice) else { return }
        await injectInput(sessionId: id, text: "\(choice)\r")
    }

    /// Answer an AskUserQuestion by sending the selected option labels as
    /// free text. For single-select: one label. For multi-select: labels
    /// joined by ", ". Falls back via `submitFreeText` if the user typed
    /// something custom.
    func answerQuestion(id: String, selections: [String]) async {
        guard !selections.isEmpty else { return }
        let joined = selections.joined(separator: ", ")
        await injectInput(sessionId: id, text: "\(joined)\r")
    }

    /// Send arbitrary free-text as the answer to whatever prompt is live.
    /// Used both by the AskUserQuestion "Other" field and by generic
    /// elicitation dialogs where we only have a raw message.
    func submitFreeText(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await injectInput(sessionId: id, text: "\(trimmed)\r")
    }

    /// SIGTERM the wrapper process backing `sessionId`. Daemon escalates to
    /// SIGKILL after 3s. Only valid for wrapper-backed sessions — the HUD
    /// already guards this at the UI level.
    func terminateSession(id: String) async {
        var req = URLRequest(url: endpoint("/sessions/\(id)/terminate"))
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.lastError = "terminate failed: HTTP \(http.statusCode)"
                return
            }
            if self.selectedId == id {
                self.selectedId = nil
            }
            await refresh()
        } catch {
            self.lastError = "terminate error: \(error.localizedDescription)"
        }
    }

    /// Relaunch the currently selected native (non-wrapper) session as a
    /// ccw-wrapped one by asking Terminal.app / iTerm to open a new window
    /// running `ccw <name>` in the same cwd. The original native process
    /// keeps running — the user can close it from its own terminal — but
    /// a fresh wrapper-backed session will replace it in the HUD list as
    /// soon as its SessionStart hook fires.
    func relaunchSelectedAsCcw() {
        guard let sid = selectedId,
              let s = sessions.first(where: { $0.id == sid }) else { return }
        guard s.wrapperId == nil else { return }
        guard let cwd = s.cwd, !cwd.isEmpty else {
            self.injectStatus = "relaunch: unknown cwd"
            return
        }
        if let err = TerminalFocus.launchNewSession(
            flavor: .ccw,
            mode: .defaultMode,
            name: s.name,
            cwd: cwd
        ) {
            self.injectStatus = "relaunch failed: \(err)"
        } else {
            self.injectStatus = "relaunching as ccw…"
        }
    }

    /// Sessions the user could bulk-forget right now — native (hook-only,
    /// `wrapperId == nil`) and quiet for > 1h. Drives the badge on the
    /// "Forget stale RO" settings button.
    var staleNativeSessions: [SessionSummary] {
        let cutoff: TimeInterval = 3600
        let now = Date()
        return sessions.filter { s in
            s.wrapperId == nil && now.timeIntervalSince(s.lastEventAt) > cutoff
        }
    }

    /// Bulk-DELETE every session in `staleNativeSessions` in parallel, then
    /// refresh once at the end. Errors per-request are swallowed (any survivor
    /// will show up on the refreshed list).
    func forgetStaleNative() async {
        let targets = staleNativeSessions.map(\.id)
        guard !targets.isEmpty else {
            self.injectStatus = "no stale RO sessions to forget"
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for id in targets {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var req = URLRequest(url: await self.endpoint("/sessions/\(id)"))
                    req.httpMethod = "DELETE"
                    req.timeoutInterval = 2
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
        if let sid = self.selectedId, targets.contains(sid) {
            self.selectedId = nil
        }
        await refresh()
        self.injectStatus = "forgot \(targets.count) stale RO session\(targets.count == 1 ? "" : "s")"
    }

    /// Drop the session from the daemon's in-memory registry without killing
    /// anything. Useful for hook-only sessions (native `claude`) the user just
    /// wants off the HUD list.
    func forgetSession(id: String) async {
        var req = URLRequest(url: endpoint("/sessions/\(id)"))
        req.httpMethod = "DELETE"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.lastError = "forget failed: HTTP \(http.statusCode)"
                return
            }
            if self.selectedId == id {
                self.selectedId = nil
            }
            await refresh()
        } catch {
            self.lastError = "forget error: \(error.localizedDescription)"
        }
    }
}

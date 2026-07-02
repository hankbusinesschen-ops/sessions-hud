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
    @Published var connectionState: ConnectionState = .connecting
    /// Row the user has expanded to see the inline detail preview, or nil.
    @Published var selectedId: String?
    @Published var runtimeDiagnostics: [RuntimeDiagnostic] = []

    private let notifier = Notifier()
    private var healthTimer: Timer?
    private var events: EventStreamClient?

    private let daemonBase: URL = {
        let fallback = URL(string: "http://127.0.0.1:39501")!
        guard let raw = ProcessInfo.processInfo.environment["SESSIONSD_URL"] else { return fallback }
        return URL(string: raw) ?? fallback
    }()
    /// `path` is relative, without a leading slash: "sessions", "health", …
    private func endpoint(_ path: String) -> URL {
        daemonBase.appendingPathComponent(path)
    }

    deinit {
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

    func start() {
        // /health poll — SSE can wedge on sleep/wake, so treat HTTP as ground truth.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkHealth() }
        }
        Task { await refresh() }
        Task { await checkHealth() }
        updateRuntimeDiagnostics()

        let client = EventStreamClient(url: endpoint("events"))
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
                onEvent: { _ in
                    await owner?.refresh()
                }
            )
        }
    }

    private func onSseConnected() async {
        setConnectionState(.connected)
        await refresh()
    }

    private func setConnectionState(_ state: ConnectionState) {
        guard self.connectionState != state else { return }
        self.connectionState = state
        updateRuntimeDiagnostics()
    }

    private func checkHealth() async {
        var req = URLRequest(url: endpoint("health"))
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

    func refresh() async {
        do {
            var req = URLRequest(url: endpoint("sessions"))
            req.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: req)
            // Sort on (sortPriority, lastEventAt desc) so pending prompts
            // float above everything else.
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
            if let sid = self.selectedId, !list.contains(where: { $0.id == sid }) {
                self.selectedId = nil
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

    /// Sessions not in the Attention Bar — drives the grouped / flat list below.
    var routineSessions: [SessionSummary] {
        sessions.filter { !$0.needsAttention }
    }

    /// How many sessions are blocking on the user right now. Drives the
    /// menu-bar badge and the Cmd+J jump shortcut.
    var attentionCount: Int { attentionSessions.count }

    /// Expand the next (or previous) session that `needsAttention`. Wraps at
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

    /// Recompute local + daemon diagnostic rows (hooks, statusline).
    func updateRuntimeDiagnostics() {
        var items: [RuntimeDiagnostic] = []
        let (daemonOk, daemonDetail): (Bool, String) = {
            switch connectionState {
            case .connected:
                return (true, "HTTP /health 正常")
            case .connecting:
                return (true, "連線中…")
            case .disconnected:
                return (false, "未連線 — 確認 launchd 或執行 scripts/check-sessions-hud-runtime.sh")
            }
        }()
        items.append(
            RuntimeDiagnostic(
                id: "daemon",
                ok: daemonOk,
                label: "sessionsd (39501)",
                detail: daemonDetail
            )
        )
        items.append(contentsOf: RuntimeDiagnostics.gatherFileBasedChecks())
        if runtimeDiagnostics != items {
            runtimeDiagnostics = items
        }
    }

    /// Sessions quiet for > 1h — candidates for the bulk-forget button in
    /// settings. Never includes sessions that are running or waiting on the
    /// user: a 70-minute-old permission prompt is exactly what the HUD exists
    /// to surface, not something to sweep away. (Automatic sweeping arrives
    /// with the local store.)
    var staleSessions: [SessionSummary] {
        let cutoff: TimeInterval = 3600
        let now = Date()
        return sessions.filter { s in
            !s.needsAttention
                && s.status != .running
                && now.timeIntervalSince(s.lastEventAt) > cutoff
        }
    }

    /// Bulk-DELETE every session in `staleSessions` in parallel, then refresh
    /// once at the end. Errors per-request are swallowed (any survivor will
    /// show up on the refreshed list).
    func forgetStale() async {
        let targets = staleSessions.map(\.id)
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in targets {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var req = URLRequest(url: await self.endpoint("sessions/\(id)"))
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
    }

    /// Drop the session from the list without killing anything. The
    /// underlying claude process keeps running.
    func forgetSession(id: String) async {
        var req = URLRequest(url: endpoint("sessions/\(id)"))
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

import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var lastError: String?
    @Published var now: Date = Date()
    @Published var selectedId: String? {
        didSet {
            if selectedId == nil {
                selectedDetail = nil
                injectStatus = nil
            } else if selectedId != oldValue {
                // Clear any stale detail + error from the previous selection.
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
    private var events: EventStreamClient?
    private let url = URL(string: "http://127.0.0.1:39501/sessions")!
    private let daemonBase = "http://127.0.0.1:39501"

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
        // Relative-time label tick (independent of session updates so "2m ago"
        // still counts up when nothing is happening).
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task { await refresh() }

        let eventsURL = URL(string: "\(daemonBase)/events")!
        let client = EventStreamClient(url: eventsURL)
        events = client
        Task { [weak self] in
            // Capture once inside the Task so the closures below capture a
            // let (Sendable under Swift 6) instead of the mutable `self?`
            // reference that came in from the outer scope.
            let owner = self
            await client.start(
                onConnect: {
                    await owner?.refresh()
                    await owner?.refreshSelected()
                },
                onEvent: { ev in
                    await owner?.handleEvent(ev)
                }
            )
        }
    }

    private func handleEvent(_ ev: SseEvent) async {
        switch ev {
        case .sessionsChanged:
            await refresh()
            if selectedId != nil {
                await refreshSelected()
            }
        case .sessionUpdated(let id):
            if id == selectedId {
                await refreshSelected()
            }
            // Also refresh the list so status / last_event_at / pending_prompt
            // on the compact row flip in lockstep.
            await refresh()
        case .unknown:
            break
        }
    }

    func refresh() async {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: req)
            let list = try decoder.decode([SessionSummary].self, from: data)
            self.sessions = list
            self.notifier.observe(list)
            self.lastError = nil
        } catch {
            self.lastError = "daemon: \(error.localizedDescription)"
        }
    }

    /// Fetch the full session payload for the currently selected id so Mode B
    /// can render the message history. Called on selection change and on each
    /// poll tick while a row remains selected.
    func refreshSelected() async {
        guard let id = selectedId,
              let url = URL(string: "\(daemonBase)/sessions/\(id)") else {
            return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                // session disappeared — drop the detail but keep the selection
                // so the view can show a placeholder.
                self.selectedDetail = nil
                return
            }
            let detail = try decoder.decode(SessionDetail.self, from: data)
            // Avoid publishing an identical value to keep SwiftUI diffs cheap.
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
        guard let url = URL(string: "\(daemonBase)/sessions/\(sessionId)/input") else { return }
        var req = URLRequest(url: url)
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
        guard let url = URL(string: "\(daemonBase)/sessions/\(id)/terminate") else { return }
        var req = URLRequest(url: url)
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

    /// Drop the session from the daemon's in-memory registry without killing
    /// anything. Useful for hook-only sessions (native `claude`) the user just
    /// wants off the HUD list.
    func forgetSession(id: String) async {
        guard let url = URL(string: "\(daemonBase)/sessions/\(id)") else { return }
        var req = URLRequest(url: url)
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

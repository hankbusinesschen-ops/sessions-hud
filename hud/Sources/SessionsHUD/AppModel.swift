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
            } else if selectedId != oldValue {
                // Clear any stale detail from the previous selection.
                selectedDetail = nil
                Task { await refreshSelected() }
            }
        }
    }
    @Published var selectedDetail: SessionDetail?
    @Published var injectDraft: String = ""
    @Published var injectStatus: String?

    private var pollTimer: Timer?
    private var clockTimer: Timer?
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

    func start() {
        // poll daemon every 1s
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
                await self?.refreshSelected()
            }
        }
        // tick clock every 1s so relative times update even when sessions[] is unchanged
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            let (data, _) = try await URLSession.shared.data(for: req)
            let list = try decoder.decode([SessionSummary].self, from: data)
            self.sessions = list
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
}

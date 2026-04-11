import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var lastError: String?
    @Published var now: Date = Date()
    @Published var selectedId: String?
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
            Task { @MainActor in await self?.refresh() }
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

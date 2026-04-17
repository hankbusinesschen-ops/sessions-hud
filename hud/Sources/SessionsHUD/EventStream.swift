import Foundation

/// Cache-invalidation events pushed by sessionsd over `/events` SSE. See
/// `SseEvent` in `crates/sessionsd/src/main.rs` for the source definition —
/// the two must stay in sync.
enum SseEvent: Decodable {
    case sessionsChanged
    case sessionUpdated(id: String)
    case unknown

    private enum CodingKeys: String, CodingKey { case type, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "sessions_changed":
            self = .sessionsChanged
        case "session_updated":
            self = .sessionUpdated(id: try c.decode(String.self, forKey: .id))
        default:
            self = .unknown
        }
    }
}

/// Minimal SSE client over URLSession.bytes. Reconnects with exponential
/// backoff on drop; the caller is expected to refetch a snapshot after each
/// (re)connect via `onConnect` to reconcile any events missed during the
/// outage. We intentionally don't implement Last-Event-ID replay — the
/// daemon has no persistence and snapshot-on-reconnect is sufficient.
actor EventStreamClient {
    private let url: URL
    private var task: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start(
        onConnect: @escaping @Sendable () async -> Void,
        onDisconnect: @escaping @Sendable () async -> Void,
        onEvent: @escaping @Sendable (SseEvent) async -> Void
    ) {
        task?.cancel()
        let url = self.url
        task = Task {
            var backoff: UInt64 = 500_000_000 // 0.5s
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: url)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 3600
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    backoff = 500_000_000
                    await onConnect()

                    var dataBuf = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Dispatch accumulated event, if any.
                            if !dataBuf.isEmpty,
                               let d = dataBuf.data(using: .utf8),
                               let ev = try? JSONDecoder().decode(SseEvent.self, from: d) {
                                await onEvent(ev)
                            }
                            dataBuf = ""
                        } else if line.hasPrefix("data:") {
                            // "data:..." or "data: ..." — strip prefix + optional space
                            let rest = line.dropFirst(5)
                            let trimmed = rest.hasPrefix(" ")
                                ? String(rest.dropFirst())
                                : String(rest)
                            if !dataBuf.isEmpty { dataBuf += "\n" }
                            dataBuf += trimmed
                        }
                        // Ignore comments (":"), event:, id:, retry:.
                    }
                } catch {
                    // Fall through to backoff — could be daemon restart, NAT
                    // timeout, sleep/wake, anything.
                    await onDisconnect()
                }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 10_000_000_000) // cap 10s
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

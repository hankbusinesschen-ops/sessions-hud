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

/// Tracks the last time the SSE read loop saw any line on the wire. Lives in
/// its own actor so the read task and the idle-watchdog task can mutate /
/// observe it without racing.
fileprivate actor LineActivityBox {
    private var last = Date()
    func touch() { last = Date() }
    func elapsed() -> TimeInterval { Date().timeIntervalSince(last) }
}

fileprivate actor ConnectedFlag {
    private(set) var value = false
    func mark() { value = true }
}

/// Minimal SSE client over URLSession.bytes. Reconnects with exponential
/// backoff on drop; the caller is expected to refetch a snapshot after each
/// (re)connect via `onConnect` to reconcile any events missed during the
/// outage. We intentionally don't implement Last-Event-ID replay — the
/// daemon has no persistence and snapshot-on-reconnect is sufficient.
///
/// Connection liveness is tracked two ways:
///   1. URLSessionConfiguration.timeoutIntervalForRequest = 30s — aborts the
///      initial connect / header phase if the daemon doesn't answer.
///   2. An in-band idle watchdog that cancels the stream if no line (not even
///      a `:keep-alive` comment) arrives within 45s. sessionsd pings every
///      15s, so 45s = 3 missed beats.
/// We do NOT use URLSession.shared — a pooled session can hold a dead
/// connection open indefinitely across macOS sleep/wake.
actor EventStreamClient {
    private let url: URL
    private var task: Task<Void, Never>?
    private let session: URLSession

    init(url: URL) {
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = TimeInterval.infinity
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: cfg)
    }

    func start(
        onConnect: @escaping @Sendable () async -> Void,
        onDisconnect: @escaping @Sendable () async -> Void,
        onEvent: @escaping @Sendable (SseEvent) async -> Void
    ) {
        task?.cancel()
        let url = self.url
        let session = self.session
        task = Task {
            var backoff: UInt64 = 500_000_000 // 0.5s
            while !Task.isCancelled {
                // Only reset backoff after we verified the daemon is reachable
                // (onConnect fired). Bare throws before that keep escalating.
                let connected = ConnectedFlag()
                do {
                    try await Self.runConnection(
                        url: url,
                        session: session,
                        onConnect: {
                            await connected.mark()
                            await onConnect()
                        },
                        onEvent: onEvent
                    )
                } catch {}
                await onDisconnect()
                if await connected.value { backoff = 500_000_000 }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 10_000_000_000) // cap 10s
            }
        }
    }

    private static func runConnection(
        url: URL,
        session: URLSession,
        onConnect: @escaping @Sendable () async -> Void,
        onEvent: @escaping @Sendable (SseEvent) async -> Void
    ) async throws {
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        await onConnect()

        let activity = LineActivityBox()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var dataBuf = ""
                for try await line in bytes.lines {
                    await activity.touch()
                    if line.isEmpty {
                        if !dataBuf.isEmpty,
                           let d = dataBuf.data(using: .utf8),
                           let ev = try? JSONDecoder().decode(SseEvent.self, from: d) {
                            await onEvent(ev)
                        }
                        dataBuf = ""
                    } else if line.hasPrefix("data:") {
                        let rest = line.dropFirst(5)
                        let trimmed = rest.hasPrefix(" ")
                            ? String(rest.dropFirst())
                            : String(rest)
                        if !dataBuf.isEmpty { dataBuf += "\n" }
                        dataBuf += trimmed
                    }
                    // Non-data lines (comments, event:, id:, retry:) still count
                    // as activity via the touch() above.
                }
            }

            // Idle watchdog: 45s without any line == wedged (common after
            // macOS sleep/wake). Throw to bump the outer reconnect loop.
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if await activity.elapsed() > 45 {
                        throw URLError(.timedOut)
                    }
                }
            }

            // First child to finish (throw or return) wins; cancel the other.
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

import Foundation
import os

/// Watches the spool directory that hooks/post-event.sh writes into and
/// delivers decoded events in filename (= chronological) order.
///
/// File lifecycle: hook event files are deleted once ingested. Statusline
/// files (`statusline-<sid>.json`) are *state*, atomically overwritten by
/// the tee — they stay on disk so a fresh launch can replay the latest
/// quota, are re-ingested only when their mtime changes, and are removed
/// via `retainStatuslineFiles` once their session leaves the registry.
@MainActor
final class EventSpool {
    nonisolated static let defaultDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["SESSIONSHUD_SPOOL"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionsHUD/events", isDirectory: true)
    }()

    /// Files older than this are dropped unprocessed at launch.
    static let maxAge: TimeInterval = 24 * 3600
    /// Hard cap on backlog replay — beyond this the oldest files are dropped.
    static let maxBacklog = 5000

    private static let statuslinePrefix = "statusline-"
    private static let log = Logger(subsystem: "com.sessionshud.app", category: "spool")

    let directory: URL
    var onEvents: (([HookEvent]) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var drainScheduled = false
    /// mtime of each statusline file at last ingest, keyed by filename —
    /// unchanged state files are skipped instead of re-decoded every drain.
    private var statuslineMtimes: [String: Date] = [:]
    /// Wall-clock time of the most recent hook event ingest (statusline
    /// re-reads don't count) — surfaced in diagnostics ("are hooks feeding
    /// us at all?").
    private(set) var lastIngestAt: Date?
    /// Files that failed to decode since launch — surfaced in diagnostics so
    /// producer/consumer format drift is visible instead of silent.
    private(set) var decodeFailureCount = 0

    private let decoder = JSONDecoder()

    init(directory: URL = EventSpool.defaultDirectory) {
        self.directory = directory
    }

    /// Creates the directory, prunes stale backlog, replays what's left, and
    /// starts watching. Returns false when the directory can't be watched.
    @discardableResult
    func start() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        prune()
        drain()

        // The 3s poll runs regardless of the kqueue watch: it papers over
        // missed kqueue events across sleep/wake AND keeps ingestion working
        // (at poll latency) if the watch can't be established at all.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log.error("cannot open spool dir \(self.directory.path)")
            return FileManager.default.fileExists(atPath: directory.path)
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        src.setEventHandler { [weak self] in self?.scheduleDrain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    /// Statusline files persist until their session is forgotten or swept:
    /// drops every statusline file whose session id is not in `liveIds`.
    func retainStatuslineFiles(for liveIds: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.statuslinePrefix) && name.hasSuffix(".json") {
            let sid = String(name.dropFirst(Self.statuslinePrefix.count).dropLast(".json".count))
            if !liveIds.contains(sid) {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
                statuslineMtimes.removeValue(forKey: name)
            }
        }
    }

    /// Coalesce bursts of directory events into one drain per tick.
    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.drainScheduled = false
            self?.drain()
        }
    }

    func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }

        // Event files sort chronologically by name; statusline files are
        // absolute state so order among them doesn't matter.
        let visible = names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
        let eventFiles = visible.filter { !$0.hasPrefix(Self.statuslinePrefix) }.sorted()
        let statuslineFiles = visible.filter { $0.hasPrefix(Self.statuslinePrefix) }

        // Statusline state is applied BEFORE the chronological hook events:
        // if the same batch carries a SessionEnd, the removal must win —
        // otherwise a stale quota file resurrects the just-ended session as
        // a ghost row.
        var events: [HookEvent] = []
        for name in statuslineFiles {
            let url = directory.appendingPathComponent(name)
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let mtime, statuslineMtimes[name] == mtime { continue }
            if let ev = decodeFile(url) {
                events.append(ev)
                statuslineMtimes[name] = mtime ?? Date()
            } else {
                try? fm.removeItem(at: url) // undecodable state file is useless
                statuslineMtimes.removeValue(forKey: name)
            }
        }

        var sawHookEvent = false
        for name in eventFiles {
            let url = directory.appendingPathComponent(name)
            if let ev = decodeFile(url) {
                events.append(ev)
                sawHookEvent = true
            }
            // Consumed (or undecodable) event files never survive a drain.
            try? fm.removeItem(at: url)
        }
        if sawHookEvent {
            lastIngestAt = Date()
        }

        guard !events.isEmpty else { return }
        onEvents?(events)
    }

    private func decodeFile(_ url: URL) -> HookEvent? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let ev = try decoder.decode(HookEvent.self, from: data)
            guard ev.v == 1 else {
                Self.log.error("unsupported envelope v\(ev.v) in \(url.lastPathComponent)")
                return nil
            }
            return ev
        } catch {
            decodeFailureCount += 1
            Self.log.error("undecodable spool file \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Launch-time cleanup: cap the backlog and drop anything older than
    /// `maxAge` — a spool that sat for a day is history, not state.
    func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)

        var eventFiles: [String] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if name.hasPrefix(".") {
                // Orphaned tmp file — but only when demonstrably abandoned:
                // a fresh one belongs to an in-flight hook whose mv would
                // fail if we unlinked it out from under it.
                if let mtime, Date().timeIntervalSince(mtime) > 60 {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            if let mtime, mtime < cutoff {
                try? fm.removeItem(at: url)
                continue
            }
            if name.hasSuffix(".json") && !name.hasPrefix(Self.statuslinePrefix) {
                eventFiles.append(name)
            }
        }
        if eventFiles.count > Self.maxBacklog {
            for name in eventFiles.sorted().dropLast(Self.maxBacklog) {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

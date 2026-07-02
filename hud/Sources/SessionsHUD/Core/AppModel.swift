import AppKit
import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    /// Sorted for display: attention first, then by recency.
    @Published var sessions: [SessionSummary] = []
    /// Row the user has expanded to see the inline detail preview, or nil.
    @Published var selectedId: String?
    @Published var runtimeDiagnostics: [RuntimeDiagnostic] = []
    /// False when the spool directory couldn't be created/watched — the one
    /// fatal local failure mode, surfaced as a banner.
    @Published var spoolActive: Bool = true

    private let store = SessionStore()
    private let notifier = Notifier()
    private let spool = EventSpool()
    private var sweepTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var snapshotDebounce: DispatchWorkItem?
    /// Gates the notifier: transitions replayed from the launch backlog are
    /// history, not news — no sounds until startup is done.
    private var started = false

    private var snapshotURL: URL {
        spool.directory
            .deletingLastPathComponent()
            .appendingPathComponent("state.json")
    }

    deinit {
        sweepTimer?.invalidate()
    }

    func start() {
        spool.onEvents = { [weak self] events in
            self?.ingest(events)
        }

        // Order matters: restore the snapshot, replay the backlog (so a
        // session started while the app was closed is known), and only then
        // sweep — sweeping first would treat those sessions' statusline
        // files as orphans and delete their quota state.
        if let data = try? Data(contentsOf: snapshotURL) {
            store.loadSnapshot(data)
        }
        spoolActive = spool.start()
        sweepNow()
        publish()
        started = true
        notifier.observe(sessions) // seed silently — first observe never fires

        sweepTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepNow() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.spool.drain()
                self?.sweepNow()
            }
        }
        updateRuntimeDiagnostics()
    }

    private func ingest(_ events: [HookEvent]) {
        var changed = false
        var sessionEnded = false
        for ev in events {
            if store.apply(ev) { changed = true }
            if ev.event == "SessionEnd" { sessionEnded = true }
        }
        if sessionEnded {
            // The ended session's statusline file must go too, or its next
            // ingest would resurrect the session as a pid-less ghost row.
            spool.retainStatuslineFiles(for: Set(store.sessions.keys))
        }
        if changed {
            publish()
            scheduleSnapshot()
        }
    }

    private func sweepNow() {
        let pids = store.sessions.values.map(\.pid).filter { $0 > 0 }
        let alive = Liveness.aliveClaudePids(pids)
        if store.sweep(now: Date(), isAlive: { alive.contains($0) }) {
            spool.retainStatuslineFiles(for: Set(store.sessions.keys))
            publish()
            scheduleSnapshot()
        }
        // While something is red (onboarding visible), keep the checks live
        // so the panel flips green by itself once the user fixes it. Once
        // everything is green, stop paying the file-read cost every sweep —
        // the settings popover refreshes on demand.
        if runtimeDiagnostics.contains(where: { !$0.ok }) {
            updateRuntimeDiagnostics()
        }
    }

    /// Everything needed to monitor sessions is wired up. Drives the
    /// onboarding takeover in the content area.
    var integrationReady: Bool {
        runtimeDiagnostics.first(where: { $0.id == "hooks" })?.ok ?? true
    }

    /// One-click Claude Code integration from the onboarding panel — the
    /// same HooksInstaller the installer CLI uses. Returns an error message
    /// or nil on success.
    func installIntegration() -> String? {
        do {
            try HooksInstaller.install()
            updateRuntimeDiagnostics()
            return nil
        } catch {
            updateRuntimeDiagnostics()
            return error.localizedDescription
        }
    }

    private func publish() {
        let list = store.sessions.values.sorted { a, b in
            if a.sortPriority != b.sortPriority {
                return a.sortPriority < b.sortPriority
            }
            if a.lastEventAt != b.lastEventAt {
                return a.lastEventAt > b.lastEventAt
            }
            return a.id < b.id // stable tiebreak — no row-jumping on exact ties
        }
        if sessions != list {
            sessions = list
        }
        if let sid = selectedId, !list.contains(where: { $0.id == sid }) {
            selectedId = nil
        }
        if started {
            notifier.observe(list)
        }
    }

    /// Debounced state snapshot so a burst of events costs one disk write.
    private func scheduleSnapshot() {
        snapshotDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.writeSnapshot() }
        }
        snapshotDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func writeSnapshot() {
        guard let data = try? store.snapshotData() else { return }
        let url = snapshotURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Called on app quit: event files are consumed-and-deleted, so anything
    /// still inside the debounce window must be flushed or it's gone forever.
    func flushSnapshot() {
        snapshotDebounce?.cancel()
        guard let data = try? store.snapshotData() else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    // MARK: - Derived collections

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
    /// the ends. No-op when there's nothing waiting.
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

    // MARK: - User actions

    /// Drop the session from the list without killing anything. The
    /// underlying claude process keeps running; its next hook event re-adds it.
    func forgetSession(id: String) {
        if store.remove(id: id) {
            spool.retainStatuslineFiles(for: Set(store.sessions.keys))
            publish()
            scheduleSnapshot()
        }
    }

    /// Sessions quiet for > 1h — candidates for the bulk-forget button in
    /// settings. Never includes sessions that are running or waiting on the
    /// user: a 70-minute-old permission prompt is exactly what the HUD exists
    /// to surface, not something to sweep away.
    var staleSessions: [SessionSummary] {
        let cutoff: TimeInterval = 3600
        let now = Date()
        return sessions.filter { s in
            !s.needsAttention
                && s.status != .running
                && now.timeIntervalSince(s.lastEventAt) > cutoff
        }
    }

    func forgetStale() {
        for s in staleSessions {
            store.remove(id: s.id)
        }
        spool.retainStatuslineFiles(for: Set(store.sessions.keys))
        publish()
        scheduleSnapshot()
    }

    // MARK: - Diagnostics

    func updateRuntimeDiagnostics() {
        var items: [RuntimeDiagnostic] = []
        let spoolDetail: String
        if !spoolActive {
            spoolDetail = "無法建立/監看 spool 目錄"
        } else if let last = spool.lastIngestAt {
            spoolDetail = "最近 hook 事件 \(Int(Date().timeIntervalSince(last)))s 前"
        } else {
            spoolDetail = "監看中，尚未收到 hook 事件"
        }
        items.append(
            RuntimeDiagnostic(
                id: "spool",
                ok: spoolActive && spool.decodeFailureCount == 0,
                label: "事件資料夾",
                detail: spool.decodeFailureCount > 0
                    ? "\(spoolDetail)；\(spool.decodeFailureCount) 個檔案無法解碼（格式不符）"
                    : spoolDetail
            )
        )
        items.append(contentsOf: RuntimeDiagnostics.gatherFileBasedChecks())
        if runtimeDiagnostics != items {
            runtimeDiagnostics = items
        }
    }
}

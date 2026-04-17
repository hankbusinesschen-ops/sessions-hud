import SwiftUI
import AppKit
import MarkdownUI

/// Root view — routes between Mode A (compact list) and Mode B (chat).
struct SessionListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.selectedId == nil {
                CompactListView()
            } else {
                ChatView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Mode A: compact list

struct CompactListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLauncher: Bool = false
    @State private var showSettings: Bool = false
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if model.connectionState == .disconnected {
                disconnectedBanner
                Divider().opacity(0.3)
            }
            content
            if let err = model.lastError {
                Divider().opacity(0.3)
                Text(err)
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .background(
            ZStack {
                Button("") { showLauncher = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("") { model.jumpToAttention(forward: true) }
                    .keyboardShortcut("j", modifiers: .command)
                Button("") { model.jumpToAttention(forward: false) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            .hidden()
        )
    }

    private var disconnectedBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("sessionsd 未連線")
                .font(.system(size: 10 * uiScale))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private var connectionDotColor: Color {
        switch model.connectionState {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return .red
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 7, height: 7)
                .help(model.connectionState == .connected ? "daemon 已連線"
                    : model.connectionState == .connecting ? "正在連線…"
                    : "daemon 未連線")
            Text("Sessions")
                .font(.system(size: 12 * uiScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(model.sessions.count))")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                showLauncher = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Launch new session")
            .popover(isPresented: $showLauncher, arrowEdge: .top) {
                LauncherPopover(isPresented: $showLauncher)
                    .environmentObject(model)
            }
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                SettingsPopover(isPresented: $showSettings)
            }
            Button {
                NSLog("HUD: compact quit button tapped")
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Sessions HUD")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.sessions.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if model.connectionState == .disconnected {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("無法連線到 sessionsd")
                        .font(.system(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("請確認 daemon 是否啟動")
                        .font(.system(size: 10 * uiScale))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("尚無工作階段")
                        .font(.system(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("點擊 + 啟動，或在終端機執行 ccw <name>")
                        .font(.system(size: 10 * uiScale))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            // Tier 0 attention bar stays pinned above the scroll region so
            // pending-prompt sessions never scroll out of sight. Tier 1 list
            // (grouped when many sessions, flat when ≤6) lives below.
            VStack(spacing: 0) {
                if !model.attentionSessions.isEmpty {
                    attentionSectionView
                    Divider().opacity(0.3)
                }
                if model.routineSessions.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    routineScrollView
                }
            }
        }
    }

    /// Tier 0 Attention Bar: cross-group pinned rows for any session with a
    /// pending prompt or needs_approval status. Header + amber-tinted rows.
    private var attentionSectionView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                Text("NEEDS ATTENTION")
                    .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                Text("(\(model.attentionSessions.count))")
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.06))
            ForEach(model.attentionSessions) { session in
                rowView(session, attentionStyle: true)
                Divider().opacity(0.15)
            }
        }
    }

    private var routineScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: useFlatLayout ? [] : [.sectionHeaders]) {
                if useFlatLayout {
                    ForEach(model.routineSessions) { session in
                        rowView(session)
                        Divider().opacity(0.15)
                    }
                } else {
                    ForEach(groupedRoutineSessions, id: \.label) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                rowView(session)
                                Divider().opacity(0.15)
                            }
                        } header: {
                            groupHeader(group.label)
                        }
                    }
                }
            }
        }
    }

    /// One row with shared tap + context-menu wiring. Used by both the
    /// Attention Bar and the routine list so behavior stays identical.
    @ViewBuilder
    private func rowView(_ session: SessionSummary, attentionStyle: Bool = false) -> some View {
        SessionRow(
            session: session,
            now: model.now,
            selected: false,
            attentionStyle: attentionStyle,
            onClose: { confirmAndClose(session) }
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedId = session.id }
        .contextMenu {
            Button("Forget session") {
                Task { await model.forgetSession(id: session.id) }
            }
            Button("Terminate (SIGTERM)") {
                confirmAndTerminate(session)
            }
            .disabled(session.wrapperId == nil)
        }
    }

    private func groupHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10 * uiScale, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    /// Auto-flatten when the routine list is small enough that repo group
    /// headers would be pure overhead. Threshold picked to fit comfortably
    /// in a small HUD window without scrolling.
    private var useFlatLayout: Bool {
        model.routineSessions.count <= 6
    }

    private var groupedRoutineSessions: [SessionGroup] {
        SessionGroup.group(model.routineSessions)
    }

    /// Row-level close button: picks terminate vs forget based on whether
    /// the session has a wrapper, and confirms first.
    private func confirmAndClose(_ session: SessionSummary) {
        let alert = NSAlert()
        let isLive = session.wrapperId != nil && session.status != .exited
        if isLive {
            alert.messageText = "Terminate “\(session.name)”?"
            alert.informativeText = "Sends SIGTERM to the ccw/cxw wrapper. Daemon escalates to SIGKILL after 3 seconds."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Terminate")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await model.terminateSession(id: session.id) }
            }
        } else {
            alert.messageText = "Forget “\(session.name)”?"
            alert.informativeText = "Removes this session from the HUD list. The underlying claude process keeps running."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await model.forgetSession(id: session.id) }
            }
        }
    }

    private func confirmAndTerminate(_ session: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Terminate “\(session.name)”?"
        alert.informativeText = "Sends SIGTERM to the ccw/cxw wrapper process. If it doesn't exit within 3 seconds, the daemon will escalate to SIGKILL."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.terminateSession(id: session.id) }
        }
    }
}

/// Compact-list grouping by repo root. We walk up from each session's cwd
/// until we find a directory containing `.git` (file or dir, so submodules /
/// worktrees both work) and use that directory's basename as the group label.
/// Sessions without a cwd — or whose cwd isn't inside any git repo — fall
/// into a `"~"` bucket so they still show up.
struct SessionGroup {
    let label: String
    let sessions: [SessionSummary]

    static func group(_ sessions: [SessionSummary]) -> [SessionGroup] {
        var buckets: [(String, [SessionSummary])] = []
        for s in sessions {
            let key = RepoRoot.label(for: s.cwd)
            if let idx = buckets.firstIndex(where: { $0.0 == key }) {
                buckets[idx].1.append(s)
            } else {
                buckets.append((key, [s]))
            }
        }
        return buckets.map { SessionGroup(label: $0.0, sessions: $0.1) }
    }
}

/// Attention-aware status indicator. Replaces the emoji icon in the compact
/// list. Pulses softly when the session is blocking on user input, fades when
/// a running session has been quiet for >30s, and stays solid otherwise. The
/// exact color/animation table lives in `color` + `body` below.
struct StatusDot: View {
    let status: SessionSummary.Status
    let needsAttention: Bool
    let lastEventAt: Date
    let now: Date
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let amber   = Color(red: 0.96, green: 0.62, blue: 0.04)
    private static let green   = Color(red: 0.08, green: 0.72, blue: 0.46)
    private static let dimGreen = Color(red: 0.30, green: 0.55, blue: 0.42)
    private static let bright  = Color(red: 0.16, green: 0.80, blue: 0.40)
    private static let gray    = Color(red: 0.55, green: 0.58, blue: 0.60)
    private static let red     = Color(red: 0.86, green: 0.20, blue: 0.18)

    var body: some View {
        if needsAttention && !reduceMotion {
            // TimelineView drives a continuous sine pulse from wall-clock time.
            // All attention dots across the list pulse in phase — cheaper than
            // per-view animation state and avoids the repeatForever-doesn't-
            // cancel quirk in SwiftUI.
            TimelineView(.animation) { context in
                dot.opacity(pulseOpacity(at: context.date))
            }
        } else {
            dot.opacity(staticOpacity)
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private func pulseOpacity(at date: Date) -> Double {
        let cycle = 1.5
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle) / cycle
        let sine = sin(phase * 2 * .pi)            // -1..1
        return 0.55 + 0.225 * (sine + 1)           // 0.55..1.0
    }

    private var staticOpacity: Double {
        isRunningStale ? 0.5 : 1.0
    }

    private var isRunningStale: Bool {
        status == .running && now.timeIntervalSince(lastEventAt) > 30
    }

    private var color: Color {
        if needsAttention { return Self.amber }
        switch status {
        case .running:       return isRunningStale ? Self.dimGreen : Self.green
        case .idle:          return Self.gray
        case .done:
            return now.timeIntervalSince(lastEventAt) < 5 ? Self.bright : Self.gray
        case .exited:        return Self.red
        case .needsApproval: return Self.amber
        case .unknown:       return Self.gray
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let now: Date
    let selected: Bool
    var attentionStyle: Bool = false
    var onClose: (() -> Void)? = nil
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    private static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)

    var body: some View {
        HStack(spacing: 0) {
            // 3pt amber bar on the left marks the attention-bar row. Flush to
            // the window edge so it reads as a single visual anchor.
            if attentionStyle {
                Rectangle()
                    .fill(Self.amber)
                    .frame(width: 3)
            }
            HStack(alignment: .center, spacing: 8) {
                StatusDot(
                    status: session.status,
                    needsAttention: session.needsAttention,
                    lastEventAt: session.lastEventAt,
                    now: now,
                    size: 8 * uiScale
                )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 12 * uiScale, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(rightLabel)
                            .font(.system(size: 10 * uiScale, design: .monospaced))
                            .foregroundStyle(rightLabelColor)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let cwd = session.cwd {
                            Text(shortenedPath(cwd))
                                .font(.system(size: 9 * uiScale))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if let chip = activityChip {
                            ActivityChipView(icon: chip.icon, label: chip.label, scale: uiScale)
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 4)
                        if session.wrapperId != nil {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .help("injectable — launched via ccw/cxw")
                        } else {
                            Text("RO")
                                .font(.system(size: 8 * uiScale, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.orange.opacity(0.6), lineWidth: 1)
                                )
                                .help("read-only — native claude, approvals disabled")
                        }
                    }
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(session.wrapperId != nil
                          ? "Terminate (SIGTERM wrapper)"
                          : "Forget session (remove from list)")
                }
            }
            .padding(.leading, attentionStyle ? 9 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
        }
        .background(rowBackground)
    }

    private var rowBackground: Color {
        if selected { return Color.accentColor.opacity(0.18) }
        if attentionStyle { return Color.orange.opacity(0.08) }
        return Color.clear
    }

    private var rightLabelColor: Color {
        if session.needsAttention { return Self.amber }
        if session.status == .exited { return Color.red.opacity(0.75) }
        // Threshold-color ctx% when it's the displayed label so runaway
        // context usage pops on the list without needing the hover popover.
        if showsCtx, let pct = session.stats?.ctxPct {
            return StatsLine.color(for: pct)
        }
        return .secondary
    }

    /// True when the right label will render ctx%. Mirrors the logic in
    /// `rightLabel`; kept in sync so `rightLabelColor` can threshold-color it.
    private var showsCtx: Bool {
        guard session.pendingPrompt == nil else { return false }
        guard session.status == .running || session.status == .idle else { return false }
        let elapsed = now.timeIntervalSince(session.lastEventAt)
        if elapsed > 30 { return false }        // stale -> show elapsed instead
        return session.stats?.ctxPct != nil
    }

    /// Smart right-side label. Priority: pending prompt summary > status-specific
    /// label. For running/idle, shows ctx% when fresh + stats available, else
    /// elapsed time (so a stale session always tells you how long it's been).
    private var rightLabel: String {
        if let prompt = session.pendingPrompt {
            switch prompt {
            case .permission(let m):      return promptShort(m)
            case .planApproval:           return "plan approval"
            case .question:               return "question"
            case .raw:                    return "prompt"
            }
        }
        switch session.status {
        case .needsApproval:
            return "needs OK"
        case .running, .idle:
            let elapsed = now.timeIntervalSince(session.lastEventAt)
            if elapsed > 30 {
                return "⏱ \(formatElapsed(elapsed))"
            }
            if let pct = session.stats?.ctxPct {
                return "ctx \(Int(pct.rounded()))%"
            }
            return "⏱ \(formatElapsed(elapsed))"
        case .done:
            return "done"
        case .exited:
            return "exited"
        case .unknown:
            return ""
        }
    }

    /// Reduce "Claude needs your permission to use Bash" → "needs Bash".
    private func promptShort(_ message: String) -> String {
        if let range = message.range(of: "to use ") {
            let tool = message[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "needs \(tool)"
        }
        return "needs OK"
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 3600 {
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
    }

    private func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The activity chip to render on the second row, or nil. Drops to nil
    /// once `since` is older than 5 minutes — treats the daemon's last known
    /// activity as stale so a missing PostToolUse doesn't leave a phantom
    /// chip plastered on a since-idle session. Appended age string (`12s`,
    /// `2m`) only when > 5s so quick tools don't flicker a timer.
    fileprivate var activityChip: (icon: String, label: String)? {
        guard let act = session.currentActivity else { return nil }
        let elapsed = now.timeIntervalSince(act.since)
        if elapsed > 300 { return nil }
        let age = elapsed > 5 ? " \(formatBriefAge(elapsed))" : ""
        switch act {
        case .tool(let name, _):
            return ("gearshape", name + age)
        case .subagent(let name, _):
            return ("sparkles", (name ?? "agent") + age)
        case .compacting:
            return ("rectangle.compress.vertical", "compacting" + age)
        }
    }

    private func formatBriefAge(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m"
    }
}

/// Small rounded chip showing "icon label" on the second row of SessionRow.
/// Deliberately muted — must never outshout the status dot.
private struct ActivityChipView: View {
    let icon: String
    let label: String
    let scale: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9 * scale))
            Text(label)
                .font(.system(size: 9 * scale, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.22))
        )
    }
}

// MARK: - Mode B: chat view

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings: Bool = false
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    private var selectedSummary: SessionSummary? {
        guard let id = model.selectedId else { return nil }
        return model.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let s = selectedSummary, s.wrapperId == nil, s.status != .exited {
                readOnlyBanner
                Divider().opacity(0.3)
            }
            if let prompt = selectedSummary?.pendingPrompt, let sid = model.selectedId {
                PromptBanner(
                    prompt: prompt,
                    sessionId: sid,
                    canInject: canInject
                )
                .environmentObject(model)
                Divider().opacity(0.3)
            }
            messageList
            Divider().opacity(0.3)
            injectBar
            if let s = model.injectStatus {
                Text(s)
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
        .onExitCommand { model.selectedId = nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.selectedId = nil
                model.injectDraft = ""
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Back to list")

            if let s = selectedSummary {
                StatusDot(
                    status: s.status,
                    needsAttention: s.needsAttention,
                    lastEventAt: s.lastEventAt,
                    now: model.now,
                    size: 10 * uiScale
                )
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 10 * uiScale, height: 10 * uiScale)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(selectedSummary?.name ?? model.selectedId ?? "")
                    .font(.system(size: 13 * uiScale, weight: .semibold))
                    .lineLimit(1)
                if let cwd = selectedSummary?.cwd {
                    Text(cwd)
                        .font(.system(size: 10 * uiScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(selectedSummary?.status.label ?? "")
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let stats = selectedSummary?.stats, stats.hasAnyPct || stats.modelDisplay != nil {
                    StatsLine(stats: stats, fontSize: 10)
                }
            }

            Button {
                TerminalFocus.openInTerminal(
                    tty: model.selectedDetail?.tty,
                    termProgram: model.selectedDetail?.termProgram
                )
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled((model.selectedDetail?.tty ?? "").isEmpty)
            .help("Open in terminal")

            Button {
                confirmAndEnd()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(selectedSummary?.wrapperId != nil
                  ? "Terminate (SIGTERM wrapper)"
                  : "Forget session (remove from list)")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                SettingsPopover(isPresented: $showSettings)
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Sessions HUD")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var messageList: some View {
        if let detail = model.selectedDetail {
            if detail.messages.isEmpty {
                emptyState("no messages yet")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(detail.messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            // Anchor at the bottom so we can scrollTo() after updates.
                            Color.clear
                                .frame(height: 1)
                                .id("__bottom__")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: detail.messages.count) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        } else {
            emptyState("loading…")
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canInject: Bool {
        selectedSummary?.wrapperId != nil
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Read-only session")
                    .font(.system(size: 11 * uiScale, weight: .semibold))
                Text("Native claude — approvals and input disabled. Relaunch via ccw to enable them.")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Relaunch as ccw") {
                model.relaunchSelectedAsCcw()
            }
            .font(.system(size: 11 * uiScale))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled((selectedSummary?.cwd ?? "").isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private var injectBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("type a reply…", text: $model.injectDraft, onCommit: send)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12 * uiScale))
                    .disabled(!canInject)
                Button("Send ⏎", action: send)
                    .font(.system(size: 11 * uiScale))
                    .disabled(!canInject || model.injectDraft.isEmpty || model.selectedId == nil)
            }
            if !canInject {
                Text("read-only — launch this session via ccw to enable input")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func send() {
        guard let id = model.selectedId else { return }
        let text = model.injectDraft + "\r"
        let sid = id
        // Clearing injectDraft synchronously here doesn't actually blank the
        // TextField on macOS — onCommit fires inside the field's own edit
        // cycle, so the binding update gets overwritten. Deferring one tick
        // lets the field settle first.
        DispatchQueue.main.async {
            model.injectDraft = ""
        }
        Task { await model.injectInput(sessionId: sid, text: text) }
    }

    private func confirmAndEnd() {
        guard let s = selectedSummary else { return }
        let alert = NSAlert()
        if s.wrapperId != nil {
            alert.messageText = "Terminate “\(s.name)”?"
            alert.informativeText = "Sends SIGTERM to the ccw/cxw wrapper. If it doesn't exit within 3 seconds, the daemon will escalate to SIGKILL."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Terminate")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await model.terminateSession(id: s.id) }
            }
        } else {
            alert.messageText = "Forget “\(s.name)”?"
            alert.informativeText = "Removes this session from the HUD list. The underlying claude process keeps running."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await model.forgetSession(id: s.id) }
            }
        }
    }
}

struct MessageBubble: View {
    let message: SessionMessage
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.system(size: 10 * uiScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(roleColor)
                if message.kind != "text" {
                    Text(kindLabel)
                        .font(.system(size: 9 * uiScale, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            bodyView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Render assistant / user text as Markdown so code fences, lists, and
    /// inline code look right. Tool-use / tool-result blocks stay monospaced
    /// so we don't accidentally interpret their contents (often raw shell
    /// output or JSON) as markdown.
    @ViewBuilder
    private var bodyView: some View {
        if message.kind == "text" {
            Markdown(message.text)
                .markdownTextStyle {
                    FontSize(12)
                }
                .markdownTextStyle(\.code) {
                    FontFamilyVariant(.monospaced)
                    FontSize(11)
                    BackgroundColor(Color.gray.opacity(0.15))
                }
                .textSelection(.enabled)
        } else {
            Text(message.text)
                .font(.system(size: 11 * uiScale, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roleLabel: String {
        switch message.role {
        case "user":      return "USER"
        case "assistant": return "CLAUDE"
        default:          return message.role.uppercased()
        }
    }

    private var kindLabel: String {
        switch message.kind {
        case "tool_use":    return "· tool call"
        case "tool_result": return "· tool result"
        default:            return "· \(message.kind)"
        }
    }

    private var roleColor: Color {
        switch message.role {
        case "user":      return .blue
        case "assistant": return .purple
        default:          return .secondary
        }
    }

    private var bubbleBackground: Color {
        if message.kind == "tool_use" || message.kind == "tool_result" {
            return Color.gray.opacity(0.12)
        }
        switch message.role {
        case "user":      return Color.blue.opacity(0.10)
        case "assistant": return Color.purple.opacity(0.08)
        default:          return Color.gray.opacity(0.08)
        }
    }
}

// MARK: - Prompt banner

/// Yellow-tinted banner surfaced above the chat when Claude Code is blocked
/// on an interactive prompt. Renders differently based on the PendingPrompt
/// variant; all routes ultimately POST to /sessions/:id/input via AppModel.
struct PromptBanner: View {
    @EnvironmentObject var model: AppModel
    let prompt: PendingPrompt
    let sessionId: String
    let canInject: Bool
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prompt {
            case .permission(let message):
                permissionView(message: message)
            case .planApproval(let message):
                planApprovalView(message: message)
            case .question(_, let questions):
                // Render the first outstanding question. When claude chains
                // follow-ups, the daemon replaces `pending_prompt` and this
                // view refreshes automatically.
                if let q = questions.first {
                    QuestionView(
                        question: q,
                        sessionId: sessionId,
                        canInject: canInject
                    )
                    .environmentObject(model)
                }
            case .raw(let message):
                rawView(message: message)
            }
            if !canInject {
                Text("read-only — answer in terminal (launch via ccw to enable)")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private func permissionView(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("⚠")
            Text(message.isEmpty ? "Claude needs your permission" : message)
                .font(.system(size: 12 * uiScale, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            Button("Yes") { respond(1) }
            Button("Yes, don't ask again") { respond(2) }
            Button("No") { respond(3) }
        }
        .disabled(!canInject)
    }

    @ViewBuilder
    private func planApprovalView(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("📋")
            Text(message.isEmpty ? "Claude needs approval for the plan" : message)
                .font(.system(size: 12 * uiScale, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            Button("Yes, auto-accept edits") { respond(1) }
            Button("Yes, approve each edit") { respond(2) }
            Button("No, keep planning") { respond(3) }
        }
        .disabled(!canInject)
    }

    @ViewBuilder
    private func rawView(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("❓")
            Text(message.isEmpty ? "Claude is waiting for input" : message)
                .font(.system(size: 12 * uiScale))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func respond(_ choice: Int) {
        Task { await model.respondToPrompt(id: sessionId, choice: choice) }
    }
}

/// Renders a single AskUserQuestion — radio for single-select, checkbox for
/// multi-select, plus a free-text "Other" field. v1 injects the selected
/// labels as plain text (see plan Layer 3 note on label-text path).
struct QuestionView: View {
    @EnvironmentObject var model: AppModel
    let question: AskQuestion
    let sessionId: String
    let canInject: Bool

    @State private var selected: Set<String> = []
    @State private var freeText: String = ""
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("❓")
                VStack(alignment: .leading, spacing: 2) {
                    if !question.header.isEmpty {
                        Text(question.header)
                            .font(.system(size: 10 * uiScale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(question.question)
                        .font(.system(size: 12 * uiScale, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.label) { opt in
                    optionRow(opt)
                }
            }
            HStack(spacing: 6) {
                TextField("or type your answer…", text: $freeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11 * uiScale))
                    .disabled(!canInject)
                Button("Submit") { submit() }
                    .font(.system(size: 11 * uiScale))
                    .disabled(!canInject || (selected.isEmpty && freeText.isEmpty))
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ opt: AskOption) -> some View {
        Button {
            toggle(opt.label)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: iconName(for: opt.label))
                    .font(.system(size: 11))
                    .foregroundStyle(selected.contains(opt.label) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.label)
                        .font(.system(size: 12 * uiScale, weight: .medium))
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 10 * uiScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canInject)
    }

    private func iconName(for label: String) -> String {
        let on = selected.contains(label)
        if question.multiSelect {
            return on ? "checkmark.square.fill" : "square"
        } else {
            return on ? "largecircle.fill.circle" : "circle"
        }
    }

    private func toggle(_ label: String) {
        if question.multiSelect {
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
        } else {
            // Single-select: one tap sends immediately.
            selected = [label]
            Task {
                await model.answerQuestion(id: sessionId, selections: [label])
                await MainActor.run {
                    self.selected.removeAll()
                    self.freeText = ""
                }
            }
        }
    }

    private func submit() {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sid = sessionId
        let selections = Array(selected)
        let free = text
        Task {
            if !free.isEmpty {
                await model.submitFreeText(id: sid, text: free)
            } else if !selections.isEmpty {
                await model.answerQuestion(id: sid, selections: selections)
            }
            await MainActor.run {
                self.selected.removeAll()
                self.freeText = ""
            }
        }
    }
}

// MARK: - Stats line

/// Renders Claude Code quota snapshot (model · ctx% · 5h% · 7d%) as a
/// horizontal strip with per-segment threshold coloring. Used in both Mode A
/// row third line and Mode B header.
struct StatsLine: View {
    let stats: SessionStats
    let fontSize: CGFloat
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            if let m = stats.modelDisplay {
                Text(m).foregroundStyle(.secondary)
            }
            if let p = stats.ctxPct {
                Text("ctx \(Int(p.rounded()))%").foregroundStyle(Self.color(for: p))
            }
            if let p = stats.fiveHrPct {
                Text("5h \(Int(p.rounded()))%").foregroundStyle(Self.color(for: p))
            }
            if let p = stats.sevenDayPct {
                Text("7d \(Int(p.rounded()))%").foregroundStyle(Self.color(for: p))
            }
        }
        .font(.system(size: fontSize * uiScale, design: .monospaced))
        .lineLimit(1)
        .help(tooltip)
    }

    private var tooltip: String {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return "updated \(df.string(from: stats.updatedAt))"
    }

    static func color(for pct: Float) -> Color {
        if pct >= 80 { return .red }
        if pct >= 60 { return .orange }
        return .secondary
    }
}

extension SessionStats {
    var hasAnyPct: Bool {
        ctxPct != nil || fiveHrPct != nil || sevenDayPct != nil
    }
}

// MARK: - Launcher popover

/// Popover for spawning a new ccw/cxw session. Delegates the actual spawn to
/// TerminalFocus.launchNewSession, which asks Terminal.app (or iTerm2) to
/// open a new window running `cd <cwd> && ccw <name>`. The HUD picks up the
/// new session on the next 1s poll via sessionsd /register.
struct LauncherPopover: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var flavor: WrapperFlavor = .ccw
    @State private var mode: PermissionMode = .defaultMode
    @State private var name: String = ""
    @State private var cwd: String = ""
    @State private var errorMessage: String?
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New session")
                .font(.system(size: 13 * uiScale, weight: .semibold))

            Picker("Flavor", selection: $flavor) {
                ForEach(WrapperFlavor.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if flavor == .ccw {
                Picker("Mode", selection: $mode) {
                    ForEach(PermissionMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 6) {
                Text("Name")
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("session name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12 * uiScale))
            }

            HStack(spacing: 6) {
                Text("Dir")
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(cwd.isEmpty ? "— pick below —" : shortenedPath(cwd))
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundStyle(cwd.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.recentProjectRoots.isEmpty {
                Text("Recent")
                    .font(.system(size: 10 * uiScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.recentProjectRoots.prefix(6), id: \.self) { root in
                        Button {
                            selectCwd(root)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: cwd == root ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(cwd == root ? Color.accentColor : .secondary)
                                Text(shortenedPath(root))
                                    .font(.system(size: 11 * uiScale, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("Choose directory…") { chooseDirectory() }
                .font(.system(size: 11 * uiScale))

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") { launch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLaunch)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var canLaunch: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !cwd.isEmpty
    }

    /// Treat name as "auto-following cwd" when it matches the previous cwd's
    /// basename (or is blank). Once the user types something custom we leave
    /// it alone even across Recent reselects.
    private func selectCwd(_ path: String) {
        let previousAutoName = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        let nameIsAuto = name.isEmpty || name == previousAutoName
        cwd = path
        if nameIsAuto {
            name = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            selectCwd(url.path)
        }
    }

    private func launch() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !cwd.isEmpty else { return }
        if let err = TerminalFocus.launchNewSession(
            flavor: flavor,
            mode: mode,
            name: trimmedName,
            cwd: cwd
        ) {
            errorMessage = "launch failed: \(err)"
            return
        }
        isPresented = false
    }

    private func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Settings popover

struct SettingsPopover: View {
    @Binding var isPresented: Bool
    @AppStorage("uiFontScale") private var scale: Double = 1.0
    @AppStorage("showMenuBarBadge") private var showMenuBarBadge: Bool = true
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UI scale")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "%.2fx", scale))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $scale, in: 0.85...1.5, step: 0.05)
            Text("⌘+ / ⌘- / ⌘0 · ⌘J next waiting")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Divider()

            Toggle(isOn: $showMenuBarBadge) {
                Text("Show attention count in menu bar")
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .help("A small • N indicator appears when any session is waiting on you. Click it to raise the HUD.")

            Divider()

            let staleCount = model.staleNativeSessions.count
            Button {
                Task { await model.forgetStaleNative() }
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(staleCount > 0
                         ? "Forget \(staleCount) stale RO session\(staleCount == 1 ? "" : "s")"
                         : "No stale RO sessions")
                        .font(.system(size: 12))
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(staleCount == 0)
            .help("Drop native (read-only) sessions idle for >1h from the HUD list. Does not kill processes.")

            HStack {
                Button("Reset") { scale = 1.0 }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

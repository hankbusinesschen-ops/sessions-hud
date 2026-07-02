import SwiftUI
import AppKit

/// Root view: header + attention bar + grouped session list. Watch-only —
/// clicking a row expands an inline detail preview; answering prompts happens
/// in the terminal.
struct SessionListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings: Bool = false
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if !model.spoolActive {
                spoolFailureBanner
                Divider().opacity(0.3)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Button("") { model.jumpToAttention(forward: true) }
                    .keyboardShortcut("j", modifiers: .command)
                Button("") { model.jumpToAttention(forward: false) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            .hidden()
        )
        .onExitCommand { model.selectedId = nil }
    }

    private var spoolFailureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("無法監看事件資料夾")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.secondary)
            }
            Text("請開啟設定（齒輪）查看診斷。")
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.spoolActive ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .help(model.spoolActive ? "監看事件中" : "事件資料夾異常")
            Text("Sessions")
                .font(.system(size: 12 * uiScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(model.sessions.count))")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.tertiary)
            Spacer()
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
                    .environmentObject(model)
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
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if !model.integrationReady {
            OnboardingView()
        } else if model.sessions.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("尚無工作階段")
                    .font(.system(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("在任何終端機執行 claude 即會出現在這裡")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(Color.attentionAmber)
                Text("NEEDS ATTENTION")
                    .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.attentionAmber)
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

    /// One row with shared tap + context-menu wiring, plus the inline detail
    /// preview when expanded. Used by both the Attention Bar and the routine
    /// list so behavior stays identical.
    @ViewBuilder
    private func rowView(_ session: SessionSummary, attentionStyle: Bool = false) -> some View {
        VStack(spacing: 0) {
            SessionRow(
                session: session,
                expanded: model.selectedId == session.id,
                attentionStyle: attentionStyle,
                onClose: { confirmAndForget(session) }
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded(session.id) }
            if model.selectedId == session.id {
                SessionInlineDetail(session: session)
            }
        }
        .contextMenu {
            Button("Forget session") {
                model.forgetSession(id: session.id)
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.selectedId = model.selectedId == id ? nil : id
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

    private func confirmAndForget(_ session: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Forget “\(session.name)”?"
        alert.informativeText = "Removes this session from the HUD list. The underlying claude process keeps running."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.forgetSession(id: session.id)
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

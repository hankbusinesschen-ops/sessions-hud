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
        .background(.ultraThinMaterial)
    }
}

// MARK: - Mode A: compact list

struct CompactListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
            if let err = model.lastError {
                Divider().opacity(0.3)
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity,
               minHeight: 180, idealHeight: 260, maxHeight: .infinity,
               alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("(\(model.sessions.count))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
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
        if model.sessions.isEmpty {
            VStack {
                Spacer()
                Text("no sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedSessions, id: \.label) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, now: model.now, selected: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectedId = session.id
                                    }
                                    .contextMenu {
                                        Button("Forget session") {
                                            Task { await model.forgetSession(id: session.id) }
                                        }
                                        Button("Terminate (SIGTERM)") {
                                            confirmAndTerminate(session)
                                        }
                                        .disabled(session.wrapperId == nil)
                                    }
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

    private func groupHeader(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var groupedSessions: [SessionGroup] {
        SessionGroup.group(model.sessions)
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
            let key = repoRoot(for: s.cwd)
            if let idx = buckets.firstIndex(where: { $0.0 == key }) {
                buckets[idx].1.append(s)
            } else {
                buckets.append((key, [s]))
            }
        }
        return buckets.map { SessionGroup(label: $0.0, sessions: $0.1) }
    }

    private static func repoRoot(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "~" }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git").path
            if fm.fileExists(atPath: git) {
                return dir.lastPathComponent
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

struct SessionRow: View {
    let session: SessionSummary
    let now: Date
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(session.status.icon)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cwd = session.cwd {
                    Text(shortenedPath(cwd))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if session.wrapperId != nil {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("injectable — launched via ccw/cxw")
            }
            Text(rightLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var rightLabel: String {
        switch session.status {
        case .running, .idle:
            return "⏱ \(formatElapsed(now.timeIntervalSince(session.lastEventAt)))"
        case .needsApproval:
            return "needs OK"
        case .done:
            return "done"
        case .exited:
            return "exited"
        case .unknown:
            return ""
        }
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
}

// MARK: - Mode B: chat view

struct ChatView: View {
    @EnvironmentObject var model: AppModel

    private var selectedSummary: SessionSummary? {
        guard let id = model.selectedId else { return nil }
        return model.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            messageList
            Divider().opacity(0.3)
            injectBar
            if let s = model.injectStatus {
                Text(s)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 560, idealWidth: 560, maxWidth: .infinity,
               minHeight: 640, idealHeight: 640, maxHeight: .infinity,
               alignment: .top)
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

            Text(selectedSummary?.status.icon ?? "⚫")
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text(selectedSummary?.name ?? model.selectedId ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let cwd = selectedSummary?.cwd {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(selectedSummary?.status.label ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

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
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canInject: Bool {
        selectedSummary?.wrapperId != nil
    }

    @ViewBuilder
    private var injectBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("type a reply…", text: $model.injectDraft, onCommit: send)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(!canInject)
                Button("Send ⏎", action: send)
                    .font(.system(size: 11))
                    .disabled(!canInject || model.injectDraft.isEmpty || model.selectedId == nil)
            }
            if !canInject {
                Text("read-only — launch this session via ccw to enable input")
                    .font(.system(size: 10))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(roleLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(roleColor)
                if message.kind != "text" {
                    Text(kindLabel)
                        .font(.system(size: 9, design: .monospaced))
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
                .font(.system(size: 11, design: .monospaced))
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

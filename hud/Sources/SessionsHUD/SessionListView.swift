import SwiftUI
import AppKit

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
                LazyVStack(spacing: 0) {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session, now: model.now, selected: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedId = session.id
                            }
                        Divider().opacity(0.15)
                    }
                }
            }
        }
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

    private var injectBar: some View {
        HStack(spacing: 6) {
            TextField("type a reply…", text: $model.injectDraft, onCommit: send)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Button("Send ⏎", action: send)
                .font(.system(size: 11))
                .disabled(model.injectDraft.isEmpty || model.selectedId == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func send() {
        guard let id = model.selectedId else { return }
        let text = model.injectDraft + "\r"
        let sid = id
        model.injectDraft = ""
        Task { await model.injectInput(sessionId: sid, text: text) }
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
            Text(message.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

import SwiftUI
import AppKit

struct SessionListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
            if model.selectedId != nil {
                Divider().opacity(0.3)
                injectBar
            }
            if let err = model.lastError {
                Divider().opacity(0.3)
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if let s = model.injectStatus {
                Text(s)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
        .frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity,
               minHeight: 180, idealHeight: 320, maxHeight: .infinity,
               alignment: .top)
        .background(.ultraThinMaterial)
    }

    private var injectBar: some View {
        HStack(spacing: 6) {
            TextField("type to send…", text: $model.injectDraft, onCommit: send)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button("Send", action: send)
                .font(.system(size: 11))
                .disabled(model.injectDraft.isEmpty || model.selectedId == nil)
            Button {
                model.selectedId = nil
                model.injectDraft = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Close input")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func send() {
        guard let id = model.selectedId else { return }
        let text = model.injectDraft + "\r"
        let sid = id
        model.injectDraft = ""
        Task { await model.injectInput(sessionId: sid, text: text) }
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
                        SessionRow(session: session, now: model.now, selected: model.selectedId == session.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if model.selectedId == session.id {
                                    model.selectedId = nil
                                } else {
                                    model.selectedId = session.id
                                }
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

import SwiftUI

extension Color {
    /// Shared attention accent — dot pulse, attention bar, prompt labels.
    static let attentionAmber = Color(red: 0.96, green: 0.62, blue: 0.04)
}

/// Attention-aware status indicator. Pulses softly when the session is
/// blocking on user input, fades when a running session has been quiet for
/// >30s, and stays solid otherwise.
struct StatusDot: View {
    let status: SessionSummary.Status
    let needsAttention: Bool
    let lastEventAt: Date
    let now: Date
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if needsAttention { return .attentionAmber }
        switch status {
        case .running:       return isRunningStale ? Self.dimGreen : Self.green
        case .idle:          return Self.gray
        case .done:
            return now.timeIntervalSince(lastEventAt) < 5 ? Self.bright : Self.gray
        case .needsApproval: return .attentionAmber
        case .unknown:       return Self.gray
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary
    var expanded: Bool = false
    var attentionStyle: Bool = false
    var onClose: (() -> Void)? = nil
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        // Per-row 1s timeline so elapsed labels tick without invalidating the
        // whole window every second.
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        HStack(spacing: 0) {
            // 3pt amber bar on the left marks the attention-bar row. Flush to
            // the window edge so it reads as a single visual anchor.
            if attentionStyle {
                Rectangle()
                    .fill(Color.attentionAmber)
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
                        let label = rightLabel(now: now)
                        Text(label.text)
                            .font(.system(size: 10 * uiScale, design: .monospaced))
                            .foregroundStyle(label.color)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let cwd = session.cwd {
                            Text(PathFormat.shorten(cwd))
                                .font(.system(size: 9 * uiScale))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if let chip = activityChip(now: now) {
                            ActivityChipView(icon: chip.icon, label: chip.label, scale: uiScale)
                                .layoutPriority(1)
                        }
                        Spacer(minLength: 4)
                    }
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Forget session (remove from list)")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.leading, attentionStyle ? 9 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
        }
        .background(rowBackground)
    }

    private var rowBackground: Color {
        if expanded { return Color.accentColor.opacity(0.10) }
        if attentionStyle { return Color.orange.opacity(0.08) }
        return Color.clear
    }

    /// Smart right-side label with its color, decided in one place so text
    /// and color can never drift apart. Priority: pending prompt summary >
    /// status-specific label. For running/idle, shows ctx% when fresh + stats
    /// available, else elapsed time (so a stale session always tells you how
    /// long it's been).
    private func rightLabel(now: Date) -> (text: String, color: Color) {
        if let prompt = session.pendingPrompt {
            switch prompt {
            case .permission(let m):      return (promptShort(m), .attentionAmber)
            case .planApproval:           return ("plan approval", .attentionAmber)
            case .raw:                    return ("prompt", .attentionAmber)
            }
        }
        switch session.status {
        case .needsApproval:
            return ("needs OK", .attentionAmber)
        case .running, .idle:
            let elapsed = now.timeIntervalSince(session.lastEventAt)
            if elapsed <= 30, let pct = session.stats?.ctxPct {
                return ("ctx \(Int(pct.rounded()))%", StatsLine.color(for: pct))
            }
            return ("⏱ \(formatElapsed(elapsed))", .secondary)
        case .done:
            return ("done", .secondary)
        case .unknown:
            return ("", .secondary)
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

    /// The activity chip to render on the second row, or nil. Drops to nil
    /// once `since` is older than 5 minutes — treats the last known activity
    /// as stale so a missing PostToolUse doesn't leave a phantom chip
    /// plastered on a since-idle session. Appended age string (`12s`, `2m`)
    /// only when > 5s so quick tools don't flicker a timer.
    private func activityChip(now: Date) -> (icon: String, label: String)? {
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

/// Inline expansion under a tapped row: full status, cwd, pending prompt
/// text, and quota.
struct SessionInlineDetail: View {
    let session: SessionSummary
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.status.label)
                    .font(.system(size: 10 * uiScale, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let stats = session.stats, stats.hasAnyPct || stats.modelDisplay != nil {
                    StatsLine(stats: stats, fontSize: 10)
                }
                Spacer()
            }
            if let cwd = session.cwd {
                Text(cwd)
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            if let prompt = session.pendingPrompt {
                Text(prompt.message.isEmpty ? "Claude 正在等待你的回覆" : prompt.message)
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
    }
}

/// Small rounded chip showing "icon label" on the second row of SessionRow.
/// Deliberately muted — must never outshout the status dot.
struct ActivityChipView: View {
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

/// Renders Claude Code quota snapshot (model · ctx% · 5h% · 7d%) as a
/// horizontal strip with per-segment threshold coloring.
struct StatsLine: View {
    let stats: SessionStats
    let fontSize: CGFloat
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0

    private static let tooltipFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        return df
    }()

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
        .help("updated \(Self.tooltipFormatter.string(from: stats.updatedAt))")
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

/// Shared "~"-relative path shortening.
enum PathFormat {
    static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

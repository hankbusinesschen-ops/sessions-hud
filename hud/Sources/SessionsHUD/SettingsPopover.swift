import SwiftUI

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
            Text("⌘J next waiting · ⇧⌘J previous")
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

            HStack {
                Text("診斷 / Diagnostics")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("重新檢查") {
                    model.updateRuntimeDiagnostics()
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.runtimeDiagnostics) { row in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(row.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.system(size: 11, weight: .medium))
                            Text(row.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider()

            let staleCount = model.staleSessions.count
            Button {
                model.forgetStale()
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(staleCount > 0
                         ? "Forget \(staleCount) stale session\(staleCount == 1 ? "" : "s")"
                         : "No stale sessions")
                        .font(.system(size: 12))
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(staleCount == 0)
            .help("Drop sessions idle for >1h from the HUD list. Does not kill processes.")

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
        .frame(width: 300)
        .onAppear { model.updateRuntimeDiagnostics() }
    }
}

import SwiftUI

/// Takes over the content area until the Claude Code integration is wired
/// up: one prominent install button + live diagnostic rows. Flips back to
/// the session list automatically once the hooks check turns green.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("uiFontScale") private var uiScale: Double = 1.0
    @State private var installing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("歡迎使用 Sessions HUD")
                .font(.system(size: 14 * uiScale, weight: .semibold))
            Text("裝上 Claude Code hooks 之後，所有 claude session\n就會即時出現在這裡。")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                installing = true
                errorMessage = model.installIntegration()
                installing = false
            } label: {
                Label("一鍵安裝 Claude Code 整合", systemImage: "wand.and.stars")
                    .font(.system(size: 12 * uiScale, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .disabled(installing)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
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
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("裝好後在任何終端機執行 claude 即可。")
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

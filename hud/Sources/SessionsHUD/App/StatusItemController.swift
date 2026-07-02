import AppKit
import Combine

/// Menu bar extra shown while any session needs attention — accessory apps
/// don't get a Dock tile, so the status bar is the only always-on surface
/// for a "N waiting" glance. Click raises the HUD window.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let onClick: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, onClick: @escaping () -> Void) {
        self.model = model
        self.onClick = onClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)

        // Re-render only when the attention count actually changes — the raw
        // `sessions` array churns on every event batch, but the badge only
        // cares about the count.
        model.$sessions
            .map { $0.reduce(into: 0) { acc, s in if s.needsAttention { acc += 1 } } }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let enabled = UserDefaults.standard.object(forKey: "showMenuBarBadge") as? Bool ?? true
        let n = model.attentionCount
        if !enabled || n == 0 {
            button.title = ""
            statusItem.isVisible = false
            return
        }
        statusItem.isVisible = true
        button.title = "● \(n)"
        button.contentTintColor = NSColor.systemOrange
        button.toolTip = "\(n) session\(n == 1 ? "" : "s") waiting for you"
    }

    @objc private func clicked() {
        onClick()
    }
}

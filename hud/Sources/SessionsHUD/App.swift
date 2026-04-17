import SwiftUI
import AppKit
import Combine
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    private static let windowSize = NSSize(width: 420, height: 520)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = SessionListView().environmentObject(model)

        NSApp.setActivationPolicy(.accessory)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentMinSize = NSSize(width: 300, height: 300)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("SessionsHUDMain2")
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        installStatusItem()

        // First-run: trigger the Automation consent dialog up-front so the
        // user doesn't hit a silent failure the first time they click
        // `+` → Launch. Remembered in UserDefaults so we only prompt once.
        if !UserDefaults.standard.bool(forKey: "sessions-hud.automationPrimed") {
            TerminalFocus.primeAutomationPermission()
            UserDefaults.standard.set(true, forKey: "sessions-hud.automationPrimed")
        }

        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Sessions HUD",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    /// Menu bar extra shown while any session needs attention — LSUIElement
    /// apps don't get a Dock tile, so the status bar is the only always-on
    /// surface for a "N waiting" glance. Click raises the HUD window.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusItem = item

        // Re-render only when the attention count actually changes — the raw
        // `sessions` array churns on every SSE frame, but the badge only cares
        // about the count. UserDefaults publishes on any key; the early-return
        // in refreshStatusItem() handles unrelated toggles cheaply.
        model.$sessions
            .map { $0.reduce(into: 0) { acc, s in if s.needsAttention { acc += 1 } } }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let enabled = UserDefaults.standard.object(forKey: "showMenuBarBadge") as? Bool ?? true
        let n = model.attentionCount
        if !enabled || n == 0 {
            button.title = ""
            item.isVisible = false
            return
        }
        item.isVisible = true
        button.title = "● \(n)"
        button.contentTintColor = NSColor.systemOrange
        item.button?.toolTip = "\(n) session\(n == 1 ? "" : "s") waiting for you"
    }

    @objc private func statusItemClicked() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@main
enum SessionsHUDMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

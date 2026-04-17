import SwiftUI
import AppKit
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = AppModel()

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

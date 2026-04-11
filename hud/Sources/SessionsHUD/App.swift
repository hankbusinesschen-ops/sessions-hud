import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    private static let compactSize = NSSize(width: 280, height: 260)
    private static let expandedSize = NSSize(width: 560, height: 640)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = SessionListView().environmentObject(model)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.setFrameAutosaveName("SessionsHUDMain")
        window.makeKeyAndOrderFront(nil)

        // Drive window size from the selection state: compact when nothing is
        // selected, expanded when a row opens a chat view. Animate so the
        // Mode A ↔ Mode B transition feels like the same window growing.
        model.$selectedId
            .removeDuplicates()
            .sink { [weak self] newId in
                self?.resizeWindow(expanded: newId != nil)
            }
            .store(in: &cancellables)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        model.start()
    }

    private func resizeWindow(expanded: Bool) {
        guard let window else { return }
        let targetSize = expanded ? Self.expandedSize : Self.compactSize
        // Anchor on the top-left so the window grows downward/rightward rather
        // than "jumping" when switching modes.
        let currentFrame = window.frame
        let topLeftY = currentFrame.origin.y + currentFrame.height
        let newOrigin = NSPoint(x: currentFrame.origin.x,
                                y: topLeftY - targetSize.height)
        let newFrame = NSRect(origin: newOrigin, size: targetSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(newFrame, display: true, animate: true)
        }
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

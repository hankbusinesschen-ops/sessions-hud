import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: HUDPanel!
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = HUDPanel(
            rootView: SessionListView().environmentObject(model),
            size: NSSize(width: 420, height: 520)
        )
        panel.center()
        panel.setFrameAutosaveName("SessionsHUDPanel")
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installMenu()
        statusItem = StatusItemController(model: model) { [weak self] in
            self?.raiseHUD()
        }
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushSnapshot()
    }

    private func raiseHUD() {
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
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
        // CLI mode: install.sh drives the same integration logic the in-app
        // onboarding button uses — no GUI, print the log, exit.
        let args = CommandLine.arguments.dropFirst()
        if let flag = args.first(where: { $0.hasPrefix("--") }) {
            runCLI(flag)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func runCLI(_ flag: String) {
        do {
            switch flag {
            case "--install-hooks":
                try HooksInstaller.install().forEach { print($0) }
            case "--uninstall-hooks":
                try HooksInstaller.uninstall().forEach { print($0) }
            case "--doctor":
                for d in RuntimeDiagnostics.gatherFileBasedChecks() {
                    print("\(d.ok ? "✓" : "✗") \(d.label): \(d.detail)")
                }
            default:
                print("usage: SessionsHUD [--install-hooks | --uninstall-hooks | --doctor]")
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

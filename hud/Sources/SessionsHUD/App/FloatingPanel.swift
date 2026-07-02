import AppKit
import SwiftUI

/// The glass HUD window: a floating, non-activating panel whose entire
/// background is an NSVisualEffectView (behind-window blur, auto light/dark).
/// `.titled + .fullSizeContentView` keeps the system's rounded corners,
/// shadow, and resize handles for free; `.nonactivatingPanel` means clicking
/// the HUD never steals focus from the terminal you're working in.
final class HUDPanel: NSPanel {
    /// Non-activating panels refuse key status by default; we accept it so
    /// keyboard shortcuts (⌘J) and Esc work when the user clicks the HUD.
    override var canBecomeKey: Bool { true }

    init<Content: View>(rootView: Content, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Sessions"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        contentMinSize = NSSize(width: 300, height: 300)

        // The glass: clear window + behind-window material filling the frame.
        backgroundColor = .clear
        isOpaque = false
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        contentView = effect
    }
}

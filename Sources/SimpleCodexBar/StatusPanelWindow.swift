import AppKit

/// A single window whose visibility changes only through explicit input handling.
/// Unlike a popover, it has no automatic dismissal or activation-driven reopening.
@MainActor final class StatusPanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 16
    static let contentWidth: CGFloat = 380
    static let minimumContentHeight: CGFloat = 280
    static let maximumContentHeight: CGFloat = 720
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // AppDelegate constrains the visible surface. AppKit would otherwise push
        // the whole canvas down to fit its transparent shadow gutter below the menu bar.
        frameRect
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.minimumContentHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // ShadowedPanelView draws a rounded shadow in the transparent canvas.
        hasShadow = false
    }

    func roundWindowFrame() {
        // Clip the window's frame view too, not just the hosting view or glass content.
        guard let frameView = contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = Self.cornerRadius
        frameView.layer?.masksToBounds = true
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        roundWindowFrame()
        super.makeKeyAndOrderFront(sender)
    }
}

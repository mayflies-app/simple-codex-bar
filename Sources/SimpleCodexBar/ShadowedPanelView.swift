import AppKit

/// Keeps the shadow within a transparent canvas, separate from the glass sampling surface.
@MainActor final class ShadowedPanelView: NSView {
    static let shadowInset: CGFloat = 32
    private static let surfaceSize = NSSize(width: StatusPanelWindow.contentWidth,
                                            height: StatusPanelWindow.minimumContentHeight)
    let surface: NSView

    init(surface: NSView) {
        self.surface = surface
        super.init(frame: NSRect(x: 0, y: 0, width: Self.surfaceSize.width + Self.shadowInset * 2,
                                height: Self.surfaceSize.height + Self.shadowInset * 2))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.shadowInset),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.shadowInset),
            surface.topAnchor.constraint(equalTo: topAnchor, constant: Self.shadowInset),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.shadowInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // Exclude the glass itself: a shadow behind it would tint the translucent surface.
        let exterior = CGMutablePath()
        exterior.addRect(bounds)
        exterior.addPath(outline)
        context.addPath(exterior)
        context.clip(using: .evenOdd)
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                          color: NSColor.black.withAlphaComponent(0.32).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(outline)
        context.fillPath()
    }

    func containsSurface(_ point: NSPoint) -> Bool {
        outline.contains(point)
    }

    private var outline: CGPath {
        CGPath(roundedRect: surface.frame, cornerWidth: StatusPanelWindow.cornerRadius,
               cornerHeight: StatusPanelWindow.cornerRadius, transform: nil)
    }
}

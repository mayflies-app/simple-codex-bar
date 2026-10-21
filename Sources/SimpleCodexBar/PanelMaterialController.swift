import AppKit

/// A single material surrounds the content; rows stay simple to preserve text contrast.
@MainActor final class PanelMaterialController: NSViewController {
    let content: NSViewController
    private(set) var materialName = "standard"
    private(set) var materialView: NSView?
    private let forceStandard: Bool

    init(content: NSViewController, forceStandard: Bool = false) {
        self.content = content; self.forceStandard = forceStandard
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        addChild(content)
        let surface = MacAppGlass.makeSurface(content: content.view,
                                              cornerRadius: StatusPanelWindow.cornerRadius,
                                              forceStandard: forceStandard)
        materialName = surface.materialName
        materialView = surface.view
        view = ShadowedPanelView(surface: surface.view)
    }
}

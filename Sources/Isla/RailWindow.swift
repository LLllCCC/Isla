import AppKit

/// 形态 C：菜单栏下沿的一条细线。不接收点击以外的任何区域，视觉负担为零。
final class RailView: NSView {

    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        let r = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
}

final class RailPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit

/// A click-through outline drawn around the thumbnail whose close button is
/// hovered, so it is clear which window the button closes.
final class ThumbnailHighlightWindow: NSWindow {

    /// How far the outline sits outside the thumbnail.
    private static let outset: CGFloat = 4

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = HighlightView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    func show(around thumbnailFrame: NSRect) {
        let newFrame = thumbnailFrame.insetBy(dx: -Self.outset, dy: -Self.outset)
        if frame != newFrame {
            setFrame(newFrame, display: true, animate: false)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }
}

private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 3
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

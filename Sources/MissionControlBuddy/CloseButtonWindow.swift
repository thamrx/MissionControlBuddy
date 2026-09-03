import AppKit
import ApplicationServices

/// A small "close" button floated over the top-left corner of a Mission
/// Control thumbnail. The window itself is click-through like the label
/// overlay; clicks are delivered by `ClickInterceptor`, because Mission
/// Control would otherwise swallow them.
final class CloseButtonWindow: NSWindow {

    /// The real AX window this button closes.
    private var targetWindow: AXUIElement?
    private var lastStyleToken: String?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
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

        contentView = CloseButtonView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    }

    func setPressed(_ pressed: Bool) {
        (contentView as? CloseButtonView)?.setPressed(pressed)
    }

    func setFrameIfNeeded(_ newFrame: NSRect) {
        if frame != newFrame {
            setFrame(newFrame, display: false, animate: false)
        }
    }

    func update(target: AXUIElement, style: ChipStyle) {
        targetWindow = target
        if style.token != lastStyleToken {
            lastStyleToken = style.token
            (contentView as? CloseButtonView)?.configure(style: style)
        }
    }

    /// Presses the real window's close button through the Accessibility API.
    func performClose() {
        guard let targetWindow else { return }
        guard let button = DockAXReader.copyAttribute(targetWindow, kAXCloseButtonAttribute as String) else {
            NSLog("CloseButton: window has no AXCloseButton")
            return
        }
        let result = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        if result != .success {
            NSLog("CloseButton: AXPress failed (\(result.rawValue))")
        }
    }
}

/// Draws a filled circle with an "x", like a traffic-light close button.
final class CloseButtonView: NSView {

    private var background: NSColor = NSColor.black.withAlphaComponent(0.72)
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(style: ChipStyle) {
        background = style.backgroundColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: rect)
        (isPressed ? background.blended(withFraction: 0.3, of: .white) ?? background : background).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let cross = NSBezierPath()
        let r = rect.width * 0.22
        let c = NSPoint(x: rect.midX, y: rect.midY)
        cross.move(to: NSPoint(x: c.x - r, y: c.y - r))
        cross.line(to: NSPoint(x: c.x + r, y: c.y + r))
        cross.move(to: NSPoint(x: c.x - r, y: c.y + r))
        cross.line(to: NSPoint(x: c.x + r, y: c.y - r))
        cross.lineWidth = max(1.5, rect.width * 0.1)
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        needsDisplay = true
    }
}

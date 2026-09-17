import AppKit
import ApplicationServices

/// Intercepts mouse clicks while Mission Control is open.
///
/// Mission Control receives mouse events before any window we float above
/// it, so a plain clickable NSPanel never sees the click: Mission Control
/// treats it as "select this window". The only way in is a HID-level event
/// tap that swallows the mouse-down and mouse-up when they land on one of our
/// close buttons. All other events pass through untouched. The tap is only
/// enabled while overlays are showing.
///
/// The same tap watches mouse movement to highlight the thumbnail a hovered
/// close button belongs to, which matters when thumbnails are stacked.
@MainActor
final class ClickInterceptor {

    struct Target {
        /// Hit rect in global display coordinates (top-left origin), the same
        /// space CGEvent locations use.
        let rect: CGRect
        let button: CloseButtonWindow
        /// The thumbnail this button closes, in Cocoa screen coordinates.
        let thumbnailFrame: NSRect
        /// The chip overlay of that thumbnail, raised together with the button.
        let overlay: NSWindow
    }

    static let shared = ClickInterceptor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targets: [Target] = []
    private var pressed: Target?
    private var hovered: Target?
    private lazy var highlight = ThumbnailHighlightWindow()

    private init() {}

    /// Replace the set of clickable rects for the current frame.
    func setTargets(_ targets: [Target]) {
        self.targets = targets
        // Keep the hover across re-renders, following the thumbnail if it moved.
        if let current = hovered {
            if let updated = targets.first(where: { $0.button === current.button }) {
                hovered = updated
                highlight.show(around: updated.thumbnailFrame)
            } else {
                clearHover()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            if tap == nil { createTap() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            targets.removeAll()
            pressed?.button.setPressed(false)
            pressed = nil
            clearHover()
        }
    }

    private func createTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: clickInterceptorCallback,
            userInfo: refcon
        ) else {
            Diagnostics.log("ClickInterceptor: could not create event tap (Accessibility permission missing?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Mission Control keeps its blue hover outline on the spot of a closed
    /// thumbnail until the mouse moves. Post a tiny synthetic move after the
    /// layout has reflowed so it re-evaluates what is under the cursor.
    private func nudgeMouse(at location: CGPoint) {
        for (delay, offset) in [(0.15, 1.0), (0.3, 0.0)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let point = CGPoint(x: location.x + offset, y: location.y + offset)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: point, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
        }
    }

    private func updateHover(at location: CGPoint) {
        if let current = hovered, current.rect.contains(location) { return }
        guard let target = targets.first(where: { $0.rect.contains(location) }) else {
            clearHover()
            return
        }
        hovered?.button.setHovered(false)
        hovered = target
        // Stacking order: highlight, then the thumbnail's chip, then its button,
        // so a stacked thumbnail's chip and button end up on top.
        highlight.show(around: target.thumbnailFrame)
        highlight.orderFrontRegardless()
        target.overlay.orderFrontRegardless()
        target.button.orderFrontRegardless()
        target.button.setHovered(true)
    }

    private func clearHover() {
        hovered?.button.setHovered(false)
        hovered = nil
        highlight.orderOut(nil)
    }

    /// Returns true when the event must be swallowed.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged:
            updateHover(at: location)
            return false
        case .leftMouseDown:
            // Prefer the highlighted target so the click closes what is shown.
            let hit = hovered.flatMap { $0.rect.contains(location) ? $0 : nil }
                ?? targets.first(where: { $0.rect.contains(location) })
            guard let target = hit else { return false }
            pressed = target
            target.button.setPressed(true)
            return true
        case .leftMouseUp:
            guard let target = pressed else { return false }
            pressed = nil
            target.button.setPressed(false)
            if target.rect.contains(location) {
                target.button.performClose()
                nudgeMouse(at: location)
            }
            return true
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            return false
        }
    }
}

private func clickInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    // The run loop source lives on the main run loop, so this runs on main.
    let location = event.location
    let swallow = MainActor.assumeIsolated {
        interceptor.handle(type, at: location)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

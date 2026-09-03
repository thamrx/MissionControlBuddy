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
@MainActor
final class ClickInterceptor {

    struct Target {
        /// Hit rect in global display coordinates (top-left origin), the same
        /// space CGEvent locations use.
        let rect: CGRect
        let button: CloseButtonWindow
    }

    static let shared = ClickInterceptor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targets: [Target] = []
    private var pressed: Target?

    private init() {}

    /// Replace the set of clickable rects for the current frame.
    func setTargets(_ targets: [Target]) {
        self.targets = targets
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
        }
    }

    private func createTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: clickInterceptorCallback,
            userInfo: refcon
        ) else {
            NSLog("ClickInterceptor: could not create event tap (Accessibility permission missing?)")
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

    /// Returns true when the event must be swallowed.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint) -> Bool {
        switch type {
        case .leftMouseDown:
            guard let target = targets.first(where: { $0.rect.contains(location) }) else { return false }
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

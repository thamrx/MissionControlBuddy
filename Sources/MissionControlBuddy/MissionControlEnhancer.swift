import AppKit
import ApplicationServices

/// Watches for native Mission Control activation and overlays app icon + name
/// (+ window title) chips on each thumbnail.
///
/// Performance design:
///  * A pool of overlay windows is REUSED across frames (no create/destroy
///    churn — that was the source of the left-edge flicker and teardown lag).
///  * A cheap "is MC open?" check runs every tick for instant teardown.
///  * Overlays only move/redraw when their frame or content actually changes.
@MainActor
final class MissionControlEnhancer {

    private var pollTimer: Timer?
    private var overlayPool: [ThumbnailOverlayWindow] = []
    private var closeButtonPool: [CloseButtonWindow] = []
    private var activeCount = 0
    private var iconResolver = IconResolver()
    private var isShowingOverlays = false

    private var suppressedUntilMCClosed = false
    private var mouseMonitor: Any?

    /// Signature of the last-seen thumbnail layout. Used to detect whether the
    /// thumbnails are STABLE (settled) vs animating (opening/closing). We only
    /// draw when stable — this kills the bottom-left blip during the close
    /// animation, regardless of how MC was dismissed (click, swipe, keyboard).
    private var lastLayoutSignature: String?
    private var stableLayoutTicks = 0

    private(set) var isEnabled = true

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: PreferencesStore.changedNotification,
            object: nil
        )
        // 60ms (~16Hz): responsive without hammering the Dock AX bridge.
        pollTimer = Timer.scheduledTimer(
            timeInterval: 0.06,
            target: self,
            selector: #selector(poll),
            userInfo: nil,
            repeats: true
        )
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        hideAllOverlays()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            hideAllOverlays()
        }
    }

    @objc private func preferencesChanged() {
        // Force a restyle on the next render by resetting the layout signature.
        lastLayoutSignature = nil
    }

    // MARK: - Polling

    @objc private func poll() {
        guard isEnabled else { return }

        // Fast path: if MC isn't open, hide everything immediately. This is the
        // cheap top-level check, so teardown feels instant.
        guard DockAXReader.isMissionControlOpen() else {
            suppressedUntilMCClosed = false
            stableLayoutTicks = 0
            lastLayoutSignature = nil
            if isShowingOverlays { hideAllOverlays() }
            return
        }

        // If the user just selected a window in MC, we suppress re-drawing until
        // Mission Control actually closes (prevents the "one last draw" glitch).
        if suppressedUntilMCClosed {
            return
        }

        guard let thumbnails = DockAXReader.currentThumbnails(), !thumbnails.isEmpty else {
            stableLayoutTicks = 0
            lastLayoutSignature = nil
            if isShowingOverlays { hideAllOverlays() }
            return
        }

        // Stability + renderability gate:
        // - During the Mission Control open/close animation, frames change.
        // - During the interactive partial-swipe transition, Dock may report a
        //   stable-but-useless layout where many frames overlap/collapse near the
        //   bottom-left corner.
        // In both cases, we DO NOT want overlays. We only draw when the layout is
        // stable *and* looks like the fully-open Mission Control grid.
        let signature = layoutSignature(thumbnails)
        defer { lastLayoutSignature = signature }

        let renderable = layoutIsRenderable(thumbnails)
        if signature == lastLayoutSignature && renderable {
            stableLayoutTicks = min(stableLayoutTicks + 1, 10)
        } else {
            stableLayoutTicks = 0
            if isShowingOverlays { hideAllOverlays() }
            return
        }

        // Require a couple stable ticks before drawing (debounce jitter).
        guard stableLayoutTicks >= 2 else {
            return
        }

        if !isShowingOverlays {
            iconResolver.refresh()   // rebuild icon lookup once per activation
            isShowingOverlays = true
            installSelectionMonitor()
        }

        render(thumbnails)
    }

    /// A cheap fingerprint of the current thumbnail layout (titles + frames).
    private func layoutSignature(_ thumbnails: [Thumbnail]) -> String {
        func q(_ value: CGFloat) -> Int {
            // Quantize to 8px buckets so tiny AX jitter doesn't reset stability.
            Int((value / 8.0).rounded())
        }

        return thumbnails
            .map { "\($0.title)@\(q($0.axFrame.origin.x)),\(q($0.axFrame.origin.y)),\(q($0.axFrame.width)),\(q($0.axFrame.height))" }
            .joined(separator: "|")
    }

    /// Heuristic: returns true only when the layout looks like the fully-open
    /// Mission Control grid. Returns false for:
    /// - open/close animation frames
    /// - partial swipe / interactive transition (thumbnails overlap and/or
    ///   collapse toward the bottom-left)
    private func layoutIsRenderable(_ thumbnails: [Thumbnail]) -> Bool {
        guard thumbnails.count >= 2 else { return false }
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return false
        }

        let screenRect = screen.frame
        let screenArea = max(1.0, screenRect.width * screenRect.height)

        let frames = thumbnails.compactMap { cocoaFrame(from: $0.axFrame) }
        guard frames.count >= 2 else { return false }

        // Bounding box should cover a meaningful portion of the screen.
        var bbox = frames[0]
        for f in frames.dropFirst() { bbox = bbox.union(f) }
        let bboxArea = max(1.0, bbox.width * bbox.height)

        // If everything is clustered, we're likely in the transition.
        if bboxArea / screenArea < 0.18 {
            return false
        }

        // The bottom-left "pile" symptom: ONLY reject when layout is both
        // corner-hugging and tightly clustered (small bbox). A valid full MC
        // grid can still begin near the left/bottom edges.
        let cornerHugging = bbox.minX < 80 && bbox.minY < 160
        let clustered = bbox.width < (screenRect.width * 0.55) && bbox.height < (screenRect.height * 0.55)
        if cornerHugging && clustered {
            return false
        }

        // Overlap check: in real MC grid, thumbnails barely overlap. In the
        // interactive transition they overlap heavily.
        var heavyOverlaps = 0
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let a = frames[i]
                let b = frames[j]
                let inter = a.intersection(b)
                if inter.isNull { continue }
                let interArea = inter.width * inter.height
                let minArea = min(a.width * a.height, b.width * b.height)
                if minArea > 0, interArea / minArea > 0.20 {
                    heavyOverlaps += 1
                    if heavyOverlaps >= frames.count { // plenty overlap → bail fast
                        return false
                    }
                }
            }
        }

        return true
    }

    // MARK: - Rendering (reuses pooled windows)

    private func render(_ thumbnails: [Thumbnail]) {
        let style = ChipStyle.current()
        iconResolver.beginPass()   // reset per-frame window claims
        var clickTargets: [ClickInterceptor.Target] = []
        for (index, thumbnail) in thumbnails.enumerated() {
            guard let cocoaFrame = cocoaFrame(from: thumbnail.axFrame) else { continue }

            let overlay = overlay(at: index)
            let aspect = thumbnail.axFrame.height > 0 ? thumbnail.axFrame.width / thumbnail.axFrame.height : 0
            let resolved = iconResolver.resolve(title: thumbnail.title, aspect: aspect)

            overlay.setFrameIfNeeded(cocoaFrame)
            overlay.updateIfNeeded(icon: resolved.icon, appName: resolved.appName, windowTitle: thumbnail.title, style: style)
            if !overlay.isVisible {
                overlay.orderFrontRegardless()
            }

            let closeButton = closeButton(at: index)
            if style.showCloseButton, let window = resolved.window {
                let size = 20 * CGFloat(style.scale)
                let inset = 6 * CGFloat(style.scale)
                closeButton.setFrameIfNeeded(NSRect(x: cocoaFrame.minX + inset,
                                                    y: cocoaFrame.maxY - inset - size,
                                                    width: size, height: size))
                closeButton.update(target: window, style: style)
                // Hit rect in AX/global (top-left origin) space for the event tap.
                let hitRect = CGRect(x: thumbnail.axFrame.minX + inset,
                                     y: thumbnail.axFrame.minY + inset,
                                     width: size, height: size).insetBy(dx: -2, dy: -2)
                clickTargets.append(ClickInterceptor.Target(rect: hitRect, button: closeButton,
                                                            thumbnailFrame: cocoaFrame, overlay: overlay))
                if !closeButton.isVisible {
                    closeButton.orderFrontRegardless()
                }
            } else if closeButton.isVisible {
                closeButton.orderOut(nil)
            }
        }

    // Hide any leftover overlays from a previous frame with more thumbnails.
        if thumbnails.count < activeCount {
            for index in thumbnails.count..<activeCount {
                overlayPool[index].orderOut(nil)
                closeButtonPool[index].orderOut(nil)
            }
        }
        activeCount = thumbnails.count

        ClickInterceptor.shared.setTargets(clickTargets)
        ClickInterceptor.shared.setEnabled(style.showCloseButton)
    }

    /// Returns a pooled overlay window, creating one lazily if needed.
    private func overlay(at index: Int) -> ThumbnailOverlayWindow {
        if index < overlayPool.count {
            return overlayPool[index]
        }
        let overlay = ThumbnailOverlayWindow()
        overlayPool.append(overlay)
        return overlay
    }

    private func closeButton(at index: Int) -> CloseButtonWindow {
        if index < closeButtonPool.count {
            return closeButtonPool[index]
        }
        let button = CloseButtonWindow()
        closeButtonPool.append(button)
        return button
    }

    private func hideAllOverlays() {
        for overlay in overlayPool where overlay.isVisible {
            overlay.orderOut(nil)
        }
        for button in closeButtonPool where button.isVisible {
            button.orderOut(nil)
        }
        ClickInterceptor.shared.setEnabled(false)
        activeCount = 0
        isShowingOverlays = false
        removeSelectionMonitor()
    }

    private func installSelectionMonitor() {
        guard mouseMonitor == nil else { return }
        // Any click while Mission Control is open usually means "select a window".
        // Hide immediately so overlays never linger over the chosen app.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isShowingOverlays {
                    self.suppressedUntilMCClosed = true
                    self.hideAllOverlays()
                }
            }
        }
    }

    private func removeSelectionMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    // MARK: - Coordinate conversion

    /// Converts an AX/global rect (top-left origin, y-down) to a Cocoa screen
    /// rect (bottom-left origin, y-up).
    private func cocoaFrame(from axFrame: CGRect) -> NSRect? {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        guard let primaryScreen = primary else { return nil }

        let cocoaY = primaryScreen.frame.maxY - axFrame.origin.y - axFrame.height
        return NSRect(x: axFrame.origin.x, y: cocoaY, width: axFrame.width, height: axFrame.height)
    }
}

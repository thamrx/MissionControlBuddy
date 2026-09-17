import AppKit
import ApplicationServices

/// Private but long-stable API (used by yabai, AltTab, Hammerspoon) that maps
/// an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Resolves a Mission Control thumbnail title to its owning app's icon + name.
///
/// Mission Control exposes NO app identity on its thumbnail buttons (proven by
/// MissionControlAttrProbe — only title/frame/role are available). So we match
/// the thumbnail's window title against the real per-app AX window titles.
///
/// Key gotcha: Mission Control MIDDLE-TRUNCATES long titles with an ellipsis
/// (e.g. "…spaces i…n Mac…"). Exact matching fails for those, so we also do a
/// prefix/suffix match around the ellipsis.
struct IconResolver {

    struct Resolved {
        let appName: String
        let icon: NSImage?
        /// The real AX window behind the thumbnail, when it could be identified.
        let window: AXUIElement?
    }

    private struct WindowEntry {
        let title: String
        let app: NSRunningApplication
        let element: AXUIElement
        /// CGWindowID of the AX window, when it could be read.
        let windowID: CGWindowID?
        /// width / height of the real AX window. Used to recover the identity of
        /// title-less thumbnails (e.g. TablePlus) via aspect-ratio matching,
        /// since Mission Control scales each space uniformly.
        let aspect: CGFloat
    }

    private var titleToApp: [String: NSRunningApplication] = [:]
    private var appNameToApp: [String: NSRunningApplication] = [:]
    private var windows: [WindowEntry] = []
    /// Indices into `windows` already claimed during the current render pass, so
    /// two thumbnails never resolve to the same physical window.
    private var claimedWindowIndices: Set<Int> = []

    /// The character macOS uses for truncation (U+2026 HORIZONTAL ELLIPSIS).
    private static let ellipsis: Character = "\u{2026}"

    /// Rebuild the lookup. Call this each time Mission Control opens so the
    /// map reflects the current set of windows.
    mutating func refresh() {
        titleToApp.removeAll(keepingCapacity: true)
        appNameToApp.removeAll(keepingCapacity: true)
        windows.removeAll(keepingCapacity: true)
        claimedWindowIndices.removeAll(keepingCapacity: true)

        let current = NSRunningApplication.current
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            // Regular apps always participate; additionally include OUR
            // background/accessory app so its Preferences window chip gets an
            // icon too.
            if app.activationPolicy == .regular { return true }
            if app.processIdentifier == current.processIdentifier { return true }
            return false
        }

        for app in apps {
            if let name = app.localizedName {
                appNameToApp[name] = app
            }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows = DockAXReader.copyAttribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement] else {
                continue
            }

            for window in axWindows {
                let title = DockAXReader.title(window)
                let aspect = aspectRatio(of: window)
                // Keep EVERY window (even title-less ones) for geometry matching.
                var windowID: CGWindowID = 0
                let hasWindowID = _AXUIElementGetWindow(window, &windowID) == .success && windowID != 0
                windows.append(WindowEntry(title: title, app: app, element: window,
                                           windowID: hasWindowID ? windowID : nil, aspect: aspect))
                if !title.isEmpty, titleToApp[title] == nil {
                    titleToApp[title] = app   // keep first mapping; avoid random flips
                }
            }
        }
    }

    /// Reset per-pass claim tracking. Call once before resolving the batch of
    /// thumbnails for a single Mission Control frame.
    mutating func beginPass() {
        claimedWindowIndices.removeAll(keepingCapacity: true)
    }

    /// width / height of an AX window, or 0 when unavailable.
    private func aspectRatio(of window: AXUIElement) -> CGFloat {
        guard let f = DockAXReader.frame(window), f.height > 0 else { return 0 }
        return f.width / f.height
    }

    /// Resolve a thumbnail title to an app icon + name.
    ///
    /// `aspect` is the thumbnail's width/height, used to recover the identity of
    /// title-less windows (Mission Control scales each space uniformly, so the
    /// thumbnail aspect ratio matches the real window's).
    mutating func resolve(title: String, aspect: CGFloat = 0, windowID: Int? = nil) -> Resolved {
        // 0. macOS 27 thumbnails carry the CGWindowID of their window: exact match,
        //    no title heuristics needed.
        if let windowID, let match = claimWindow(id: CGWindowID(windowID)) {
            return resolved(match.app, fallbackName: title, window: match.element)
        }

        // Title-less thumbnail (e.g. TablePlus): match purely by geometry.
        if title.isEmpty {
            if let entry = claimClosestWindow(aspect: aspect) {
                return resolved(entry.app, fallbackName: entry.app.localizedName ?? "", window: entry.element)
            }
            return Resolved(appName: "", icon: nil, window: nil)
        }

        // 1. Exact window-title match (works for non-truncated titles).
        if let app = titleToApp[title] {
            let window = claimWindow(matching: title)
            return resolved(app, fallbackName: title, window: window)
        }

        // 2. Middle-ellipsis truncation: match a real window by prefix/suffix.
        if let entry = matchTruncated(title) {
            return resolved(entry.app, fallbackName: title, window: entry.element)
        }

        // 2b. Short title that is a PREFIX of a real window title. Some apps
        //     append text to their AX title that MC's thumbnail omits, e.g.
        //     Chrome shows "Gmail" but its AX title is
        //     "Gmail - Google Chrome - <profile>".
        if title.count >= 3 {
            for entry in windows where entry.title.hasPrefix(title) {
                return resolved(entry.app, fallbackName: title, window: entry.element)
            }
        }

        // 3. Title of the form "document — AppName": match the trailing segment.
        for separator in [" \u{2014} ", " \u{2013} ", " - "] {
            if let range = title.range(of: separator, options: .backwards) {
                let tail = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let app = appNameToApp[tail] {
                    return resolved(app, fallbackName: tail)
                }
                let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let app = appNameToApp[head] {
                    return resolved(app, fallbackName: head)
                }
            }
        }

        // 4. Whole title equals an app name (e.g. "Calendar", "Postman").
        if let app = appNameToApp[title] {
            return resolved(app, fallbackName: title)
        }

        // 5. Give up on the icon; keep the title as the name.
        return Resolved(appName: title, icon: nil, window: nil)
    }

    // MARK: - Helpers

    /// Claim the window with this CGWindowID. When it is not among the AX
    /// windows read at refresh (for example an app that is not a regular app),
    /// fall back to the window server's owner PID so the icon is still right.
    private mutating func claimWindow(id windowID: CGWindowID) -> (app: NSRunningApplication, element: AXUIElement?)? {
        if let index = windows.firstIndex(where: { $0.windowID == windowID }) {
            claimedWindowIndices.insert(index)
            return (windows[index].app, windows[index].element)
        }
        guard
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t
        else {
            return nil
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return (app, nil)
    }

    /// Claim the first unclaimed window whose title matches, so a subsequent
    /// title-less thumbnail won't steal its identity via geometry. Returns the
    /// claimed AX window.
    private mutating func claimWindow(matching title: String) -> AXUIElement? {
        for (index, entry) in windows.enumerated()
        where !claimedWindowIndices.contains(index) && entry.title == title {
            claimedWindowIndices.insert(index)
            return entry.element
        }
        return nil
    }

    /// Find (and claim) the unclaimed window whose aspect ratio is closest to
    /// the thumbnail's. Returns nil when nothing is close enough.
    private mutating func claimClosestWindow(aspect: CGFloat) -> WindowEntry? {
        guard aspect > 0 else { return nil }

        var bestIndex: Int?
        var bestDelta = CGFloat.greatestFiniteMagnitude
        for (index, entry) in windows.enumerated() {
            guard !claimedWindowIndices.contains(index), entry.aspect > 0 else { continue }
            let delta = abs(entry.aspect - aspect)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }

        // Require a reasonably tight match (±8% of the aspect ratio). Uniform
        // MC scaling preserves aspect, so a loose match means "not this window".
        guard let bestIndex, bestDelta <= aspect * 0.08 else { return nil }
        claimedWindowIndices.insert(bestIndex)
        return windows[bestIndex]
    }

    private func resolved(_ app: NSRunningApplication, fallbackName: String, window: AXUIElement? = nil) -> Resolved {
        Resolved(appName: app.localizedName ?? fallbackName, icon: app.icon, window: window)
    }

    /// Match a middle-truncated title (containing "\u{2026}") against a real window
    /// title. The prefix (before the ellipsis) must anchor at the START of the
    /// real title; the suffix (after the ellipsis) must appear SOMEWHERE after
    /// it. We use `contains` for the suffix rather than `hasSuffix` because some
    /// apps append extra text to their AX window title that Mission Control's
    /// thumbnail title omits — e.g. Chrome adds " - Google Chrome - <profile>".
    private func matchTruncated(_ truncated: String) -> WindowEntry? {
        guard truncated.contains(Self.ellipsis) else { return nil }

        // Split on every ellipsis; the first segment is the prefix, the last is
        // the suffix (handles rare multi-ellipsis titles too).
        let segments = truncated
            .split(separator: Self.ellipsis, omittingEmptySubsequences: false)
            .map(String.init)
        guard let prefix = segments.first, let suffix = segments.last else { return nil }

        // Guard against too-loose matches (very short prefix + suffix).
        guard prefix.count + suffix.count >= 6 else { return nil }

        for entry in windows {
            let realTitle = entry.title
            guard realTitle.count >= prefix.count else { continue }
            if (prefix.isEmpty || realTitle.hasPrefix(prefix)),
               (suffix.isEmpty || realTitle.contains(suffix)) {
                return entry
            }
        }
        return nil
    }
}

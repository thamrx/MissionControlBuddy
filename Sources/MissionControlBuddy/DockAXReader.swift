import AppKit
import ApplicationServices

/// A single Mission Control thumbnail as exposed by the Dock's Accessibility tree.
struct Thumbnail {
    let title: String
    /// Frame in AX/global coordinates (top-left origin, y grows downward).
    let axFrame: CGRect
    /// CGWindowID of the window behind the thumbnail (`wid`, macOS 27+).
    var windowID: Int? = nil
}

/// Where the Mission Control accessibility tree lives.
enum MissionControlHost: String {
    /// Through macOS 26: under the Dock's "Mission Control" group.
    case dock
    /// macOS 27+: the Dock keeps an empty stub group; the displays and their
    /// thumbnails are children of the WindowManager application element.
    case windowManager
}

/// Reads native Mission Control thumbnails from the Dock process via the
/// public Accessibility API. Probe #2 proved these exist as AXButtons nested
/// under an AXGroup titled "Mission Control".
enum DockAXReader {

    // MARK: - Generic AX helpers

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? ""
    }

    static func title(_ element: AXUIElement) -> String {
        string(element, kAXTitleAttribute as String) ?? ""
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let posValue = copyAttribute(element, kAXPositionAttribute as String),
            let sizeValue = copyAttribute(element, kAXSizeAttribute as String)
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    // MARK: - Dock element

    static func dockElement() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first
        else {
            return nil
        }
        return AXUIElementCreateApplication(dock.processIdentifier)
    }

    /// Diagnostics: "role:title" of the Dock's top-level children.
    static func dockTopLevelDescription() -> String {
        guard let dock = dockElement() else { return "<no dock element>" }
        let kids = children(dock)
        if kids.isEmpty { return "<no children readable>" }
        return kids.map { "\(role($0)):\(title($0))" }.joined(separator: ", ")
    }

    static func identifier(_ element: AXUIElement) -> String {
        string(element, kAXIdentifierAttribute as String) ?? ""
    }

    static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copyAttribute(element, attribute) as? NSNumber)?.intValue
    }

    static let windowManagerBundleID = "com.apple.WindowManager"

    static func windowManagerElement() -> AXUIElement? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: windowManagerBundleID)
            .first
        else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// The host the last `currentThumbnails()` call read from.
    @MainActor private(set) static var lastHost: MissionControlHost = .dock

    /// How WindowManager-hosted window thumbnails report AXPosition. On macOS
    /// 27.0 they report their top-left corner (the thumbnail at x=23 on a
    /// display starting at x=0 could not be a center). Spaces-bar tiles do
    /// report their center, but those are not used here. Overridable without a
    /// rebuild in case a later release changes it:
    ///   defaults write com.local.missioncontrolbuddy mcPositionAnchor center
    /// Read once per Mission Control session via `reloadAnchorOverride()`.
    @MainActor private(set) static var windowManagerAnchorIsCenter = false

    @MainActor static func reloadAnchorOverride() {
        let appID = (Bundle.main.bundleIdentifier ?? "com.local.missioncontrolbuddy") as CFString
        CFPreferencesAppSynchronize(appID)
        let value = CFPreferencesCopyAppValue("mcPositionAnchor" as CFString, appID) as? String
        windowManagerAnchorIsCenter = value == "center"
    }

    /// Returns the "Mission Control" AXGroup if MC is currently open, else nil.
    static func missionControlGroup(in dock: AXUIElement) -> AXUIElement? {
        for child in children(dock) where role(child) == kAXGroupRole as String {
            if title(child) == "Mission Control" {
                return child
            }
        }
        return nil
    }

    /// Cheap check: is Mission Control currently open? Only inspects the Dock's
    /// top-level children (no deep tree walk), so it's fast enough to call often
    /// for instant teardown detection.
    static func isMissionControlOpen() -> Bool {
        guard let dock = dockElement() else { return false }
        return missionControlGroup(in: dock) != nil
    }

    /// Reads all thumbnail buttons under the Mission Control group.
    /// Returns nil when Mission Control is not open.
    @MainActor static func currentThumbnails() -> [Thumbnail]? {
        guard let dock = dockElement() else { return nil }
        guard let mcGroup = missionControlGroup(in: dock) else { return nil }

        var results: [Thumbnail] = []
        collectThumbnails(from: mcGroup, into: &results, depth: 0)
        if !results.isEmpty || !children(mcGroup).isEmpty {
            lastHost = .dock
            return results
        }

        // macOS 27: the Dock's group is an empty stub while Mission Control is
        // open; read the displays from WindowManager instead.
        lastHost = .windowManager
        guard let windowManager = windowManagerElement() else { return results }
        for display in children(windowManager) where identifier(display) == "mc.display" {
            // Window thumbnails are direct AXButton children of the display
            // (there is no mc.windows container anymore). The Spaces bar is a
            // separate mc.spaces group and is skipped this way.
            for child in children(display) where role(child) == kAXButtonRole as String {
                guard let reported = frame(child), reported.width > 60, reported.height > 40 else { continue }
                let axFrame = windowManagerAnchorIsCenter
                    ? reported.offsetBy(dx: -reported.width / 2, dy: -reported.height / 2)
                    : reported
                results.append(Thumbnail(title: title(child), axFrame: axFrame,
                                         windowID: number(child, "wid")))
            }
        }
        return results
    }

    /// Recursively walks the MC subtree, collecting window thumbnails.
    ///
    /// Window thumbnails are AXButtons living inside a space's content group.
    /// We deliberately KEEP empty-title buttons: some apps (e.g. TablePlus)
    /// expose windows with an empty AXTitle, and those still deserve a chip —
    /// their identity is recovered later via geometry matching.
    ///
    /// We exclude the Spaces Bar group ("Desktop 1/2/…" plus the add-desktop
    /// chrome button, which is a CHILD of that group). We must NOT filter on Y
    /// origin: thumbnails on a secondary monitor placed above/left of the
    /// primary have negative AX coordinates and are perfectly valid.
    private static func collectThumbnails(from element: AXUIElement, into results: inout [Thumbnail], depth: Int) {
        if depth > 10 { return }

        for child in children(element) {
            let childRole = role(child)
            let childTitle = title(child)

            // Skip the Spaces Bar group entirely (Desktop 1/2/… + add-desktop button).
            if childRole == kAXGroupRole as String, childTitle == "Spaces Bar" {
                continue
            }

            if childRole == kAXButtonRole as String,
               let f = frame(child),
               f.width > 60, f.height > 40 {
                results.append(Thumbnail(title: childTitle, axFrame: f))
            }

            collectThumbnails(from: child, into: &results, depth: depth + 1)
        }
    }
}

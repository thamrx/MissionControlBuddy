import AppKit
import ApplicationServices

/// Diagnostics: writes the Dock's full accessibility tree to
/// ~/Library/Logs/MissionControlBuddy-axdump.txt so a changed Mission Control
/// structure (new macOS release) can be inspected without extra tools.
enum AXTreeDump {

    static let fileURL = Diagnostics.fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("MissionControlBuddy-axdump.txt")

    private static let maxLines = 2500
    private static let maxDepth = 16

    @MainActor static func dumpMissionControl() {
        var lines: [String] = ["# Mission Control AX trees, \(Date()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for screen in NSScreen.screens {
            lines.append("# screen \(screen.localizedName) frame=\(screen.frame) scale=\(screen.backingScaleFactor)")
        }
        lines.append("# windowManagerAnchorIsCenter=\(DockAXReader.windowManagerAnchorIsCenter)")
        lines.append("## Dock")
        if let dock = DockAXReader.dockElement() {
            walk(dock, depth: 0, into: &lines)
        }
        lines.append("## WindowManager")
        if let windowManager = DockAXReader.windowManagerElement() {
            walk(windowManager, depth: 0, into: &lines)
        } else {
            lines.append("# WindowManager not running")
        }
        if lines.count >= maxLines { lines.append("# truncated at \(maxLines) lines") }
        do {
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            Diagnostics.log("axdump: wrote \(lines.count) lines to \(fileURL.path)")
        } catch {
            Diagnostics.log("axdump: write failed: \(error)")
        }
    }

    private static func walk(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard lines.count < maxLines else { return }
        let indent = String(repeating: "  ", count: depth)
        let role = DockAXReader.role(element)
        let subrole = DockAXReader.string(element, kAXSubroleAttribute as String) ?? ""
        let title = DockAXReader.title(element)
        let description = DockAXReader.string(element, kAXDescriptionAttribute as String) ?? ""
        let identifier = DockAXReader.string(element, kAXIdentifierAttribute as String) ?? ""
        let frame = DockAXReader.frame(element)
        let kids = DockAXReader.children(element)

        var line = "\(indent)\(role)"
        if !subrole.isEmpty { line += " sub=\(subrole)" }
        if !title.isEmpty { line += " title=\"\(title.prefix(60))\"" }
        if !description.isEmpty { line += " desc=\"\(description.prefix(60))\"" }
        if !identifier.isEmpty { line += " id=\(identifier)" }
        if let frame { line += " frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))" }
        if let wid = DockAXReader.number(element, "wid") { line += " wid=\(wid)" }
        if let displayID = DockAXReader.number(element, "AXDisplayID") { line += " displayID=\(displayID)" }
        line += " children=\(kids.count)"

        // For anything thumbnail-sized, also list every attribute and action,
        // since the title may have moved to another attribute.
        if role != "AXDockItem", let frame, frame.width > 60, frame.height > 40, kids.count <= 3 {
            var names: CFArray?
            if AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] {
                line += " attrs=[\(names.joined(separator: ","))]"
            }
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success, let actions = actions as? [String], !actions.isEmpty {
                line += " actions=[\(actions.joined(separator: ","))]"
            }
        }
        lines.append(line)

        guard depth < maxDepth else {
            if !kids.isEmpty { lines.append("\(indent)  # depth limit") }
            return
        }
        for child in kids {
            walk(child, depth: depth + 1, into: &lines)
        }
    }
}

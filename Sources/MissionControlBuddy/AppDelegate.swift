import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private let enhancer = MissionControlEnhancer()
    private let preferencesController = PreferencesWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance policy: the newest launch wins. Terminate any other
        // copies already running so we cleanly override the old process.
        terminateOtherInstances()

        // Accessory apps don't get an app icon automatically; set it so it shows
        // in About panels, ⌘-Tab, and anywhere AppKit asks for the app icon.
        if let icon = AppInfo.icon {
            NSApp.applicationIconImage = icon
        }

        ensureAccessibilityPermission()

        preferencesController.overlayEnabledProvider = { [weak self] in
            self?.enhancer.isEnabled ?? true
        }
        preferencesController.setOverlayEnabled = { [weak self] enabled in
            guard let self else { return }
            self.enhancer.setEnabled(enabled)
            self.statusBarController?.rebuildMenu()
        }
        preferencesController.menuIconVisibilityChanged = { [weak self] visible in
            self?.statusBarController?.isVisible = visible
        }
        preferencesController.quitHandler = {
            NSApp.terminate(nil)
        }

        statusBarController = StatusBarController(enhancer: enhancer) { [weak self] in
            self?.preferencesController.showAndFocus()
        }
        statusBarController?.isVisible = PreferencesStore.shared.showMenuBarIcon

        enhancer.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: PreferencesStore.changedNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        enhancer.stop()
        statusBarController = nil
    }

    /// If the menu bar icon is hidden, relaunching/opening the app should bring
    /// preferences so users still have a control surface.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !PreferencesStore.shared.showMenuBarIcon {
            preferencesController.showAndFocus()
            return false
        }
        return true
    }

    @objc private func preferencesChanged() {
        statusBarController?.isVisible = PreferencesStore.shared.showMenuBarIcon
        statusBarController?.rebuildMenu()
    }

    /// Enforces a single running instance: kills every other copy of this app
    /// so the newest launch takes over. Matches by bundle identifier when
    /// available (the .app), falling back to the executable URL for `swift run`.
    private func terminateOtherInstances() {
        let me = NSRunningApplication.current
        let others: [NSRunningApplication]

        if let bundleID = Bundle.main.bundleIdentifier {
            others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me.processIdentifier }
        } else {
            let myURL = me.executableURL
            others = NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != me.processIdentifier && $0.executableURL == myURL
            }
        }

        guard !others.isEmpty else { return }

        for app in others {
            if !app.terminate() {   // ask nicely first
                app.forceTerminate() // then insist
            }
        }

        // Give the OS a brief moment to release the old status item / resources.
        let deadline = Date().addingTimeInterval(2.0)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Prompts for Accessibility permission if not already granted. The Dock AX
    /// tree (where Mission Control thumbnails live) is unreadable without it.
    private func ensureAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Diagnostics.log("accessibility trusted at launch = \(trusted)")
        if !trusted {
            let alert = NSAlert()
            alert.messageText = "Accessibility permission needed"
            alert.informativeText = """
            MissionControlBuddy needs Accessibility access to read Mission Control \
            thumbnails.

            Open System Settings → Privacy & Security → Accessibility, enable this \
            app (or your terminal if running via 'swift run'), then relaunch.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

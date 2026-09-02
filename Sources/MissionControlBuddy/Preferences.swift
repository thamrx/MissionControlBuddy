import AppKit

/// How to handle window titles that are too long for the chip.
enum LongTextBehavior: String, CaseIterable {
    case truncate
    case wrap

    var displayName: String {
        switch self {
        case .truncate: return "Cut with …"
        case .wrap: return "Wrap (2 lines)"
        }
    }
}

/// User-tunable overlay appearance settings, persisted in UserDefaults.
/// Posts `.overlayPreferencesChanged` whenever a value changes so the enhancer
/// can restyle currently-visible chips live.
@MainActor
final class PreferencesStore {

    static let shared = PreferencesStore()

    static let changedNotification = Notification.Name("MissionControlBuddy.overlayPreferencesChanged")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let chipScale = "chipScale"
        static let backgroundHex = "chipBackgroundHex"
        static let backgroundOpacity = "chipBackgroundOpacity"
        static let longText = "chipLongTextBehavior"
        static let titleLimitEnabled = "chipTitleLimitEnabled"
        static let maxTitleChars = "chipMaxTitleChars"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    private init() {
        defaults.register(defaults: [
            Key.chipScale: 1.0,
            Key.backgroundHex: "#000000",
            Key.backgroundOpacity: 0.72,
            Key.longText: LongTextBehavior.truncate.rawValue,
            Key.titleLimitEnabled: true,
            Key.maxTitleChars: 50,
            Key.showMenuBarIcon: true
        ])
    }

    // MARK: - Values

    /// Scale multiplier for chip size (icon + fonts + paddings). 0.6 … 1.8.
    var chipScale: Double {
        get { defaults.double(forKey: Key.chipScale) }
        set { set(newValue.clamped(0.6, 1.8), forKey: Key.chipScale) }
    }

    var backgroundHex: String {
        get { defaults.string(forKey: Key.backgroundHex) ?? "#000000" }
        set { set(newValue, forKey: Key.backgroundHex) }
    }

    /// Chip background opacity, 0 … 1.
    var backgroundOpacity: Double {
        get { defaults.double(forKey: Key.backgroundOpacity) }
        set { set(newValue.clamped(0.0, 1.0), forKey: Key.backgroundOpacity) }
    }

    var longTextBehavior: LongTextBehavior {
        get { LongTextBehavior(rawValue: defaults.string(forKey: Key.longText) ?? "") ?? .truncate }
        set { set(newValue.rawValue, forKey: Key.longText) }
    }

    /// Whether the window title is cut after `maxTitleChars` characters.
    /// When false the chip width is the only limit.
    var titleLimitEnabled: Bool {
        get { defaults.bool(forKey: Key.titleLimitEnabled) }
        set { set(newValue, forKey: Key.titleLimitEnabled) }
    }

    /// Maximum number of characters of the window title before it is cut with
    /// an ellipsis. Only applied when `titleLimitEnabled` is true.
    var maxTitleChars: Int {
        get { defaults.integer(forKey: Key.maxTitleChars) }
        set { set(Swift.min(Swift.max(newValue, 5), 200), forKey: Key.maxTitleChars) }
    }

    /// The character limit to apply, or 0 for none.
    var effectiveMaxTitleChars: Int {
        titleLimitEnabled ? maxTitleChars : 0
    }

    /// The resolved background color (hex + opacity).
    var backgroundColor: NSColor {
        (NSColor(hex: backgroundHex) ?? .black).withAlphaComponent(CGFloat(backgroundOpacity))
    }

    /// Show the menu bar icon when true.
    var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// Restore every setting to its default value.
    func resetToDefaults() {
        for key in [Key.chipScale, Key.backgroundHex, Key.backgroundOpacity, Key.longText,
                    Key.titleLimitEnabled, Key.maxTitleChars, Key.showMenuBarIcon] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    // MARK: - Helpers

    private func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}

private extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double {
        Swift.min(Swift.max(self, lower), upper)
    }
}

extension NSColor {
    /// Create a color from a "#RRGGBB" hex string.
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }

        let red = CGFloat((value & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((value & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(value & 0x0000FF) / 255.0
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1.0)
    }

    /// "#RRGGBB" representation (ignores alpha).
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

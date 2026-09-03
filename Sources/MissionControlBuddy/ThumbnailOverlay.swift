import AppKit

/// A borderless, click-through overlay that sits on top of a single Mission
/// Control thumbnail and shows the app icon + name (+ window title).
final class ThumbnailOverlayWindow: NSWindow {

    private var lastAppName: String?
    private var lastWindowTitle: String?
    private var lastIcon: NSImage?
    private var lastStyleToken: String?

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

        contentView = ThumbnailLabelView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    func setFrameIfNeeded(_ newFrame: NSRect) {
        if frame != newFrame {
            setFrame(newFrame, display: false, animate: false)
        }
    }

    /// Update content and/or style only when something changed.
    func updateIfNeeded(icon: NSImage?, appName: String, windowTitle: String, style: ChipStyle) {
        let styleToken = style.token
        if appName == lastAppName,
           windowTitle == lastWindowTitle,
           icon === lastIcon,
           styleToken == lastStyleToken {
            return
        }
        lastAppName = appName
        lastWindowTitle = windowTitle
        lastIcon = icon
        lastStyleToken = styleToken
        (contentView as? ThumbnailLabelView)?.configure(icon: icon, appName: appName, windowTitle: windowTitle, style: style)
    }
}

/// Resolved chip appearance derived from user preferences.
struct ChipStyle {
    let scale: Double
    let backgroundColor: NSColor
    let longTextBehavior: LongTextBehavior
    /// 0 = no character limit.
    let maxTitleChars: Int
    let showIcon: Bool
    let showAppName: Bool
    let showWindowTitle: Bool
    let showCloseButton: Bool

    /// Cheap change-detection token.
    var token: String {
        "\(scale)|\(backgroundColor.hexString)|\(backgroundColor.alphaComponent)|\(longTextBehavior.rawValue)|\(maxTitleChars)|\(showIcon)|\(showAppName)|\(showWindowTitle)|\(showCloseButton)"
    }

    /// Applies the character limit to a window title, appending an ellipsis
    /// when something was cut off.
    func limitedTitle(_ title: String) -> String {
        guard maxTitleChars > 0, title.count > maxTitleChars else { return title }
        let kept = title.prefix(maxTitleChars).trimmingCharacters(in: .whitespaces)
        return kept + "\u{2026}"
    }

    static func current() -> ChipStyle {
        MainActor.assumeIsolated {
            let prefs = PreferencesStore.shared
            return ChipStyle(
                scale: prefs.chipScale,
                backgroundColor: prefs.backgroundColor,
                longTextBehavior: prefs.longTextBehavior,
                maxTitleChars: prefs.effectiveMaxTitleChars,
                showIcon: prefs.showIcon,
                showAppName: prefs.showAppName,
                showWindowTitle: prefs.showWindowTitle,
                showCloseButton: prefs.showCloseButton
            )
        }
    }
}

/// Draws a compact solid pill (icon + app name + window title) pinned to the
/// bottom-left of the thumbnail. Rebuilt on each configure() so size/color/wrap
/// preferences apply cleanly.
final class ThumbnailLabelView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: NSImage?, appName: String, windowTitle: String, style: ChipStyle) {
        subviews.forEach { $0.removeFromSuperview() }

        let scale = CGFloat(style.scale)
        let iconSize = 28 * scale
        let hPad = 6 * scale
        let vPad = 4 * scale
        let spacing = 6 * scale
        let appFontSize = 12 * scale
        let titleFontSize = 10 * scale
        let inset = 6 * scale

        let windowTitle = style.limitedTitle(windowTitle)
        let showIcon = style.showIcon && icon != nil
        let showApp = style.showAppName
        // The title is redundant when it equals the app name that is already shown.
        let showTitle = style.showWindowTitle && !windowTitle.isEmpty && !(showApp && windowTitle == appName)
        guard showIcon || showApp || showTitle else { return }

        let wrap = style.longTextBehavior == .wrap

        // Chip may not exceed the thumbnail width (minus insets).
        let maxChipWidth = max(120 * scale, bounds.width - inset * 2)
        let iconSpan = showIcon ? iconSize + ((showApp || showTitle) ? spacing : 0) : 0
        let maxTextWidth = max(40 * scale, maxChipWidth - iconSpan - hPad * 2)

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = style.backgroundColor.cgColor
        pill.layer?.cornerRadius = 8 * scale
        pill.layer?.masksToBounds = true
        addSubview(pill)

        var iconView: NSImageView?
        if showIcon {
            let view = NSImageView()
            view.image = icon
            view.imageScaling = .scaleProportionallyUpOrDown
            pill.addSubview(view)
            iconView = view
        }

        // Text lines, top to bottom, each with its measured height.
        var lines: [(label: NSTextField, height: CGFloat)] = []
        if showApp {
            let label = makeLabel(appName, size: appFontSize, weight: .semibold,
                                  color: .white, maxWidth: maxTextWidth,
                                  wrap: wrap, maxLines: wrap ? 2 : 1)
            let height = min(label.intrinsicContentSize.height, wrap ? appFontSize * 2.6 : appFontSize * 1.4)
            lines.append((label, height))
        }
        if showTitle {
            // Without the app name, the title takes the larger font.
            let size = showApp ? titleFontSize : appFontSize
            let label = makeLabel(windowTitle, size: size, weight: showApp ? .regular : .semibold,
                                  color: showApp ? NSColor.white.withAlphaComponent(0.8) : .white,
                                  maxWidth: maxTextWidth, wrap: wrap, maxLines: wrap ? 2 : 1)
            let height = min(label.intrinsicContentSize.height, wrap ? size * 2.6 : size * 1.4)
            lines.append((label, height))
        }
        lines.forEach { pill.addSubview($0.label) }

        // Measure.
        let textWidth = lines.map { min($0.label.intrinsicContentSize.width, maxTextWidth) }.max() ?? 0
        let lineGap = 1 * CGFloat(max(0, lines.count - 1))
        let textBlockHeight = lines.map(\.height).reduce(0, +) + lineGap

        let chipWidth = min(maxChipWidth, hPad * 2 + iconSpan + textWidth)
        let chipHeight = max(showIcon ? iconSize + vPad * 2 : 0, textBlockHeight + vPad * 2)

        pill.frame = NSRect(x: inset, y: inset, width: chipWidth, height: chipHeight)
        iconView?.frame = NSRect(x: hPad, y: (chipHeight - iconSize) / 2, width: iconSize, height: iconSize)

        let textX = hPad + iconSpan
        let textWidthFinal = max(10, chipWidth - textX - hPad)
        var y = (chipHeight + textBlockHeight) / 2 // top of the vertically centred text block
        for line in lines {
            y -= line.height
            line.label.frame = NSRect(x: textX, y: y, width: textWidthFinal, height: line.height)
            y -= 1
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight,
                           color: NSColor, maxWidth: CGFloat, wrap: Bool, maxLines: Int) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = maxLines
        label.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        label.preferredMaxLayoutWidth = maxWidth
        label.cell?.wraps = wrap
        label.cell?.isScrollable = !wrap

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        label.shadow = shadow
        return label
    }
}

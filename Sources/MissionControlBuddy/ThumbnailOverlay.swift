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

    /// Cheap change-detection token.
    var token: String {
        "\(scale)|\(backgroundColor.hexString)|\(backgroundColor.alphaComponent)|\(longTextBehavior.rawValue)|\(maxTitleChars)"
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
                maxTitleChars: prefs.effectiveMaxTitleChars
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

        // Chip may not exceed the thumbnail width (minus insets).
        let maxChipWidth = max(120 * scale, bounds.width - inset * 2)
        let maxTextWidth = max(40 * scale, maxChipWidth - iconSize - hPad * 3 - spacing)

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = style.backgroundColor.cgColor
        pill.layer?.cornerRadius = 8 * scale
        pill.layer?.masksToBounds = true
        addSubview(pill)

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        pill.addSubview(iconView)

        let windowTitle = style.limitedTitle(windowTitle)
        let showTitle = !windowTitle.isEmpty && windowTitle != appName
        let wrap = style.longTextBehavior == .wrap

        let appLabel = makeLabel(appName, size: appFontSize, weight: .semibold,
                                 color: .white, maxWidth: maxTextWidth,
                                 wrap: wrap, maxLines: wrap ? 2 : 1)
        pill.addSubview(appLabel)

        var titleLabel: NSTextField?
        if showTitle {
            let label = makeLabel(windowTitle, size: titleFontSize, weight: .regular,
                                  color: NSColor.white.withAlphaComponent(0.8),
                                  maxWidth: maxTextWidth, wrap: wrap, maxLines: wrap ? 2 : 1)
            pill.addSubview(label)
            titleLabel = label
        }

        // Measure.
        let appSize = appLabel.intrinsicContentSize
        let appHeight = min(appSize.height, wrap ? appFontSize * 2.6 : appFontSize * 1.4)
        let appWidth = min(appSize.width, maxTextWidth)

        var textWidth = appWidth
        var textBlockHeight = appHeight
        var titleHeight: CGFloat = 0
        if let titleLabel {
            let tSize = titleLabel.intrinsicContentSize
            titleHeight = min(tSize.height, wrap ? titleFontSize * 2.6 : titleFontSize * 1.4)
            textWidth = max(textWidth, min(tSize.width, maxTextWidth))
            textBlockHeight += titleHeight + 1
        }

        let chipWidth = min(maxChipWidth, iconSize + hPad * 3 + spacing + textWidth)
        let chipHeight = max(iconSize + vPad * 2, textBlockHeight + vPad * 2)

        pill.frame = NSRect(x: inset, y: inset, width: chipWidth, height: chipHeight)
        iconView.frame = NSRect(x: hPad, y: (chipHeight - iconSize) / 2, width: iconSize, height: iconSize)

        let textX = hPad + iconSize + spacing
        let textWidthFinal = max(10, chipWidth - textX - hPad)
        if let titleLabel {
            let topY = chipHeight - vPad - appHeight
            appLabel.frame = NSRect(x: textX, y: topY, width: textWidthFinal, height: appHeight)
            titleLabel.frame = NSRect(x: textX, y: topY - 1 - titleHeight, width: textWidthFinal, height: titleHeight)
        } else {
            appLabel.frame = NSRect(x: textX, y: (chipHeight - appHeight) / 2, width: textWidthFinal, height: appHeight)
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

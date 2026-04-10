import AppKit

enum MenuBarLabelFactory {
    static func makeLabel(timeText: String, isTracking: Bool, showSeconds: Bool) -> NSImage {
        let icon = MenuBarIconFactory.makeIcon(isTracking: isTracking)
        let size = NSSize(width: showSeconds ? 100 : 74, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 1

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .shadow: shadow
        ]

        let template = showSeconds ? "00h\u{2006}00m\u{2006}00s" : "00h\u{2006}00m"
        let templateSize = NSString(string: template).size(withAttributes: attributes)

        let iconSize = NSSize(width: 16, height: 16)
        let gap: CGFloat = 6
        let contentWidth = iconSize.width + gap + templateSize.width
        let contentOriginX = floor((size.width - contentWidth) / 2)

        let iconRect = NSRect(
            x: contentOriginX,
            y: floor((size.height - iconSize.height) / 2),
            width: iconSize.width,
            height: iconSize.height
        )
        icon.draw(in: iconRect)

        let textRect = NSRect(
            x: iconRect.maxX + gap,
            y: floor((size.height - templateSize.height) / 2),
            width: templateSize.width,
            height: templateSize.height
        )
        NSString(string: timeText).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

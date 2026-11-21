import AppKit

/// Draws the menu bar icon: one or two horizontal "battery" bars whose fill shows the
/// fraction of each limit that is still available.
enum StatusIcon {
    static let warningThreshold = 0.25
    static let criticalThreshold = 0.10

    /// - Parameters:
    ///   - fractions: remaining fraction (0...1) per bar, top to bottom; `nil` = unknown.
    ///   - dimmed: draw faded (stale data / error).
    static func image(fractions: [Double?], dimmed: Bool) -> NSImage {
        let width: CGFloat = 26
        let height: CGFloat = 16
        let barHeight: CGFloat = fractions.count > 1 ? 6 : 9
        let gap: CGFloat = 2
        let stackHeight = CGFloat(fractions.count) * barHeight + CGFloat(max(0, fractions.count - 1)) * gap
        let anyLow = fractions.contains { ($0 ?? 1) <= warningThreshold }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            // Template images are tinted by the system (perfect in light/dark menu bars);
            // when a limit is low we draw in color instead and use labelColor for the rest.
            let base: NSColor = anyLow ? .labelColor : .black
            let alpha: CGFloat = dimmed ? 0.35 : 1

            var y = ((height - stackHeight) / 2).rounded()
            for fraction in fractions {
                let outer = NSRect(x: 0.5, y: y + 0.5, width: width - 1, height: barHeight - 1)
                let outline = NSBezierPath(roundedRect: outer, xRadius: 2, yRadius: 2)
                outline.lineWidth = 1
                base.withAlphaComponent(alpha * (fraction == nil ? 0.5 : 0.9)).setStroke()
                outline.stroke()

                if let fraction, fraction > 0 {
                    let inner = outer.insetBy(dx: 1.5, dy: 1.5)
                    // Keep a visible sliver for tiny-but-nonzero values.
                    let fillWidth = max(1.5, inner.width * CGFloat(fraction))
                    let fillRect = NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height)
                    fillColor(for: fraction, base: base).withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()
                }
                y += barHeight + gap
            }
            return true
        }
        image.isTemplate = !anyLow
        image.accessibilityDescription = "Claude usage"
        return image
    }

    static func fillColor(for fraction: Double, base: NSColor) -> NSColor {
        if fraction <= criticalThreshold { return .systemRed }
        if fraction <= warningThreshold { return .systemOrange }
        return base
    }
}

/// A non-interactive menu row: title + "% left", a bar, and the reset time.
final class UsageRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = BarView()

    static let width: CGFloat = 300

    init(title: String, remainingFraction: Double, usedPercent: Int, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: UsageRowView.width, height: 52))

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor

        let remaining = Int((remainingFraction * 100).rounded())
        valueLabel.stringValue = "\(remaining)% left · \(usedPercent)% used"
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor

        bar.fraction = remainingFraction

        let inset: CGFloat = 14
        let inner = UsageRowView.width - inset * 2
        titleLabel.frame = NSRect(x: inset, y: 4, width: inner * 0.5, height: 17)
        valueLabel.frame = NSRect(x: inset + inner * 0.4, y: 5, width: inner * 0.6, height: 16)
        bar.frame = NSRect(x: inset, y: 24, width: inner, height: 6)
        detailLabel.frame = NSRect(x: inset, y: 33, width: inner, height: 15)
        for view in [titleLabel, valueLabel, bar, detailLabel] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

private final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        guard fraction > 0 else { return }
        var fill = bounds
        fill.size.width = max(3, bounds.width * CGFloat(min(1, fraction)))
        let color = StatusIcon.fillColor(for: fraction, base: .controlAccentColor)
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

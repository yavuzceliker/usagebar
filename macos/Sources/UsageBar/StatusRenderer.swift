import AppKit

/// Draws the compact menu bar item: blinking dot, amount, two tiny vertical bars.
enum StatusRenderer {
    static func image(text: String, tag: String? = nil, ratio: Double, meters: [Double?], dotOn: Bool) -> NSImage {
        let tagFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let tagSize = tag.map { ($0 as NSString).size(withAttributes: [.font: tagFont]) } ?? .zero
        let tagWidth = tag == nil ? 0 : ceil(tagSize.width) + 10 + 5  // pill padding + gap
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let textSize = (text as NSString).size(withAttributes: [.font: font])

        let height: CGFloat = 22
        let dot: CGFloat = 7
        let gap: CGFloat = 5
        let barW: CGFloat = 3.5
        let barGap: CGFloat = 2
        let barH: CGFloat = 13
        let bars = Array(meters.prefix(2))
        let barsWidth = bars.isEmpty ? 0 : CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * barGap
        let width = ceil(dot + gap + tagWidth + textSize.width + (bars.isEmpty ? 0 : gap + 1 + barsWidth)) + 1

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // Runs at draw time, so labelColor follows the menu bar's light/dark appearance.
            Heat.nsColor(ratio, alpha: dotOn ? 1 : 0.19).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: (height - dot) / 2, width: dot, height: dot)).fill()

            var x = dot + gap
            if let tag {
                // A filled pill keeps the label readable on both light and dark (and tinted) menu bars.
                let pill = NSRect(x: x, y: (height - 15) / 2, width: ceil(tagSize.width) + 10, height: 15)
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                (tag as NSString).draw(at: NSPoint(x: x + 5, y: pill.midY - tagSize.height / 2),
                                       withAttributes: [.font: tagFont, .foregroundColor: NSColor.labelColor])
                x += tagWidth
            }
            (text as NSString).draw(at: NSPoint(x: x, y: (height - textSize.height) / 2),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            x += textSize.width + gap + 1

            let y = (height - barH) / 2
            for pct in bars {
                let track = NSRect(x: x, y: y, width: barW, height: barH)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1.2, yRadius: 1.2).fill()
                if let pct, pct > 0 {
                    let p = min(100, pct) / 100
                    let fill = NSRect(x: x, y: y, width: barW, height: max(1.5, barH * p))
                    Heat.nsColor(p).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
                }
                x += barW + barGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

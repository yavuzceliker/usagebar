import AppKit
import SwiftUI

/// Same blue → amber → orange → red ramp as the Windows version.
enum Heat {
    private static let stops: [(Double, Double, Double, Double)] = [
        (0.00, 82, 163, 255),
        (0.45, 232, 160, 48),
        (0.75, 240, 96, 48),
        (1.00, 232, 64, 64),
    ]

    static func nsColor(_ ratio: Double, alpha: CGFloat = 1) -> NSColor {
        let r = min(1, max(0, ratio))
        var i = 0
        for n in 0..<(stops.count - 1) where r >= stops[n].0 { i = n }
        let a = stops[i]
        let b = stops[min(i + 1, stops.count - 1)]
        let span = b.0 - a.0
        let t = span > 0 ? (r - a.0) / span : 0
        func mix(_ x: Double, _ y: Double) -> CGFloat { CGFloat((x + (y - x) * t) / 255) }
        return NSColor(srgbRed: mix(a.1, b.1), green: mix(a.2, b.2), blue: mix(a.3, b.3), alpha: alpha)
    }

    static func color(_ ratio: Double) -> Color { Color(nsColor: nsColor(ratio)) }

    /// Blink period in seconds; faster as the limit gets closer.
    static func blinkInterval(ratio: Double, flashing: Bool) -> TimeInterval {
        if flashing { return 0.18 }
        if ratio >= 0.90 { return 0.24 }
        if ratio >= 0.70 { return 0.38 }
        if ratio >= 0.45 { return 0.62 }
        return 0.98
    }
}

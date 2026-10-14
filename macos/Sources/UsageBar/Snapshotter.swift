import AppKit
import SwiftUI

/// `UsageBar --snapshot <dir> [--demo]`: fetches every account once (or uses fake demo data) and writes PNGs of the
/// menu bar item and the popover (light + dark). Handy for README screenshots and debugging.
@MainActor
enum Snapshotter {
    static func run(outputDir: String, demo: Bool = false) async {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = AppModel()
        if demo { model.loadDemo() } else { await model.tick(force: true) }
        for account in model.visibleAccounts {
            let state = model.state(account)
            print("\(account.id): \(state.menuBarText)  error=\(state.error?.long ?? "-")")
        }

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            if let account = model.activeAccount {
                let state = model.state(account)
                let look = NSAppearance(named: appearance)!
                look.performAsCurrentDrawingAppearance {
                    let bar = StatusRenderer.image(text: state.menuBarText,
                                                   tag: model.visibleAccounts.count > 1 ? account.tag : nil,
                                                   ratio: state.ratio,
                                                   meters: state.snapshot?.meters.map(\.percent) ?? [], dotOn: true)
                    write(bar, background: name == "dark" ? .black : .white, scale: 3,
                          to: dir.appendingPathComponent("menubar-\(name).png"))
                }
            }
            let view = PopoverView(model: model, interactive: false)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage {
                write(image, background: nil, scale: 1, to: dir.appendingPathComponent("popover-\(name).png"))
            }
        }
    }

    private static func write(_ image: NSImage, background: NSColor?, scale: CGFloat, to url: URL) {
        let pad: CGFloat = background == nil ? 0 : 4
        let size = NSSize(width: (image.size.width + pad * 2) * scale, height: (image.size.height + pad * 2) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let background { background.setFill(); NSRect(origin: .zero, size: size).fill() }
        image.draw(in: NSRect(x: pad * scale, y: pad * scale, width: image.size.width * scale, height: image.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

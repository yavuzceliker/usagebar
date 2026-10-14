import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var pollTimer: Timer?
    private var blinkTimer: Timer?
    private var dotOn = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]  // popover grows/shrinks with the content, no scrolling
        popover.contentViewController = host

        model.onChange = { [weak self] in self?.redraw() }
        redraw()

        Task { await model.tick(force: true) }
        // Tick every 15s; each account decides whether it is due (Claude only every 60s).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.model.tick() }
        }
        scheduleBlink()

        // Refresh right after waking from sleep instead of waiting for the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model.tick(force: true) }
        }
    }

    private func scheduleBlink() {
        let active = model.activeAccount
        let interval = Heat.blinkInterval(ratio: active.map { model.state($0).ratio } ?? 0,
                                          flashing: active.map(model.isFlashing) ?? false)
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dotOn.toggle()
                self.redraw()
                self.scheduleBlink()
            }
        }
    }

    private func redraw() {
        guard let account = model.activeAccount else {
            statusItem.button?.image = StatusRenderer.image(text: "–", ratio: 0, meters: [], dotOn: false)
            statusItem.button?.toolTip = "UsageBar"
            return
        }
        let state = model.state(account)
        // Only label the item when there is more than one account to tell apart.
        let tag = model.visibleAccounts.count > 1 ? account.tag : nil
        statusItem.button?.image = StatusRenderer.image(text: state.menuBarText, tag: tag, ratio: state.ratio,
                                                        meters: state.snapshot?.meters.map(\.percent) ?? [], dotOn: dotOn)
        statusItem.button?.toolTip = state.error?.long ?? "\(account.provider.title) · \(account.title)"
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            Task { await model.tick() }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot") {
    let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
    Task { @MainActor in
        await Snapshotter.run(outputDir: dir, demo: args.contains("--demo"))
        exit(0)
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

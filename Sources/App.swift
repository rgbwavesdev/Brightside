import AppKit
import SwiftUI

@main
enum BrightsideMain {
    @MainActor
    static func main() {
        if CLI.run(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = DisplayStore.shared
        store.start()

        let host = NSHostingController(rootView: PopoverView().environment(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Brightside")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuitMenu()
        } else if popover.isShown {
            DisplayStore.shared.stopMatchByEye()
            popover.performClose(sender)
        } else {
            DisplayStore.shared.refreshLevels()
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    /// During Match by Eye the panel stays open while you look at the screens and click around. The sun in the
    /// menu bar, Stop, or quitting ends it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        DisplayStore.shared.matchByEye == nil
    }

    func popoverDidClose(_ notification: Notification) {
        DisplayStore.shared.stopMatchByEye()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayStore.shared.stopMatchByEye()
    }

    private func showQuitMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Brightside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
}

import AppKit
import SwiftUI

/// Headless commands for testing and scripting (run the binary inside the app bundle):
///   --list                          every display, how Brightside can control it, and its current level
///   --set <n|all> <0-100>           set the backlight over DDC (n is the number from --list)
///   --snapshot <file.png> [--dark] [--match-by-eye]
///                                   render the menu panel to an image, optionally as it looks after clicking Match by Eye
enum CLI {
    @MainActor
    static func run(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        switch args[1] {
        case "--list": list()
        case "--set": set(Array(args.dropFirst(2)))
        case "--snapshot": snapshot(Array(args.dropFirst(2)))
        default: return false
        }
        return true
    }

    private static func list() {
        let found = Discovery.scan()
        for (index, display) in found.enumerated() {
            var line = "\(index + 1). \(display.name) [\(display.key)] \(Discovery.detail(for: display, among: found))"
            if display.isApple {
                line += " — Apple display, macOS controls its brightness"
                if let level = DisplayServices.level(display.id) {
                    line += " (now \(Int((level.slider * 100).rounded()))%"
                    if let linear = level.linear { line += ", giving \(String(format: "%.1f", linear * 100))% of its light" }
                    line += ")"
                }
            } else if display.isBuiltin {
                line += " — built-in"
            } else if let channel = display.channel {
                if let level = channel.read(VCP.brightness) {
                    line += " — DDC brightness \(level.current)/\(level.max)"
                } else {
                    line += " — DDC connected, but it doesn't report a level"
                }
            } else {
                line += " — no DDC channel (software dimming only)"
            }
            print(line)
        }
    }

    private static func set(_ args: [String]) {
        guard args.count == 2, let percent = Int(args[1]), (0...100).contains(percent) else {
            print("usage: --set <n|all> <0-100>")
            exit(2)
        }
        let found = Discovery.scan()
        let targets: [FoundDisplay]
        if args[0] == "all" {
            targets = found.filter(\.needsUs)
        } else if let n = Int(args[0]), found.indices.contains(n - 1) {
            targets = [found[n - 1]]
        } else {
            print("No display \(args[0]); see --list")
            exit(2)
        }
        for display in targets {
            guard display.needsUs, let channel = display.channel else {
                print("\(display.name): no DDC channel")
                continue
            }
            let max = channel.read(VCP.brightness)?.max ?? 100
            channel.write(VCP.brightness, (percent * max + 50) / 100)
            usleep(100_000)
            if let level = channel.read(VCP.brightness) {
                print("\(display.name): now \(level.current)/\(level.max)")
            } else {
                print("\(display.name): sent \(percent)% (the monitor doesn't report its level back)")
            }
        }
    }

    @MainActor
    private static func snapshot(_ args: [String]) {
        guard let path = args.first else {
            print("usage: --snapshot <file.png> [--dark] [--match-by-eye]")
            exit(2)
        }
        let dark = args.contains("--dark")
        _ = NSApplication.shared
        let store = DisplayStore.shared
        store.rescan(applyDimming: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let the DDC reads land
        if args.contains("--match-by-eye") { store.requestMatchByEye() }   // only the panel changes; the XDR isn't touched
        let view = PopoverView()
            .environment(store)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.17) : Color(white: 0.94))
        // Drawn through a window that never comes on screen: ImageRenderer leaves placeholders where the switch and
        // the ⋯ menus go, since those are AppKit controls.
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("Couldn't render")
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("Couldn't render")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

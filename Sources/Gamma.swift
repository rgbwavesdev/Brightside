import CoreGraphics

/// Software dimming: scales a display's gamma table. Works on any screen, but only darkens the picture
/// (the backlight stays put), and macOS resets the table on its own after sleep or a display change.
/// Quartz restores every table when the app quits.
final class Gamma {
    static let shared = Gamma()

    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Table] = [:]
    private var factors: [CGDirectDisplayID: Float] = [:]

    var isDimmingAnything: Bool { !factors.isEmpty }

    func dim(_ id: CGDirectDisplayID, factor: Double) {
        guard factor < 0.999 else { return restore(id) }
        guard let base = original(id) else { return }
        factors[id] = Float(factor)
        apply(base, Float(factor), to: id)
    }

    func restore(_ id: CGDirectDisplayID) {
        factors[id] = nil
        if let base = originals.removeValue(forKey: id) { apply(base, 1, to: id) }
    }

    /// Puts the dimming back if macOS reset the table (wake, reconfiguration, profile change).
    func reapplyIfReset() {
        for (id, factor) in factors {
            guard let base = originals[id], let current = read(id), let last = current.red.last,
                  let expected = base.red.last.map({ $0 * factor }) else { continue }
            if abs(last - expected) > 0.01 { apply(base, factor, to: id) }
        }
    }

    private func original(_ id: CGDirectDisplayID) -> Table? {
        if let table = originals[id] { return table }
        guard let table = read(id) else { return nil }
        originals[id] = table
        return table
    }

    private func read(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity)), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        let n = Int(count)
        return Table(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    private func apply(_ base: Table, _ factor: Float, to id: CGDirectDisplayID) {
        var red = base.red.map { $0 * factor }, green = base.green.map { $0 * factor }, blue = base.blue.map { $0 * factor }
        CGSetDisplayTransferByTable(id, UInt32(red.count), &red, &green, &blue)
    }
}

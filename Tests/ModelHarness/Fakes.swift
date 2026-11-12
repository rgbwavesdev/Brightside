// Stand-ins for everything Model.swift touches on the hardware: no DDC, no gamma, no DisplayServices.
import CoreGraphics
import Foundation

struct AppleLevel: Equatable {
    let slider: Double
    let linear: Double?
}

final class DDCChannel {}

final class BacklightLink {
    static var sent: [String: Int] = [:]
    let label: String
    init(channel: DDCChannel, label: String) { self.label = label }
    func set(_ value: Int) { Self.sent[label] = value }
    func read(_ completion: @escaping ((current: Int, max: Int)?) -> Void) { completion(nil) }
}

struct FoundDisplay {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let isApple: Bool
    let isBuiltin: Bool
    let mirrors: CGDirectDisplayID
    let bounds: CGRect
    let rotation: Double
    let connection: String?
    let channel: DDCChannel?
    var needsUs: Bool { !isApple && !isBuiltin }
}

enum Discovery {
    static var displays: [FoundDisplay] = []
    static func scan() -> [FoundDisplay] { displays }
    static func detail(for display: FoundDisplay, among: [FoundDisplay]) -> String { display.connection ?? "" }
}

/// The XDR: its slider, and light from the curve measured on 2026-10-27 (nits / 500).
enum DisplayServices {
    static let appleID: CGDirectDisplayID = 9_000_001
    static var slider = 0.625
    static var auto = false
    static var onChange: (() -> Void)?
    static let table: [(Double, Double)] = [(0, 4), (1.0 / 16, 16.5), (2.0 / 16, 27.5), (4.0 / 16, 55), (6.0 / 16, 92),
                                            (8.0 / 16, 140), (12.0 / 16, 281), (1, 500)]

    static func brightness(_ id: CGDirectDisplayID) -> Double? { id == appleID ? slider : nil }
    static func level(_ id: CGDirectDisplayID) -> AppleLevel? {
        brightness(id).map { AppleLevel(slider: $0, linear: light($0)) }
    }
    static func light(_ s: Double) -> Double {
        let upper = table.firstIndex { $0.0 >= s } ?? table.count - 1
        guard upper > 0 else { return table[0].1 / 500 }
        let (x0, y0) = table[upper - 1], (x1, y1) = table[upper]
        return (y0 + (y1 - y0) * (s - x0) / (x1 - x0)) / 500
    }
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Double) { if id == appleID { slider = value } }
    static func autoBrightness(_ id: CGDirectDisplayID) -> Bool? { id == appleID ? auto : nil }
    static func observe(_ id: CGDirectDisplayID) {}
}

final class Gamma {
    static let shared = Gamma()
    var factors: [CGDirectDisplayID: Double] = [:]
    var isDimmingAnything: Bool { false }
    func dim(_ id: CGDirectDisplayID, factor: Double) { factors[id] = factor }
    func restore(_ id: CGDirectDisplayID) { factors[id] = nil }
    func reapplyIfReset() {}
}

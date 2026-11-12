import CoreGraphics
import Foundation

/// An Apple display's brightness: where its slider sits, and how much light that gives (nil if macOS won't say).
struct AppleLevel: Equatable {
    let slider: Double
    let linear: Double?
}

/// Brightness of Apple displays (the Pro Display XDR here) through the private DisplayServices framework, a thin client
/// of corebrightnessd that Control Center's slider also goes through. Looked up at runtime, like IOAVService in DDC.swift.
enum DisplayServices {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias FlagFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias Callback = @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?,
                                                 UnsafeRawPointer?, CFDictionary?) -> Void
    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, Callback) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getBrightness = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    private static let getLinearBrightness = symbol("DisplayServicesGetLinearBrightness", as: GetFn.self)
    private static let writeBrightness = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    private static let ambientCompensation = symbol("DisplayServicesAmbientLightCompensationEnabled", as: FlagFn.self)
    private static let register = symbol("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)
    private static var observed: Set<CGDirectDisplayID> = []

    /// Runs on the main thread after an observed display's brightness changes.
    static var onChange: (() -> Void)?

    /// The display's brightness slider, 0...1. Nil for displays macOS doesn't control, which return error 1000.
    static func brightness(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = -1
        guard let getBrightness, getBrightness(id, &value) == 0, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    /// The display's light output as a share of its maximum, 0...1. The slider isn't linear: on the XDR here,
    /// slider 1/16 gives 0.033 (16.5 of 500 nits), 1/2 gives 0.28, and 3/4 gives 0.56.
    static func linearBrightness(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = -1
        guard let getLinearBrightness, getLinearBrightness(id, &value) == 0, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    static func level(_ id: CGDirectDisplayID) -> AppleLevel? {
        brightness(id).map { AppleLevel(slider: $0, linear: linearBrightness(id)) }
    }

    /// Moves the display's brightness slider, as the brightness keys and Control Center do. Match by Eye steps the
    /// Apple display through its levels with this.
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        _ = writeBrightness?(id, Float(min(1, max(0, value))))
    }

    /// Whether auto-brightness ("Automatically adjust brightness") is on. It doesn't keep a level set with
    /// `setBrightness`: on the XDR here, a level set to 0 crept back up to the ambient level (0.12) within minutes.
    static func autoBrightness(_ id: CGDirectDisplayID) -> Bool? {
        var on = false
        guard let ambientCompensation, ambientCompensation(id, &on) == 0 else { return nil }
        return on
    }

    /// corebrightnessd reports every change, whoever made it: the brightness keys, Control Center, auto-brightness.
    static func observe(_ id: CGDirectDisplayID) {
        guard let register, !observed.contains(id) else { return }
        let result = register(id, UnsafeMutableRawPointer(bitPattern: UInt(id)), { _, _, _, _, _ in
            DispatchQueue.main.async { DisplayServices.onChange?() }
        })
        if result == 0 { observed.insert(id) }
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

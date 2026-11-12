import AppKit
import Observation
import ServiceManagement

enum DimMethod: String {
    case backlight   // DDC/CI: the monitor's own brightness setting
    case software    // gamma table: darkens the picture, works on anything
}

/// One external monitor in the menu. Everything here runs on the main thread; DDC work hops to its link's queue.
@Observable
final class Monitor: Identifiable {
    /// Share of the backlight slider that sits below the monitor's minimum, where gamma takes over.
    static let shadeRange = 0.3
    /// Gamma scale at the bottom of that range. Displays raise it to about the 2.2 power, so this leaves
    /// roughly 3% of the light the backlight gives at 0 (an LG at 0 looked like the XDR at 50%).
    static let shadeFloor = 0.2
    /// The Apple display level that looks like the backlight at 0. Matching maps the levels below it onto the shade range.
    static let appleLevelAtMinimum = 0.5
    /// The Apple display's light output at that level: 140 of the XDR's 500 nits (measured 2026-10-27). Its slider
    /// isn't linear, quadrupling the light in the first step up from 0, so below the knee matching follows light output.
    static let appleLinearAtMinimum = 0.28
    /// Matches saved closer together than this replace each other: just under half a brightness-key step (1/16).
    static let matchSpacing = 0.03

    let key: String
    var id: String { key }
    private(set) var name: String
    private(set) var detail: String
    private(set) var method: DimMethod
    /// The monitor's own brightness setting, 0...1.
    private(set) var backlightLevel: Double
    /// Extra darkening once the backlight is at 0: 0 = none, 1 = the floor.
    private(set) var shade: Double
    private(set) var dimsPastMinimum: Bool
    private(set) var softwareLevel: Double
    /// Nil until the first read finishes; false when the monitor has never answered with a valid level.
    private(set) var readable: Bool?
    private(set) var hasChannel: Bool
    /// The user has moved this monitor's backlight slider at least once.
    private(set) var adjusted: Bool
    /// Where the user matched this monitor to the Apple display by eye, in order of the Apple display's level.
    /// Moving the slider while matching saves one for the Apple display's current level.
    private(set) var matchPoints: [MatchPoint]

    @ObservationIgnored private(set) var displayID: CGDirectDisplayID
    @ObservationIgnored fileprivate var sortKey: (Int, CGFloat, CGFloat)
    @ObservationIgnored private var link: BacklightLink?
    @ObservationIgnored private var maxValue = 100
    @ObservationIgnored private var lastSent: Int?
    @ObservationIgnored private var sends = 0
    @ObservationIgnored private var matchedLevel: AppleLevel?   // the Apple display's brightness while matching it
    @ObservationIgnored var isDragging = false

    init(_ display: FoundDisplay, detail: String) {
        key = display.key
        name = display.name
        self.detail = detail
        displayID = display.id
        sortKey = Self.sortKey(display)
        hasChannel = display.channel != nil
        link = display.channel.map { BacklightLink(channel: $0, label: display.key) }
        let defaults = UserDefaults.standard
        let saved = DimMethod(rawValue: defaults.string(forKey: "\(display.key).method") ?? "")
        method = saved ?? (display.channel != nil ? .backlight : .software)
        backlightLevel = defaults.object(forKey: "\(display.key).backlight") as? Double ?? 1
        shade = defaults.object(forKey: "\(display.key).shade") as? Double ?? 0
        dimsPastMinimum = defaults.object(forKey: "\(display.key).pastMinimum") as? Bool ?? true
        softwareLevel = defaults.object(forKey: "\(display.key).software") as? Double ?? 1
        adjusted = defaults.bool(forKey: "\(display.key).adjusted")
        matchPoints = (defaults.array(forKey: "\(display.key).matches") ?? []).compactMap(MatchPoint.init(plist:))
        defaults.removeObject(forKey: "\(display.key).offset")   // one offset for every level, before matches (2026-10-27)
    }

    func update(_ display: FoundDisplay, detail: String) {
        if display.id != displayID { Gamma.shared.restore(displayID) }
        displayID = display.id
        sortKey = Self.sortKey(display)
        name = display.name
        self.detail = detail
        hasChannel = display.channel != nil
        link = display.channel.map { BacklightLink(channel: $0, label: display.key) }
        lastSent = nil
    }

    /// Slider position, 0...1. With dimming past the minimum, the backlight's 0...1 fills the top 70%.
    var level: Double {
        switch method {
        case .software:
            return softwareLevel
        case .backlight:
            guard dimsPastMinimum else { return backlightLevel }
            return shade > 0 ? Self.shadeRange * (1 - shade) : Self.shadeRange + (1 - Self.shadeRange) * backlightLevel
        }
    }

    var isShaded: Bool { method == .backlight && shade > 0 }

    /// Where the backlight bottoms out on the slider, when the slider goes past it.
    var shadeMarker: Double? { method == .backlight && dimsPastMinimum ? Self.shadeRange : nil }

    var note: String? {
        switch method {
        case .software:
            return hasChannel
                ? "Software dimming darkens the picture. The monitor's backlight stays where it is."
                : "This monitor has no DDC connection, so it's dimmed in software."
        case .backlight:
            if !hasChannel { return "No DDC connection found. Choose Software dimming from the ⋯ menu." }
            if readable == false {
                return adjusted
                    ? "This monitor doesn't report its level, so the slider shows the last value set here."
                    : "This monitor doesn't report its level, so the slider starts where you last left it. If moving it does nothing, choose Software dimming from the ⋯ menu."
            }
            return nil
        }
    }

    func userSet(_ value: Double) {
        let value = min(1, max(0, value))
        if let matchedLevel { remember(value, at: matchedLevel) }
        if method == .backlight { adjusted = true }
        setLevel(value)
    }

    /// Saves where the slider sits now as the match for this Apple display level, replacing any saved closer than
    /// `radius` (Next, in Match by Eye).
    func keepMatch(at appleLevel: AppleLevel, replacingWithin radius: Double) {
        remember(level, at: appleLevel, replacingWithin: radius)
        save()
    }

    func forgetMatches() {
        matchPoints = []
        save()
        match(matchedLevel)
    }

    private func remember(_ position: Double, at appleLevel: AppleLevel, replacingWithin radius: Double = Monitor.matchSpacing) {
        matchPoints.removeAll { abs($0.apple.slider - appleLevel.slider) < radius }
        matchPoints.append(MatchPoint(apple: appleLevel, position: position))
        matchPoints.sort { $0.apple.slider < $1.apple.slider }
    }

    /// Matching: puts the slider where it matches the Apple display, as adjusted by the user's matches. Moves that need
    /// the backlight wait until the target is a whole point away, so auto-brightness creeping by fractions doesn't keep
    /// DDC busy. Moves inside the shade only change gamma, so they follow closer: near the floor a whole point is
    /// about a third more light.
    func match(_ appleLevel: AppleLevel?) {
        matchedLevel = appleLevel
        guard let appleLevel, !isDragging else { return }
        let target = min(100, max(0, (position(matching: appleLevel) + adjustment(at: appleLevel)) * 100))
        let shadeOnly = shadeMarker.map { target < $0 * 100 && level < $0 } ?? false
        guard abs(target - level * 100) > (shadeOnly ? 0.25 : 0.99) else { return }
        setLevel(target / 100)
    }

    /// How far the user's matches move the slider from `position(matching:)`. At a saved level the slider lands exactly
    /// where the user put it, and between two saved levels the change blends in a straight line. Below the lowest saved
    /// level it shrinks to nothing at the darkest setting, and above the highest to nothing at the brightest, unless
    /// a match was saved at that end too.
    private func adjustment(at appleLevel: AppleLevel) -> Double {
        var knots = matchPoints.map { (x: $0.apple.slider, y: $0.position - position(matching: $0.apple)) }
        guard let first = knots.first, let last = knots.last else { return 0 }
        if first.x >= Self.matchSpacing { knots.insert((x: 0, y: 0), at: 0) }
        if last.x <= 1 - Self.matchSpacing { knots.append((x: 1, y: 0)) }
        let x = appleLevel.slider
        guard let upper = knots.firstIndex(where: { $0.x >= x }) else { return knots[knots.count - 1].y }
        guard upper > 0 else { return knots[0].y }
        let low = knots[upper - 1], high = knots[upper]
        return low.y + (high.y - low.y) * (x - low.x) / (high.x - low.x)
    }

    /// Slider position for an Apple display level, before the user's matches. With the shade range, the Apple display's upper
    /// half maps onto the backlight. Its lower half maps onto the shade by light output: the backlight sits at 0 and
    /// gamma scales the signal so the monitor gives off the same share of its minimum light as the Apple display gives
    /// of its light at the knee. Displays turn signal into light at about the 2.2 power, hence the 1/2.2.
    /// Without the shade range, the slider follows the Apple display's slider one to one.
    private func position(matching apple: AppleLevel) -> Double {
        guard method == .backlight, dimsPastMinimum else { return apple.slider }
        let knee = Self.appleLevelAtMinimum
        if apple.slider >= knee {
            return Self.shadeRange + (apple.slider - knee) / (1 - knee) * (1 - Self.shadeRange)
        }
        guard let linear = apple.linear else { return apple.slider / knee * Self.shadeRange }
        let signal = pow(min(1, linear / Self.appleLinearAtMinimum), 1 / 2.2)
        let shade = min(1, max(0, (1 - signal) / (1 - Self.shadeFloor)))
        return Self.shadeRange * (1 - shade)
    }

    private func setLevel(_ value: Double) {
        switch method {
        case .software:
            softwareLevel = value
        case .backlight:
            if dimsPastMinimum, value < Self.shadeRange {
                backlightLevel = 0
                let depth = 1 - value / Self.shadeRange
                shade = depth < 0.01 ? 0 : depth   // a hair under the line is rounding, not a choice
            } else {
                backlightLevel = dimsPastMinimum ? (value - Self.shadeRange) / (1 - Self.shadeRange) : value
                shade = 0
            }
            sendBacklight()
        }
        applyGamma()
        save()
    }

    func setMethod(_ newMethod: DimMethod) {
        guard newMethod != method else { return }
        method = newMethod
        applyGamma()
        if newMethod == .backlight { refresh(force: true) }
        save()
        match(matchedLevel)
    }

    func setDimsPastMinimum(_ on: Bool) {
        guard on != dimsPastMinimum else { return }
        dimsPastMinimum = on
        if !on {
            shade = 0
            applyGamma()
        }
        save()
        match(matchedLevel)
    }

    /// Puts back this monitor's gamma (software dimming, or the shade below the backlight's minimum).
    /// macOS drops gamma tables on wake, display changes and quit, so this runs after each of those.
    func applyGamma() {
        let factor = switch method {
        case .software: Self.softwareFactor(softwareLevel)
        case .backlight: 1 - shade * (1 - Self.shadeFloor)
        }
        Gamma.shared.dim(displayID, factor: factor)
    }

    /// Re-reads the monitor's own level, since its buttons may have changed it. Monitors that never answered
    /// are only retried when forced, to keep the bus quiet.
    func refresh(force: Bool = false) {
        guard method == .backlight, let link, force || readable != false else { return }
        let sendsBefore = sends
        link.read { [weak self] result in
            guard let self else { return }
            guard let result else {
                if readable == nil { readable = false }
                return
            }
            readable = true
            maxValue = max(result.max, 1)
            // Matching can send at any moment; a value sent after this read was queued is newer than what it found.
            guard sends == sendsBefore else { return }
            lastSent = result.current
            guard !isDragging, method == .backlight else { return }
            backlightLevel = min(1, Double(result.current) / Double(maxValue))
            if result.current > 0, shade > 0 {   // turned up with the monitor's own buttons
                shade = 0
                applyGamma()
            }
            save()
        }
    }

    /// Only sends when the monitor's value actually changes, so dragging through the shade stays off the bus.
    private func sendBacklight() {
        let value = Int((backlightLevel * Double(maxValue)).rounded())
        guard value != lastSent else { return }
        lastSent = value
        sends += 1
        link?.set(value)
    }

    /// Slider 0 still leaves a tenth of the signal, so a dimmed screen can't go fully black.
    private static func softwareFactor(_ level: Double) -> Double { 0.1 + 0.9 * level }

    private static func sortKey(_ display: FoundDisplay) -> (Int, CGFloat, CGFloat) {
        (display.mirrors == 0 ? 0 : 1, display.bounds.minX, display.bounds.minY)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(method.rawValue, forKey: "\(key).method")
        defaults.set(backlightLevel, forKey: "\(key).backlight")
        defaults.set(shade, forKey: "\(key).shade")
        defaults.set(dimsPastMinimum, forKey: "\(key).pastMinimum")
        defaults.set(softwareLevel, forKey: "\(key).software")
        defaults.set(adjusted, forKey: "\(key).adjusted")
        defaults.set(matchPoints.map(\.plist), forKey: "\(key).matches")
    }
}

/// The Apple display whose brightness the monitors can match (the Pro Display XDR here).
struct MatchSource: Equatable {
    let id: CGDirectDisplayID
    let name: String
}

/// One level where the user matched a monitor to the Apple display by eye.
struct MatchPoint: Equatable {
    let apple: AppleLevel
    /// The monitor's slider, 0...1.
    let position: Double
}

extension MatchPoint {
    init?(plist: Any) {
        guard let values = plist as? [String: Double], let slider = values["apple"], let position = values["monitor"]
        else { return nil }
        self.init(apple: AppleLevel(slider: slider, linear: values["appleLight"]), position: position)
    }

    var plist: [String: Double] {
        var values = ["apple": apple.slider, "monitor": position]
        values["appleLight"] = apple.linear
        return values
    }
}

/// Where Match by Eye is: it steps the Apple display through the brightness keys' levels, darkest first.
struct MatchByEye: Equatable {
    static let keyStep = 1.0 / 16
    static let levels = (0...16).map { Double($0) * keyStep }
    var index = 0
    /// The Apple display's level before Match by Eye started. It goes back there at the end.
    let returnTo: Double

    var level: Double { Self.levels[index] }
    var isLast: Bool { index == Self.levels.count - 1 }
}

@Observable
final class DisplayStore {
    static let shared = DisplayStore()

    private(set) var monitors: [Monitor] = []
    private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    /// An Apple display whose brightness can be read; nil when none is connected.
    private(set) var matchSource: MatchSource?
    private(set) var isMatching = UserDefaults.standard.bool(forKey: "matchAppleDisplay")
    /// One slider moves every monitor, so a pair can be matched to the Apple display together. On unless turned off.
    private(set) var movesTogether = UserDefaults.standard.object(forKey: "moveTogether") as? Bool ?? true
    /// Set while Match by Eye steps the Apple display through its levels.
    private(set) var matchByEye: MatchByEye?
    /// Auto-brightness on the Apple display. Match by Eye needs it off: it drags the display away from each level.
    private(set) var appleAutoBrightness = false
    /// Match by Eye was asked for while auto-brightness was on, so the panel explains how to turn it off.
    private(set) var matchByEyeWaitsForAutoBrightness = false

    @ObservationIgnored private var dragStart: [String: Double] = [:]   // each moving monitor's level when a drag began
    @ObservationIgnored private var rescanWork: DispatchWorkItem?
    @ObservationIgnored private var gammaTimer: Timer?
    @ObservationIgnored private var matchTimer: Timer?
    @ObservationIgnored private var running = false

    /// App mode: watch for display changes, keep gamma dimming applied, and follow the Apple display when matching.
    func start() {
        running = true
        DisplayServices.onChange = { DisplayStore.shared.match() }
        rescan()
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayStore.shared.scheduleRescan(after: 1) }
        }, nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DisplayStore.shared.scheduleRescan(after: 2)
            }
        }
        gammaTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            if Gamma.shared.isDimmingAnything { Gamma.shared.reapplyIfReset() }
        }
    }

    func scheduleRescan(after delay: TimeInterval) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func rescan(applyDimming: Bool = true) {
        let found = Discovery.scan()
        var next: [Monitor] = []
        for display in found where display.needsUs {
            let detail = Discovery.detail(for: display, among: found)
            if let existing = monitors.first(where: { $0.key == display.key }) {
                existing.update(display, detail: detail)
                next.append(existing)
            } else {
                next.append(Monitor(display, detail: detail))
            }
        }
        monitors = next.sorted { $0.sortKey < $1.sortKey }   // left to right, mirrors last
        for monitor in monitors {
            if applyDimming { monitor.applyGamma() }
            monitor.refresh(force: true)
        }
        let apple = found.filter { !$0.needsUs && DisplayServices.brightness($0.id) != nil }
        matchSource = (apple.first { CGDisplayIsMain($0.id) != 0 } ?? apple.first).map { MatchSource(id: $0.id, name: $0.name) }
        if matchSource == nil { matchByEye = nil }
        updateAutoBrightness()
        updateMatching()
    }

    /// Called when the menu opens.
    func refreshLevels() {
        monitors.forEach { $0.refresh() }
        updateAutoBrightness()
    }

    /// Re-reads auto-brightness; only a change is stored, so the panel doesn't redraw on every 2 s check.
    private func updateAutoBrightness() {
        let on = matchSource.flatMap { DisplayServices.autoBrightness($0.id) } ?? false
        if on != appleAutoBrightness { appleAutoBrightness = on }
        if !on, matchByEyeWaitsForAutoBrightness { matchByEyeWaitsForAutoBrightness = false }
    }

    func setMatching(_ on: Bool) {
        isMatching = on
        UserDefaults.standard.set(on, forKey: "matchAppleDisplay")
        updateMatching()
    }

    /// The change notification covers the brightness keys, Control Center and auto-brightness. The 2 s check is for
    /// one that goes missing (sleep, a reconnect, corebrightnessd restarting); it costs one XPC call.
    private func updateMatching() {
        guard running else { return }   // command-line runs never send anything on their own
        let active = isMatching && matchSource != nil
        if active, let matchSource { DisplayServices.observe(matchSource.id) }
        if active, matchTimer == nil {
            matchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in DisplayStore.shared.match() }
            matchTimer?.tolerance = 0.5
        } else if !active {
            matchTimer?.invalidate()
            matchTimer = nil
        }
        match()
    }

    private func match() {
        let level = isMatching ? matchSource.flatMap { DisplayServices.level($0.id) } : nil
        monitors.forEach { $0.match(level) }
        updateAutoBrightness()
    }

    func setMovesTogether(_ on: Bool) {
        movesTogether = on
        UserDefaults.standard.set(on, forKey: "moveTogether")
    }

    /// A slider the user moved. With Move Together on, the others move by the same amount, like linked faders, so
    /// monitors that sit apart keep their difference and turning the option on or off never makes one jump.
    /// During a drag, the amount counts from where each monitor started, so one pinned at an end comes back with it.
    func userSet(_ monitor: Monitor, to value: Double) {
        guard movesTogether else { return monitor.userSet(value) }
        let amount = value - (dragStart[monitor.key] ?? monitor.level)
        for each in monitors {
            each.userSet(each === monitor ? value : (dragStart[each.key] ?? each.level) + amount)
        }
    }

    func setDragging(_ monitor: Monitor, _ dragging: Bool) {
        let moving = movesTogether ? monitors : [monitor]
        dragStart = dragging ? Dictionary(uniqueKeysWithValues: moving.map { ($0.key, $0.level) }) : [:]
        for each in dragging ? moving : monitors { each.isDragging = dragging }   // letting go frees every monitor
    }

    /// The Match by Eye button. With auto-brightness on it doesn't start: auto-brightness would pull the Apple display
    /// away from every level within seconds to minutes, and the monitors would slide along with it.
    func requestMatchByEye() {
        updateAutoBrightness()
        if appleAutoBrightness { matchByEyeWaitsForAutoBrightness = true } else { startMatchByEye() }
    }

    /// Match by Eye: the Apple display steps through the brightness keys' levels so each monitor can be matched at
    /// every one. Stopping, finishing or quitting puts the Apple display back where it was.
    func startMatchByEye() {
        guard isMatching, let matchSource, let now = DisplayServices.brightness(matchSource.id) else { return }
        matchByEye = MatchByEye(returnTo: now)
        showMatchByEyeLevel()
    }

    /// Saves every monitor's place at this level as its match, then moves on, or finishes after the brightest.
    /// On the step itself (the usual case), it clears out to just short of the neighboring steps, so a full pass
    /// leaves one match per step and nothing left over from earlier tries in between.
    func nextMatchByEyeLevel() {
        guard var step = matchByEye, let matchSource else { return }
        if let level = DisplayServices.level(matchSource.id) {
            let onStep = abs(level.slider - step.level) < 0.005
            let radius = onStep ? MatchByEye.keyStep - 0.005 : Monitor.matchSpacing
            monitors.forEach { $0.keepMatch(at: level, replacingWithin: radius) }
        }
        guard !step.isLast else { return stopMatchByEye() }
        step.index += 1
        matchByEye = step
        showMatchByEyeLevel()
    }

    func previousMatchByEyeLevel() {
        guard var step = matchByEye, step.index > 0 else { return }
        step.index -= 1
        matchByEye = step
        showMatchByEyeLevel()
    }

    func stopMatchByEye() {
        guard let step = matchByEye else { return }
        matchByEye = nil
        if let matchSource { DisplayServices.setBrightness(matchSource.id, step.returnTo) }
    }

    private func showMatchByEyeLevel() {
        guard running, let matchByEye, let matchSource else { return }   // a command-line snapshot only shows the panel
        DisplayServices.setBrightness(matchSource.id, matchByEye.level)
        match()   // the change notification follows, but there's no need to wait for it
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Brightside: couldn't change the login item: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        if on, status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

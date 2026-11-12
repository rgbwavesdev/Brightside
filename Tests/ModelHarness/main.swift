// Runs the real Model.swift against fake displays and checks Move Together, the auto-brightness gate and Match by Eye.
import CoreGraphics
import Foundation

let domain = "brightside-harness"
UserDefaults.standard.removePersistentDomain(forName: domain)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.0005) -> Bool { abs(a - b) < tolerance }
func f(_ x: Double) -> String { String(format: "%.4f", x) }

let channel = DDCChannel()
func lg(_ id: CGDirectDisplayID, _ key: String, _ connection: String, x: CGFloat) -> FoundDisplay {
    FoundDisplay(id: id, key: key, name: "LG HDR 4K", isApple: false, isBuiltin: false, mirrors: 0,
                 bounds: CGRect(x: x, y: 0, width: 100, height: 100), rotation: 90, connection: connection, channel: channel)
}
Discovery.displays = [
    FoundDisplay(id: DisplayServices.appleID, key: "1552-1-1", name: "Pro Display XDR", isApple: true, isBuiltin: false,
                 mirrors: 0, bounds: .zero, rotation: 0, connection: nil, channel: nil),
    lg(9_000_002, "test-dp", "DisplayPort", x: 100),
    lg(9_000_003, "test-hdmi", "HDMI", x: 200),
]

let store = DisplayStore.shared
store.start()
let a = store.monitors[0], b = store.monitors[1]
func xdr(_ slider: Double) {   // the XDR changes, and its notification arrives
    DisplayServices.slider = slider
    DisplayServices.onChange?()
}
print("monitors: \(store.monitors.map(\.key)), match source: \(store.matchSource?.name ?? "none")")

print("Matching follows the XDR")
store.setMatching(true)
xdr(0.625)
check(near(a.level, 0.475) && near(b.level, 0.475), "XDR 10/16 puts both at 0.475 (a \(f(a.level)), b \(f(b.level)))")

print("Move Together off: only the moved monitor changes")
store.setMovesTogether(false)
store.userSet(a, to: 0.55)
check(near(a.level, 0.55) && near(b.level, 0.475), "a 0.55, b stays 0.475 (a \(f(a.level)), b \(f(b.level)))")
check(a.matchPoints.count == 1 && b.matchPoints.isEmpty, "only a saved a match")

print("Turning Move Together on and off moves nothing")
store.setMovesTogether(true)
store.setMovesTogether(false)
store.setMovesTogether(true)
check(near(a.level, 0.55) && near(b.level, 0.475), "still a 0.55, b 0.475")

print("Move Together on: the other moves by the same amount, it doesn't snap")
store.userSet(a, to: 0.60)
check(near(a.level, 0.60) && near(b.level, 0.525), "a 0.60, b 0.525 (a \(f(a.level)), b \(f(b.level)))")
check(a.matchPoints.count == 1 && b.matchPoints.count == 1, "both saved a match at this level")

print("A drag that pins one monitor at the top brings it back")
store.setMovesTogether(false)
store.userSet(b, to: 0.95)
store.setMovesTogether(true)
store.setDragging(a, true)
check(a.isDragging && b.isDragging, "both held while dragging")
store.userSet(a, to: 0.80)
check(near(a.level, 0.80) && near(b.level, 1.0), "a 0.80, b pinned at 1.0 (b \(f(b.level)))")
store.userSet(a, to: 0.60)
check(near(a.level, 0.60) && near(b.level, 0.95), "back to a 0.60, b 0.95 (b \(f(b.level)))")
store.setDragging(a, false)
check(!a.isDragging && !b.isDragging, "letting go frees both")

print("Letting go frees every monitor, even if the option changed mid-drag")
store.setDragging(a, true)
store.setMovesTogether(false)
store.setDragging(a, false)
check(!a.isDragging && !b.isDragging, "neither is stuck held")
store.setMovesTogether(true)

print("Auto-brightness on: Match by Eye explains instead of starting")
a.forgetMatches(); b.forgetMatches()
DisplayServices.auto = true
store.requestMatchByEye()
check(store.matchByEye == nil && store.matchByEyeWaitsForAutoBrightness, "not started, waiting on auto-brightness")
check(near(DisplayServices.slider, 0.625), "the XDR wasn't touched")
DisplayServices.auto = false
xdr(0.625)   // the next check (notification or 2 s timer) sees it off
check(!store.matchByEyeWaitsForAutoBrightness, "the notice clears once auto-brightness is off")

print("Match by Eye: a full pass leaves exactly one match per step")
// Leftovers from a drifting run, like the ones saved on 2026-10-27: between steps, and one absurd.
store.setMovesTogether(false)
for (slider, position) in [(0.0672, 1.0), (0.11, 0.2), (0.15, 0.3), (0.40, 0.5)] {
    xdr(slider)
    store.userSet(b, to: position)
}
store.setMovesTogether(true)
xdr(0.625)   // where the XDR is when Match by Eye starts, and where it should end up
check(b.matchPoints.count == 4, "b starts with 4 leftovers: \(b.matchPoints.map { f($0.apple.slider) })")
store.requestMatchByEye()
check(store.matchByEye?.index == 0 && near(DisplayServices.slider, 0), "started at level 0 with the XDR at 0")
var saved: [Double: Double] = [:]
for step in 0...16 {
    xdr(DisplayServices.slider)   // the notification for the level Match by Eye just set
    if step == 3 {   // the user nudges at level 3 (both move together)
        store.userSet(a, to: a.level + 0.05)
    }
    saved[Double(step) / 16] = a.level
    store.nextMatchByEyeLevel()
}
check(store.matchByEye == nil, "Finish after level 16 ends Match by Eye")
check(near(DisplayServices.slider, 0.625), "the XDR is back at 10/16 (\(f(DisplayServices.slider)))")
let steps = (0...16).map { Double($0) / 16 }
check(a.matchPoints.map(\.apple.slider) == steps, "a: one match at each of the 17 steps")
check(b.matchPoints.map(\.apple.slider) == steps, "b: the 4 leftovers are gone, one match per step")
check(a.matchPoints.allSatisfy { near($0.position, saved[$0.apple.slider]!) }, "a's matches are where its slider was at each Next")

print("After the pass, each step lands exactly on its match")
var exact = true
for point in a.matchPoints {
    xdr(point.apple.slider)
    if !near(a.level, point.position, 0.01) { exact = false; print("    at \(f(point.apple.slider)): \(f(a.level)) vs \(f(point.position))") }
}
check(exact, "a sits on its match at every step (within the 1-point hysteresis)")
xdr(3.0 / 16)
let nudged = a.matchPoints.first { near($0.apple.slider, 3.0 / 16) }!
check(near(a.level, nudged.position, 0.01) && nudged.position > saved[2.0 / 16]!, "the level-3 nudge was kept (\(f(nudged.position)))")

print("Forget puts a monitor back on the starting curve")
xdr(0.625)
a.forgetMatches()
check(a.matchPoints.isEmpty && near(a.level, 0.475, 0.01), "a back to 0.475 at 10/16 (\(f(a.level)))")

UserDefaults.standard.removePersistentDomain(forName: domain)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

import SwiftUI

struct PopoverView: View {
    @Environment(DisplayStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.monitors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No monitors to control").font(.headline)
                    Text("Brightside controls external displays that aren't made by Apple. Apple displays use the brightness keys and Control Center.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(store.monitors) { MonitorRow(monitor: $0, following: store.isMatching ? store.matchSource : nil) }
                if store.monitors.count > 1 {
                    Toggle(store.monitors.count == 2 ? "Move both sliders together" : "Move all sliders together",
                           isOn: Binding(get: { store.movesTogether }, set: { store.setMovesTogether($0) }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .padding(.top, -8)
                }
            }
            VStack(spacing: 10) {
                Divider()
                if let source = store.matchSource, !store.monitors.isEmpty {
                    if let step = store.matchByEye {
                        MatchByEyeRow(source: source, step: step)
                    } else {
                        MatchRow(source: source)
                    }
                    Divider()
                }
                HStack {
                    Toggle("Open at login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// "Match Pro Display XDR": the monitors follow the Apple display's brightness, adjusted by the matches saved by eye.
struct MatchRow: View {
    @Environment(DisplayStore.self) private var store
    let source: MatchSource

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Match \(source.name)")
                Spacer()
                Toggle("Match \(source.name)", isOn: Binding(get: { store.isMatching }, set: { store.setMatching($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            Text(store.isMatching
                 ? "Moving a slider saves that monitor's match at the current level. Match by Eye steps through every level."
                 : "Follow its brightness as auto-brightness and the brightness keys change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.isMatching {
                if store.matchByEyeWaitsForAutoBrightness {
                    Text("Match by Eye needs auto-brightness off, or it keeps pulling the \(source.name) away from each level. In Displays settings, turn off “Automatically adjust brightness,” then click Match by Eye again. Turn it back on when you're done.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
                HStack {
                    Button("Match by Eye…") { store.requestMatchByEye() }
                    if store.matchByEyeWaitsForAutoBrightness {
                        Button("Open Displays Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 5)
            }
        }
    }
}

/// Match by Eye: the Apple display steps through its levels, and the user matches the monitors to each one.
struct MatchByEyeRow: View {
    @Environment(DisplayStore.self) private var store
    let source: MatchSource
    let step: MatchByEye

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Match by Eye")
                Spacer()
                Text("Level \(step.index) of \(MatchByEye.levels.count - 1)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Move the sliders until the monitors look as bright as the \(source.name), then click Next. If you stop early, the levels you've done stay saved. The \(source.name) goes back to its brightness at the end.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.appleAutoBrightness {
                Text("Auto-brightness is back on, so the \(source.name) will drift away from this level. Turn it off in Displays settings, or stop.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Stop") { store.stopMatchByEye() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back") { store.previousMatchByEyeLevel() }
                    .disabled(step.index == 0)
                Button(step.isLast ? "Finish" : "Next") { store.nextMatchByEyeLevel() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
    }
}

struct MonitorRow: View {
    @Environment(DisplayStore.self) private var store
    let monitor: Monitor
    var following: MatchSource? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.name).font(.headline).lineLimit(1)
                    Text(monitor.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                optionsMenu
            }
            HStack(spacing: 10) {
                BrightnessSlider(value: Binding(get: { monitor.level }, set: { store.userSet(monitor, to: $0) }),
                                 symbol: monitor.method == .software ? "circle.lefthalf.filled"
                                     : monitor.isShaded ? "moon.fill" : "sun.max.fill",
                                 marker: monitor.shadeMarker,
                                 onDrag: { store.setDragging(monitor, $0) })
                Text("\(Int((monitor.level * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            if let following {
                let saved = monitor.matchPoints.count
                Text(saved == 0 ? "Following \(following.name)"
                     : "Following \(following.name), matched by eye at \(saved) \(saved == 1 ? "level" : "levels")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = monitor.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Dim using", selection: Binding(get: { monitor.method }, set: { monitor.setMethod($0) })) {
                Text("Monitor backlight (DDC)").tag(DimMethod.backlight)
                Text("Software dimming").tag(DimMethod.software)
            }
            .pickerStyle(.inline)
            Divider()
            if monitor.method == .backlight {
                Toggle("Dim Past Backlight Minimum", isOn: Binding(get: { monitor.dimsPastMinimum },
                                                                   set: { monitor.setDimsPastMinimum($0) }))
            }
            Button("Read Level from Monitor") { monitor.refresh(force: true) }
                .disabled(monitor.method != .backlight || !monitor.hasChannel)
            if !monitor.matchPoints.isEmpty {
                Divider()
                Button("Forget Matches by Eye") { monitor.forgetMatches() }
            }
        } label: {
            // A Label, not an .accessibilityLabel on the Menu: once the menu has been opened, a re-render drops that
            // one and VoiceOver goes back to the symbol's own name, "More".
            Label("Dimming options for \(monitor.name)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dimming options")
    }
}

/// Control Center–style slider: a white fill that grows from the left, with the symbol riding inside it.
/// An optional tick marks where the backlight bottoms out and gamma dimming takes over.
struct BrightnessSlider: View {
    @Binding var value: Double
    var symbol: String
    var marker: Double? = nil
    var onDrag: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var dragging = false
    private let height: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - height, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.1))
                Capsule()
                    .fill(Color.white)
                    .frame(width: height + travel * value)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.2), radius: 1.5, y: 0.5)
                if let marker {
                    Capsule()
                        .fill(value > marker ? Color.black.opacity(0.18) : Color.primary.opacity(0.3))
                        .frame(width: 2, height: 8)
                        .offset(x: height / 2 + travel * marker - 1)
                }
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.5))
                    .frame(width: height, height: height)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onDrag(true)
                        }
                        value = min(1, max(0, (drag.location.x - height / 2) / travel))
                    }
                    .onEnded { _ in
                        dragging = false
                        onDrag(false)
                    }
            )
        }
        .frame(height: height)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1, step: 0.05) { Text("Brightness") }
        }
    }
}

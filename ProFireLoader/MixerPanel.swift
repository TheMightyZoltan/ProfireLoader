//
//  MixerPanel.swift
//  Console-style mixer (after the original M-Audio panel): LED meter bridge, aux and pan knob
//  rows, mute/solo/link, faders with dB scales, channel source buttons and a MIXER OUT section.
//  Every row has a fixed height and every cell a fixed width, so nothing moves when values change.
//

import SwiftUI
import AppKit

// MARK: - look

enum Theme {
    static let panel = Color(white: 0.105)
    static let strip = Color(white: 0.15)
    static let stripAlt = Color(white: 0.17)
    static let well = Color(white: 0.055)
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.52)
    static let aux = Color(red: 0.30, green: 0.82, blue: 0.78)
    static let pan = Color(red: 0.98, green: 0.62, blue: 0.22)
    static let mute = Color(red: 0.96, green: 0.34, blue: 0.29)
    static let solo = Color(red: 0.98, green: 0.82, blue: 0.22)
    static let link = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let green = Color(red: 0.27, green: 0.86, blue: 0.40)
    static let yellow = Color(red: 0.99, green: 0.83, blue: 0.24)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.24)
}

// MARK: - meters

enum MeterScale {
    static let floorDB = -60.0
    static func frac(db: Double) -> Double { max(0, min(1, (db - floorDB) / -floorDB)) }
    static func frac(_ lin: Float) -> Double { lin > 0 ? frac(db: 20 * log10(Double(lin))) : 0 }
    static let marks: [Double] = [0, -6, -10, -20, -30, -40, -50]
    static let clipH: CGFloat = 5, clipGap: CGFloat = 3
}

/// Segmented LED meter with peak-hold segment and a latching clip LED (click to reset).
struct LEDMeter: View {
    @EnvironmentObject var meters: MeterStore
    var tap: MeterTap? = nil
    var fixed: MeterReading? = nil
    var vertical = true
    var showClip = true
    var segments = 30

    var body: some View {
        let reading = fixed ?? tap.map { meters.reading($0) } ?? MeterReading()
        let core = Canvas { ctx, size in
            let n = segments, gap: CGFloat = 1
            let len = vertical ? size.height : size.width
            let seg = (len - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((MeterScale.frac(reading.level) * Double(n)).rounded())
            let peak = reading.peak > 0 ? Int((MeterScale.frac(reading.peak) * Double(n)).rounded(.up)) - 1 : -1
            for i in 0..<n {
                let top = MeterScale.floorDB * (1 - Double(i + 1) / Double(n))
                let base = top > -3 ? Theme.red : top > -12 ? Theme.yellow : Theme.green
                let on = i < lit || (i == peak && i >= 0)
                let p = CGFloat(i) * (seg + gap)
                let r = vertical ? CGRect(x: 0, y: size.height - p - seg, width: size.width, height: seg)
                                 : CGRect(x: p, y: 0, width: seg, height: size.height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(on ? base : base.opacity(0.12)))
            }
        }
        Group {
            if vertical && showClip {
                VStack(spacing: MeterScale.clipGap) {
                    RoundedRectangle(cornerRadius: 1.5).fill(reading.clip ? Theme.red : Theme.red.opacity(0.14))
                        .frame(height: MeterScale.clipH)
                    core
                }
            } else { core }
        }
        .contentShape(Rectangle())
        .onTapGesture { meters.reset() }
        .help("Click to reset peak hold and clip indicators")
    }
}

/// Vertical text scale; `pos` maps a mark to 0 (bottom) ... 1 (top) of the usable height.
struct DBScale: View {
    var marks: [Double]
    var pos: (Double) -> Double
    var topInset: CGFloat = 0, bottomInset: CGFloat = 0
    var label: (Double) -> String = { $0 == 0 ? "0" : String(format: "%g", $0) }
    var alignment: Alignment = .trailing
    var body: some View {
        GeometryReader { g in
            let h = g.size.height - topInset - bottomInset
            ForEach(marks, id: \.self) { mk in
                Text(label(mk))
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                    .frame(width: g.size.width, alignment: alignment)
                    .position(x: g.size.width / 2, y: topInset + (1 - pos(mk)) * h)
            }
        }
    }
}

// MARK: - controls

/// Catches right-clicks (and Control-clicks) only; every other event falls through to the
/// SwiftUI control underneath. The action gets the modifier flags (Option = alternate reset).
struct RightClickArea: NSViewRepresentable {
    var action: (NSEvent.ModifierFlags) -> Void
    func makeNSView(context: Context) -> Catcher { let v = Catcher(); v.action = action; return v }
    func updateNSView(_ v: Catcher, context: Context) { v.action = action }
    final class Catcher: NSView {
        var action: ((NSEvent.ModifierFlags) -> Void)?
        override func hitTest(_ p: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || e.type == .rightMouseUp
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(p) : nil
        }
        override func rightMouseDown(with e: NSEvent) { action?(e.modifierFlags) }
        override func mouseDown(with e: NSEvent) { action?(e.modifierFlags) }   // Control-click
    }
}

extension View {
    func onRightClick(_ action: @escaping (NSEvent.ModifierFlags) -> Void) -> some View {
        overlay(RightClickArea(action: action))
    }
}

private struct KnobArc: Shape {
    var from: Double, to: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = min(from, to), b = max(from, to)
        guard b > a else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        let steps = max(2, Int((b - a) * 60))
        for s in 0...steps {
            let v = a + (b - a) * Double(s) / Double(steps)
            let ang = (135 + 270 * v) * .pi / 180
            let pt = CGPoint(x: c.x + r * cos(ang), y: c.y + r * sin(ang))
            if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Rotary knob: drag up/down (Option = fine), double-click resets.
struct Knob: View {
    @Binding var value: Double          // 0 ... 1
    var color: Color
    var bipolar = false
    var enabled = true
    var dimmed = false
    var resetValue: Double
    var optionResetValue: Double? = nil      // Option + right-click
    var onBegin: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    var onReset: ((Double) -> Void)? = nil   // resets go here instead of the binding (no group move)
    var text: String
    var help: String
    var axID: String
    @State private var start: Double?

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                KnobArc(from: 0, to: 1).stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                KnobArc(from: bipolar ? 0.5 : 0, to: value)
                    .stroke(color.opacity(enabled && !dimmed ? 1 : 0.3), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                    .padding(4.5)
                Capsule().fill(Color.white.opacity(enabled ? 0.92 : 0.35)).frame(width: 2, height: 7)
                    .offset(y: -6.5).rotationEffect(.degrees(270 * (value - 0.5)))
            }
            .frame(width: 30, height: 30)
            Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(enabled ? Theme.text : Theme.dim)
                .lineLimit(1).frame(width: 44, height: 11)
        }
        .frame(width: 46, height: 44)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { g in
            guard enabled else { return }
            if start == nil { start = value; onBegin?() }
            let fine = NSEvent.modifierFlags.contains(.option)
            value = max(0, min(1, start! - Double(g.translation.height) / (fine ? 600 : 140)))
        }.onEnded { _ in start = nil; onEnd?() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { reset(resetValue) } })
        .onRightClick { flags in
            guard enabled else { return }
            reset(flags.contains(.option) ? (optionResetValue ?? resetValue) : resetValue)
        }
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(help)
        .accessibilityValue(text)
        .accessibilityIdentifier(axID)
    }

    private func reset(_ v: Double) { if let onReset { onReset(v) } else { value = v } }
}

/// Fader with tick marks; drags relative to where it was grabbed (the cap never jumps), double-click = 0 dB.
struct ConsoleFader: View {
    @Binding var db: Double
    var axID: String
    var capColor = Color(white: 0.80)
    var onBegin: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil         // 0 dB reset for this fader only
    @State private var startPos: Double?
    static let capH: CGFloat = 26
    static let marks: [Double] = [12, 6, 0, -6, -12, -20, -30, -40, -60]

    var body: some View {
        GeometryReader { g in
            let travel = g.size.height - Self.capH
            ZStack(alignment: .top) {
                ForEach(Self.marks, id: \.self) { mk in
                    Rectangle().fill(Color.white.opacity(mk == 0 ? 0.5 : 0.17))
                        .frame(width: mk == 0 ? 32 : 24, height: 1)
                        .offset(y: Self.capH / 2 + (1 - FaderCurve.pos(mk)) * travel)
                }
                RoundedRectangle(cornerRadius: 2.5).fill(Theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color.white.opacity(0.06)))
                    .frame(width: 5, height: travel)
                    .offset(y: Self.capH / 2)
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [capColor, capColor.opacity(0.62), capColor.opacity(0.88)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
                    Rectangle().fill(Color.black.opacity(0.75)).frame(height: 1.5)
                }
                .frame(width: 32, height: Self.capH)
                .offset(y: (1 - FaderCurve.pos(db)) * travel)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if startPos == nil { startPos = FaderCurve.pos(db); onBegin?() }
                let fine = NSEvent.modifierFlags.contains(.option)
                let p = startPos! - Double(v.translation.height / travel) / (fine ? 4 : 1)
                db = FaderCurve.db(max(0, min(1, p)))
            }.onEnded { _ in startPos = nil; onEnd?() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let onReset { onReset() } else { db = 0 } })
        }
        .onRightClick { _ in if let onReset { onReset() } else { db = 0 } }
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue(dbText(db))
        .accessibilityIdentifier(axID)
        .help("Drag (Option = fine); double-click or right-click for 0 dB")
    }
}

/// Small latching pad button (mute / solo / link). Same size in both states.
struct PadButton: View {
    let title: String
    var symbol: String? = nil
    let on: Bool
    let color: Color
    var width: CGFloat = 20
    var help: String
    var axID: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5).fill(on ? color : Color(white: 0.24))
                RoundedRectangle(cornerRadius: 3.5).stroke(Color.black.opacity(0.5), lineWidth: 0.5)
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                } else {
                    Text(title).font(.system(size: 10, weight: .heavy))
                }
            }
            .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.text.opacity(0.8))
            .frame(width: width, height: 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityIdentifier(axID)
    }
}

/// Which output pairs a mix bus (0 = master, k = aux k) feeds; multi-select menu.
struct BusOutputMenu: View {
    @EnvironmentObject var m: ProFireModel
    let bus: Int
    var width: CGFloat = 132
    var body: some View {
        let outs = m.outputs(ofBus: bus)
        HStack(spacing: 5) {
            Circle().fill(outs.isEmpty ? Theme.mute : Theme.green).frame(width: 7, height: 7)
            Menu {
                Section(bus == 0 ? "Mixer master feeds" : "Aux \(bus) feeds") {
                    ForEach(OutputPair.allCases) { p in
                        Toggle(p.name, isOn: Binding(get: { outs.contains(p) }, set: { m.setOutput(p, bus: bus, on: $0) }))
                    }
                }
            } label: {
                Text(outs.isEmpty ? "Not routed" : outs.count == 1 ? outs[0].name : "\(outs[0].name) +\(outs.count - 1)")
                    .font(.system(size: 10.5)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("busout.\(bus)")
        }
        .frame(width: width, height: 18, alignment: .leading)
        .help(outs.isEmpty ? "This mix is not routed to any output, so it is inaudible. Pick an output." : "Outputs fed by this mix")
    }
}

// MARK: - mixer

/// The mixer page: shared toolbar and row labels, then one block per ProFire shown.
struct MixerView: View {
    @EnvironmentObject var devices: DeviceManager
    typealias D = DeviceMixer
    @State private var fit = FitState()

    var body: some View {
        let shown = devices.shownInMixer
        VStack(spacing: 0) {
            toolbar(shown)
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: D.colGap) {
                    labelColumn
                    ForEach(shown, id: \.serviceID) { m in
                        DeviceMixer(showHeader: true).environmentObject(m).environmentObject(m.meters)
                    }
                }
                .padding(12)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    fit.content = size
                    DispatchQueue.main.async { [fit] in fit.fitWindow() }
                }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                fit.viewport = size
                DispatchQueue.main.async { [fit] in fit.fitWindow() }
            }
            .background(Theme.panel)
        }
        .onAppear { fit.fitted = .zero }
    }

    private func toolbar(_ shown: [ProFireModel]) -> some View {
        HStack(spacing: 14) {
            Text("Aux rows").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                PadButton(title: "−", on: false, color: .gray, width: 22, help: "Remove an aux row", axID: "auxrows.minus") { devices.auxRows = max(1, devices.auxRows - 1) }
                Text("\(devices.auxRows)").monospacedDigit().frame(width: 14)
                PadButton(title: "+", on: false, color: .gray, width: 22, help: "Add an aux row", axID: "auxrows.plus") { devices.auxRows = min(7, devices.auxRows + 1) }
            }
            Divider().frame(height: 16)
            Text("Peak hold").foregroundStyle(.secondary)
            Picker("", selection: $devices.peakHold) {
                Text("Off").tag(0.0); Text("1 s").tag(1.0); Text("3 s").tag(3.0); Text("10 s").tag(10.0); Text("Hold").tag(-1.0)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 230)
            .accessibilityIdentifier("peakhold")
            Button("Reset Peaks") { for m in shown { m.resetPeaks() } }.accessibilityIdentifier("resetpeaks")
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var labelColumn: some View {
        VStack(alignment: .trailing, spacing: D.rowGap) {
            Color.clear.frame(height: D.headerH)
            label("INPUT").frame(height: D.srcH)
            DBScale(marks: MeterScale.marks, pos: { MeterScale.frac(db: $0) }, topInset: MeterScale.clipH + MeterScale.clipGap)
                .frame(height: D.meterH)
            ForEach(0..<devices.auxRows, id: \.self) { r in
                Text("AUX \(r + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.aux).frame(height: D.knobH)
            }
            Text("PAN").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.pan).frame(height: D.knobH)
            Color.clear.frame(height: D.msH)
            DBScale(marks: D.faderMarks, pos: FaderCurve.pos, topInset: ConsoleFader.capH / 2, bottomInset: ConsoleFader.capH / 2,
                    label: { $0 > 0 ? "+\(Int($0))" : "\(Int($0))" })
                .frame(height: D.faderH)
            Text("dB").font(.system(size: 9)).foregroundStyle(Theme.dim).frame(height: D.valH)
            label("CH").frame(height: D.numH)
            label("NAME").frame(height: D.nameH)
        }
        .frame(width: D.labelW)
        .padding(.vertical, 8)
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
    }
}

/// One ProFire's mixer: name header, 18 channel strips and its MIXER OUT section.
struct DeviceMixer: View {
    @EnvironmentObject var m: ProFireModel
    var showHeader = true

    static let stripW: CGFloat = 46, stripGap: CGFloat = 4, colGap: CGFloat = 8, labelW: CGFloat = 50, masterW: CGFloat = 156
    static let srcH: CGFloat = 18, meterH: CGFloat = 150, knobH: CGFloat = 44, msH: CGFloat = 19, faderH: CGFloat = 196
    static let valH: CGFloat = 13, numH: CGFloat = 18, nameH: CGFloat = 18
    static let rowGap: CGFloat = 7
    static let faderMarks: [Double] = [12, 6, 0, -6, -12, -20, -30, -40, -60]
    static let groupColors: [Color] = [Theme.link, Theme.pan, Theme.green, Color(red: 0.72, green: 0.52, blue: 1.0),
                                       Color(red: 1.0, green: 0.45, blue: 0.70), Theme.aux, Theme.yellow, Theme.red,
                                       Color(red: 0.55, green: 0.62, blue: 1.0)]

    static let headerH: CGFloat = 22

    /// Colour by the group's rank among the groups that exist, so groups present at once differ.
    private func groupColor(_ id: Int) -> Color {
        let ids = Set(m.mixer.groups ?? []).filter { $0 > 0 }.sorted()
        return Self.groupColors[(ids.firstIndex(of: id) ?? 0) % Self.groupColors.count]
    }

    @State private var selection = Set<Int>()
    @State private var anchor = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: Self.headerH)
            HStack(alignment: .top, spacing: Self.colGap) {
                HStack(alignment: .top, spacing: Self.stripGap) {
                    ForEach(0..<MixerSettings.channelCount, id: \.self) { strip($0) }
                }
                masterColumn
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(m.displayName.uppercased()).font(.system(size: 11, weight: .heavy)).tracking(0.5).foregroundStyle(Theme.text)
            Spacer()
            Button("All Mono") { m.allMono() }
                .help("Unlink every channel and center its pan").accessibilityIdentifier("allmono")
            Button("Stereo Pairs") { m.stereoPairs() }
                .help("Link 1/2, 3/4, … as stereo pairs panned L100/R100").accessibilityIdentifier("stereopairs")
            Button("Reset Mixer") { m.resetMixer() }.accessibilityIdentifier("resetmixer")
        }
        .controlSize(.mini)
        .padding(.horizontal, 4)
    }

    // MARK: channel strip

    private func strip(_ i: Int) -> some View {
        let g = m.mixer.group(i)
        let selected = selection.contains(i)
        return VStack(spacing: Self.rowGap) {
            InputMenu(index: i).frame(width: Self.stripW, height: Self.srcH)
            LEDMeter(tap: m.meter(mixerChannel: i)).frame(width: 18).frame(width: Self.stripW, height: Self.meterH)
            ForEach(0..<m.auxRows, id: \.self) { k in auxKnob(i, k).frame(width: Self.stripW, height: Self.knobH) }
            panKnob(i).frame(width: Self.stripW, height: Self.knobH)
            msCell(i).frame(width: Self.stripW, height: Self.msH)
            ConsoleFader(db: Binding(get: { m.mixer.channels[i].level },
                                     set: { m.setLevel(i, $0, single: NSEvent.modifierFlags.contains(.shift)) }),
                         axID: "fader.\(i + 1)",
                         onBegin: { m.beginDrag(i) }, onEnd: { m.endDrag() },
                         onReset: { m.setLevel(i, 0, single: true) })
                .frame(width: Self.stripW, height: Self.faderH)
            Text(dbText(m.mixer.channels[i].level)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.text)
                .frame(width: Self.stripW, height: Self.valH)
                .accessibilityIdentifier("val.\(i + 1)")
            numberButton(i, group: g, selected: selected).frame(width: Self.stripW, height: Self.numH)
            NameField(index: i).frame(width: Self.stripW - 2, height: Self.nameH)
        }
        .padding(.vertical, 8).padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(g == 0 ? Theme.strip : groupColor(g).opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.white.opacity(0.55) : .clear, lineWidth: 1.5))
        .overlay(alignment: .top) {
            Capsule().fill(g == 0 ? Color.clear : groupColor(g)).frame(width: Self.stripW - 10, height: 3).offset(y: 2)
        }
    }

    /// Channel number: Finder-style selection (click, Shift-click range, Command-click toggle);
    /// right-click for link / unlink.
    private func numberButton(_ i: Int, group g: Int, selected: Bool) -> some View {
        let targets = selection.contains(i) ? selection : [i]
        let linkedTargets = targets.filter { m.mixer.group($0) != 0 }
        return Button { select(i) } label: {
            Text("\(i + 1)").font(.system(size: 12, weight: .heavy))
                .foregroundStyle(selected ? Color.black.opacity(0.85) : (g == 0 ? Theme.text : groupColor(g)))
                .frame(width: Self.stripW - 6, height: Self.numH)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color(white: 0.85) : Color(white: 0.22)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(targets.count >= 2 ? "Link Channels \(Self.list(targets))" : "Link (select 2 or more channels)") {
                m.link(targets); selection = []
            }
            .disabled(targets.count < 2)
            Button(linkedTargets.isEmpty ? "Unlink" : "Unlink Channels \(Self.list(linkedTargets))") { m.unlink(targets) }
                .disabled(linkedTargets.isEmpty)
            Divider()
            Button("Select All") { selection = Set(0..<MixerSettings.channelCount) }
            Button("Deselect") { selection = [] }.disabled(selection.isEmpty)
        }
        .help(g == 0 ? "Channel \(i + 1). Click / Shift-click / Command-click to select, right-click to link."
                     : "Channel \(i + 1), linked with \(Self.list(m.mixer.members(i))). Right-click to unlink.")
        .accessibilityLabel("Channel \(i + 1)")
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityIdentifier("num.\(i + 1)")
    }

    private static func list(_ s: some Collection<Int>) -> String { s.sorted().map { "\($0 + 1)" }.joined(separator: ", ") }

    private func select(_ i: Int) {
        let f = NSEvent.modifierFlags
        if f.contains(.shift) {
            let r = min(anchor, i)...max(anchor, i)
            selection = (f.contains(.command) ? selection : []).union(r)
        } else if f.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i
        } else {
            selection = selection == [i] ? [] : [i]
            anchor = i
        }
    }

    private func msCell(_ i: Int) -> some View {
        HStack(spacing: 3) {
            PadButton(title: "M", on: m.mixer.channels[i].mute, color: Theme.mute, help: "Mute channel \(i + 1) (Shift: this channel only)", axID: "mute.\(i + 1)") {
                m.toggle(i, \.mute, single: NSEvent.modifierFlags.contains(.shift))
            }
            PadButton(title: "S", on: m.mixer.channels[i].solo, color: Theme.solo, help: "Solo channel \(i + 1) (Shift: this channel only)", axID: "solo.\(i + 1)") {
                m.toggle(i, \.solo, single: NSEvent.modifierFlags.contains(.shift))
            }
        }
    }

    private func auxKnob(_ i: Int, _ k: Int) -> some View {
        let b = Binding<Double>(get: { FaderCurve.pos(m.mixer.channels[i].aux[k]) },
                                set: { m.setLevel(i, FaderCurve.db($0), aux: k, single: NSEvent.modifierFlags.contains(.shift)) })
        return Knob(value: b, color: Theme.aux, dimmed: m.mixer.auxMuted(k), resetValue: 0, optionResetValue: FaderCurve.pos(0),
                    onBegin: { m.beginDrag(i, aux: k) }, onEnd: { m.endDrag() },
                    onReset: { m.setLevel(i, FaderCurve.db($0), aux: k, single: true) },
                    text: dbText(m.mixer.channels[i].aux[k]),
                    help: "Channel \(i + 1) send to aux \(k + 1) (pre-fader). Shift-drag: this channel only. Right-click: off, Option+right-click: 0 dB",
                    axID: "aux\(k + 1).\(i + 1)")
    }

    private func panKnob(_ i: Int) -> some View {
        let pan = m.mixer.channels[i].pan
        let b = Binding<Double>(get: { (pan + 1) / 2 }, set: { m.mixer.channels[i].pan = $0 * 2 - 1 })
        let txt = abs(pan) < 0.01 ? "C" : (pan < 0 ? "L" : "R") + "\(Int((abs(pan) * 100).rounded()))"
        let def = m.defaultPan(i)
        return Knob(value: b, color: Theme.pan, bipolar: true, resetValue: (def + 1) / 2, text: txt,
                    help: "Channel \(i + 1) pan. Right-click: \(def < 0 ? "L100" : def > 0 ? "R100" : "center")",
                    axID: "pan.\(i + 1)")
    }

    // MARK: master

    private var masterColumn: some View {
        VStack(alignment: .leading, spacing: Self.rowGap) {
            Text("MIXER OUT").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.text).frame(height: Self.srcH)
            HStack(alignment: .top, spacing: 4) {
                LEDMeter(tap: m.meter(mixerOut: 0)).frame(width: 18)
                LEDMeter(tap: m.meter(mixerOut: 1)).frame(width: 18)
                DBScale(marks: MeterScale.marks, pos: { MeterScale.frac(db: $0) }, topInset: MeterScale.clipH + MeterScale.clipGap,
                        alignment: .leading)
                    .frame(width: 22)
                Text("L  R").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .frame(height: Self.meterH, alignment: .top)
            ForEach(0..<m.auxRows, id: \.self) { r in
                let k = r + 1
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        LEDMeter(tap: m.meter(mixerOut: 2 * k), showClip: false, segments: 15).frame(width: 6)
                        LEDMeter(tap: m.meter(mixerOut: 2 * k + 1), showClip: false, segments: 15).frame(width: 6)
                    }
                    .frame(height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("AUX \(k) OUT").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.aux)
                            PadButton(title: "M", on: m.mixer.auxMuted(r), color: Theme.mute, help: "Mute aux \(k) bus", axID: "auxmute.\(k)") {
                                var a = m.mixer.auxMute ?? [Bool](repeating: false, count: 7)
                                a[r].toggle(); m.mixer.auxMute = a
                            }
                        }
                        BusOutputMenu(bus: k, width: 128)
                    }
                }
                .frame(height: Self.knobH)
            }
            Color.clear.frame(height: Self.knobH)
            HStack(spacing: 6) {
                PadButton(title: "M", on: m.mixer.masterMuted, color: Theme.mute, help: "Mute the mixer master", axID: "mute.master") {
                    m.mixer.masterMute = !m.mixer.masterMuted
                }
                Text("MASTER").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.dim)
            }
            .frame(height: Self.msH)
            HStack(spacing: 4) {
                ConsoleFader(db: $m.mixer.masterLevel, axID: "fader.master", capColor: Color(red: 0.95, green: 0.55, blue: 0.45))
                    .frame(width: 46)
                DBScale(marks: Self.faderMarks, pos: FaderCurve.pos, topInset: ConsoleFader.capH / 2, bottomInset: ConsoleFader.capH / 2,
                        label: { $0 > 0 ? "+\(Int($0))" : "\(Int($0))" }, alignment: .leading)
                    .frame(width: 24)
            }
            .frame(height: Self.faderH)
            Text(dbText(m.mixer.masterLevel)).font(.system(size: 9.5).monospacedDigit()).frame(width: 46, height: Self.valH)
            VStack(alignment: .leading, spacing: 2) {
                Text("OUTPUT").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                BusOutputMenu(bus: 0, width: 140)
            }
            .frame(height: Self.numH + Self.rowGap + Self.nameH)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .frame(width: Self.masterW, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.19)))
    }
}

/// Channel name (stored with the mixer settings). Shown as a label; click to edit, Return or
/// clicking elsewhere ends editing. No text field exists until then, so it can't catch stray typing.
struct NameField: View {
    @EnvironmentObject var m: ProFireModel
    let index: Int
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let name = m.mixer.channels[index].name ?? ""
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Theme.well)
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onExitCommand { editing = false }
                    .padding(.horizontal, 2)
            } else {
                Text(name.isEmpty ? InputMenu.shortName(m.mixer.channels[index].source) : name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(name.isEmpty ? Theme.dim.opacity(0.7) : Theme.text)
                    .lineLimit(1).padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { text = name; editing = true; DispatchQueue.main.async { focused = true } } }
        .help("Channel \(index + 1) name: click to edit")
        .accessibilityElement(children: editing ? .contain : .ignore)
        .accessibilityLabel("Channel \(index + 1) name")
        .accessibilityValue(name)
        .accessibilityIdentifier("name.\(index + 1)")
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let t = text.trimmingCharacters(in: .whitespaces)
        if t != (m.mixer.channels[index].name ?? "") { m.mixer.channels[index].name = t.isEmpty ? nil : t }
    }
}

/// Input source menu at the top of each strip (like the original's channel source buttons).
struct InputMenu: View {
    @EnvironmentObject var m: ProFireModel
    let index: Int
    var body: some View {
        let src = m.mixer.channels[index].source
        Menu {
            ForEach(MixerSources.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.self) { s in
                        Button(s.name) { m.mixer.channels[index].source = s }
                    }
                }
            }
        } label: {
            Text(Self.shortName(src)).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 44, height: 16)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.24)))
        .help("Channel \(index + 1) input: \(src.name)")
        .accessibilityIdentifier("source.\(index + 1)")
    }

    static func shortName(_ s: Signal) -> String {
        switch s {
        case .analogIn(let c): return "An \(c + 1)"
        case .adatAIn(let c): return "A·\(c + 1)"
        case .adatBIn(let c): return "B·\(c + 1)"
        case .spdifIn(let c): return c == 0 ? "SPD L" : "SPD R"
        case .spdifOptIn(let c): return c == 0 ? "Opt L" : "Opt R"
        case .swReturn(let c): return "SW \(c + 1)"
        case .mixerOut: return "Mix"
        case .off: return "Off"
        }
    }
}

// MARK: - meters page: every group in one wide row

struct MetersView: View {
    @EnvironmentObject var m: ProFireModel
    @EnvironmentObject var devices: DeviceManager
    static let meterW: CGFloat = 20, meterH: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Peak hold").foregroundStyle(.secondary)
                Picker("", selection: $devices.peakHold) {
                    Text("Off").tag(0.0); Text("1 s").tag(1.0); Text("3 s").tag(3.0); Text("10 s").tag(10.0); Text("Hold").tag(-1.0)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                Button("Reset Peaks") { m.resetPeaks() }
                Spacer()
                Text("Click any meter to reset peaks and clip LEDs").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small).padding(.horizontal, 12).frame(height: 34)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 18) {
                    bridge("INPUTS", [
                        ("Analog", (0..<8).map { ("\($0 + 1)", m.meter(source: .analogIn($0))) }),
                        ("ADAT A", (0..<8).map { ("\($0 + 1)", m.meter(source: .adatAIn($0))) }),
                        ("ADAT B", (0..<8).map { ("\($0 + 1)", m.meter(source: .adatBIn($0))) }),
                        ("S/PDIF", [("L", m.meter(source: .spdifIn(0))), ("R", m.meter(source: .spdifIn(1))),
                                    ("oL", m.meter(source: .spdifOptIn(0))), ("oR", m.meter(source: .spdifOptIn(1)))]),
                    ])
                    bridge("FROM COMPUTER (software returns)", [
                        ("", (0..<26).map { ("\($0 + 1)", m.meter(source: .swReturn($0))) }),
                    ])
                    bridge("MIXER OUTPUTS", [("Master", [("L", m.meter(mixerOut: 0)), ("R", m.meter(mixerOut: 1))])]
                           + (1...7).map { k in ("Aux \(k)", [("L", m.meter(mixerOut: 2 * k)), ("R", m.meter(mixerOut: 2 * k + 1))]) })
                    bridge("HARDWARE OUTPUTS", Dest.outputGroups.map { g in
                        (g.0.replacingOccurrences(of: " Outputs", with: ""),
                         g.1.map { d in (Self.outLabel(d), m.meter(dest: d.port(m.mode))) })
                    })
                }
                .padding(16)
            }
            .background(Theme.panel)
        }
    }

    private static func outLabel(_ d: Dest) -> String {
        switch d {
        case .spdifOut(let c): return c == 0 ? "L" : "R"
        case .spdifOptOut(let c): return c == 0 ? "oL" : "oR"
        case .analogOut(let c), .adatAOut(let c), .adatBOut(let c): return "\(c + 1)"
        default: return "?"
        }
    }

    private func bridge(_ title: String, _ groups: [(String, [(String, MeterTap)])]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.text)
            HStack(alignment: .top, spacing: 14) {
                DBScale(marks: MeterScale.marks, pos: { MeterScale.frac(db: $0) }, topInset: MeterScale.clipH + MeterScale.clipGap)
                    .frame(width: 20, height: Self.meterH)
                    .padding(.top, 15)
                ForEach(Array(groups.enumerated()), id: \.0) { _, g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.0).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.dim).frame(height: 12)
                        HStack(spacing: 5) {
                            ForEach(Array(g.1.enumerated()), id: \.0) { _, it in
                                VStack(spacing: 3) {
                                    LEDMeter(tap: it.1).frame(width: Self.meterW, height: Self.meterH)
                                    Text(it.0).font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.dim).frame(width: Self.meterW + 4)
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.strip))
        }
    }
}

private struct MixerContentSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
private struct MixerViewportSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Window auto-fit state for the mixer (a reference, so deferred callbacks see current sizes).
@MainActor
final class FitState {
    var content = CGSize.zero, viewport = CGSize.zero
    var fitted = CGSize.zero        // content size the window was last fitted to

    /// Resize the window by exactly the difference between the mixer's content and its viewport,
    /// keeping the top-left corner in place and staying on screen. Only runs when the mixer's own
    /// layout changes (start, aux rows, mono strips), so a manual resize is left alone otherwise.
    func fitWindow() {
        // Fit once per mixer layout; a later manual resize (viewport change only) is left alone.
        guard content.width > 0, viewport.width > 0, content != fitted,
              let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "ProFire Control" }) else { return }
        fitted = content
        let dw = content.width - viewport.width, dh = content.height - viewport.height
        guard abs(dw) > 1 || abs(dh) > 1 else { return }
        var f = win.frame
        let vis = (win.screen ?? NSScreen.main)?.visibleFrame ?? f
        let w = min(vis.width, f.width + dw), h = min(vis.height, f.height + dh)
        f.origin.y += f.height - h
        f.size = CGSize(width: w, height: h)
        if f.minY < vis.minY { f.origin.y = vis.minY }
        if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - w) }
        win.setFrame(f, display: true, animate: false)
    }

}

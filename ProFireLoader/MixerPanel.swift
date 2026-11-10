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
    @EnvironmentObject var m: ProFireModel
    var reading: MeterReading
    var vertical = true
    var showClip = true
    var segments = 30

    var body: some View {
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
        .onTapGesture { m.resetPeaks() }
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
            if start == nil { start = value }
            let fine = NSEvent.modifierFlags.contains(.option)
            value = max(0, min(1, start! - Double(g.translation.height) / (fine ? 600 : 140)))
        }.onEnded { _ in start = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { value = resetValue } })
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(help)
        .accessibilityValue(text)
        .accessibilityIdentifier(axID)
    }
}

/// Fader with tick marks; drags relative to where it was grabbed (the cap never jumps), double-click = 0 dB.
struct ConsoleFader: View {
    @Binding var db: Double
    var axID: String
    var capColor = Color(white: 0.80)
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
                if startPos == nil { startPos = FaderCurve.pos(db) }
                let fine = NSEvent.modifierFlags.contains(.option)
                let p = startPos! - Double(v.translation.height / travel) / (fine ? 4 : 1)
                db = FaderCurve.db(max(0, min(1, p)))
            }.onEnded { _ in startPos = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
        }
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue(dbText(db))
        .accessibilityIdentifier(axID)
        .help("Drag (Option = fine), double-click for 0 dB")
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

struct MixerView: View {
    @EnvironmentObject var m: ProFireModel

    static let stripW: CGFloat = 46, linkW: CGFloat = 14, colGap: CGFloat = 8, labelW: CGFloat = 50, masterW: CGFloat = 156
    static let meterH: CGFloat = 150, knobH: CGFloat = 44, msH: CGFloat = 19, faderH: CGFloat = 196, valH: CGFloat = 13, srcH: CGFloat = 34
    static let rowGap: CGFloat = 7
    static let faderMarks: [Double] = [12, 6, 0, -6, -12, -20, -30, -40, -60]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: Self.colGap) {
                    labelColumn
                    ForEach(0..<(MixerSettings.channelCount / 2), id: \.self) { pairColumn($0) }
                    masterColumn
                }
                .padding(12)
            }
            .background(Theme.panel)
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("Aux rows").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                PadButton(title: "−", on: false, color: .gray, width: 22, help: "Remove an aux row", axID: "auxrows.minus") { m.auxRows = max(1, m.auxRows - 1) }
                Text("\(m.auxRows)").monospacedDigit().frame(width: 14)
                PadButton(title: "+", on: false, color: .gray, width: 22, help: "Add an aux row", axID: "auxrows.plus") { m.auxRows = min(7, m.auxRows + 1) }
            }
            Divider().frame(height: 16)
            Text("Peak hold").foregroundStyle(.secondary)
            Picker("", selection: $m.peakHold) {
                Text("Off").tag(0.0); Text("1 s").tag(1.0); Text("3 s").tag(3.0); Text("10 s").tag(10.0); Text("Hold").tag(-1.0)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 230)
            .accessibilityIdentifier("peakhold")
            Button("Reset Peaks") { m.resetPeaks() }.accessibilityIdentifier("resetpeaks")
            Spacer()
            Button("Reset Mixer") { m.resetMixer() }.accessibilityIdentifier("resetmixer")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: columns

    private var labelColumn: some View {
        VStack(alignment: .trailing, spacing: Self.rowGap) {
            DBScale(marks: MeterScale.marks, pos: { MeterScale.frac(db: $0) }, topInset: MeterScale.clipH + MeterScale.clipGap)
                .frame(height: Self.meterH)
            ForEach(0..<m.auxRows, id: \.self) { r in
                let k = r + 1
                VStack(alignment: .trailing, spacing: 4) {
                    Text("AUX \(k)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.aux)
                    PadButton(title: "M", on: m.mixer.auxMuted(r), color: Theme.mute, help: "Mute aux \(k) bus", axID: "auxmute.\(k)") {
                        var a = m.mixer.auxMute ?? [Bool](repeating: false, count: 7)
                        a[r].toggle(); m.mixer.auxMute = a
                    }
                }
                .frame(height: Self.knobH)
            }
            Text("PAN").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.pan).frame(height: Self.knobH)
            Color.clear.frame(height: Self.msH)
            DBScale(marks: Self.faderMarks, pos: FaderCurve.pos, topInset: ConsoleFader.capH / 2, bottomInset: ConsoleFader.capH / 2,
                    label: { $0 > 0 ? "+\(Int($0))" : "\(Int($0))" })
                .frame(height: Self.faderH)
            Text("dB").font(.system(size: 9)).foregroundStyle(Theme.dim).frame(height: Self.valH)
            Text("INPUT").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim).frame(height: Self.srcH)
        }
        .frame(width: Self.labelW)
        .padding(.vertical, 8)
    }

    private func pairColumn(_ pair: Int) -> some View {
        let l = pair * 2, r = pair * 2 + 1
        let linked = m.mixer.link[pair]
        return VStack(spacing: Self.rowGap) {
            cells(height: Self.meterH, l: meterCell(l), r: meterCell(r))
            ForEach(0..<m.auxRows, id: \.self) { k in
                cells(height: Self.knobH, l: auxKnob(l, k, linked), r: auxKnob(r, k, linked))
            }
            cells(height: Self.knobH, l: panKnob(l, linked), r: panKnob(r, linked))
            HStack(spacing: 0) {
                msCell(l, linked).frame(width: Self.stripW)
                PadButton(title: "", symbol: "link", on: linked, color: Theme.link, width: 13,
                          help: linked ? "Unlink channels \(l + 1) and \(r + 1)" : "Link channels \(l + 1) and \(r + 1) as a stereo pair",
                          axID: "link.\(pair + 1)") { m.mixer.link[pair].toggle() }
                    .frame(width: Self.linkW)
                msCell(r, linked).frame(width: Self.stripW)
            }
            .frame(height: Self.msH)
            cells(height: Self.faderH, l: ConsoleFader(db: levelBinding(l, linked), axID: "fader.\(l + 1)"),
                  r: ConsoleFader(db: levelBinding(r, linked), axID: "fader.\(r + 1)"))
            cells(height: Self.valH, l: valueText(l), r: valueText(r))
            cells(height: Self.srcH, l: SourceButton(index: l), r: SourceButton(index: r))
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(pair % 2 == 0 ? Theme.strip : Theme.stripAlt))
        .overlay(alignment: .top) {
            // stereo-link bracket over the meters
            Capsule().fill(Theme.link.opacity(linked ? 0.8 : 0)).frame(width: 2 * Self.stripW + Self.linkW - 20, height: 2).offset(y: 3)
        }
    }

    private func cells<L: View, R: View>(height: CGFloat, l: L, r: R) -> some View {
        HStack(spacing: 0) {
            l.frame(width: Self.stripW, height: height)
            Color.clear.frame(width: Self.linkW, height: height)
            r.frame(width: Self.stripW, height: height)
        }
    }

    private func meterCell(_ i: Int) -> some View {
        LEDMeter(reading: m.meter(mixerChannel: i)).frame(width: 18)
    }

    private func valueText(_ i: Int) -> some View {
        Text(dbText(m.mixer.channels[i].level)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.text)
            .frame(width: 44, height: 13)
            .accessibilityIdentifier("val.\(i + 1)")
    }

    private func msCell(_ i: Int, _ linked: Bool) -> some View {
        HStack(spacing: 3) {
            PadButton(title: "M", on: m.mixer.channels[i].mute, color: Theme.mute, help: "Mute channel \(i + 1)", axID: "mute.\(i + 1)") {
                set(i, linked) { $0.mute.toggle() }
            }
            PadButton(title: "S", on: m.mixer.channels[i].solo, color: Theme.solo, help: "Solo channel \(i + 1)", axID: "solo.\(i + 1)") {
                set(i, linked) { $0.solo.toggle() }
            }
        }
    }

    private func auxKnob(_ i: Int, _ k: Int, _ linked: Bool) -> some View {
        let b = Binding<Double>(get: { FaderCurve.pos(m.mixer.channels[i].aux[k]) }, set: { p in
            let db = FaderCurve.db(p)
            m.mixer.channels[i].aux[k] = db
            if linked { m.mixer.channels[i ^ 1].aux[k] = db }
        })
        return Knob(value: b, color: Theme.aux, dimmed: m.mixer.auxMuted(k), resetValue: 0,
                    text: dbText(m.mixer.channels[i].aux[k]), help: "Channel \(i + 1) send to aux \(k + 1) (pre-fader); double-click = off",
                    axID: "aux\(k + 1).\(i + 1)")
    }

    private func panKnob(_ i: Int, _ linked: Bool) -> some View {
        let pan = linked ? (i % 2 == 0 ? -1.0 : 1.0) : m.mixer.channels[i].pan
        let b = Binding<Double>(get: { (pan + 1) / 2 }, set: { m.mixer.channels[i].pan = $0 * 2 - 1 })
        let txt = abs(pan) < 0.01 ? "C" : (pan < 0 ? "L" : "R") + "\(Int((abs(pan) * 100).rounded()))"
        return Knob(value: b, color: Theme.pan, bipolar: true, enabled: !linked, resetValue: 0.5, text: txt,
                    help: linked ? "Linked pair: hard left/right (unlink to pan)" : "Channel \(i + 1) pan; double-click = center",
                    axID: "pan.\(i + 1)")
    }

    private func levelBinding(_ i: Int, _ linked: Bool) -> Binding<Double> {
        Binding(get: { m.mixer.channels[i].level }, set: { v in
            m.mixer.channels[i].level = v
            if linked { m.mixer.channels[i ^ 1].level = v }
        })
    }

    private func set(_ i: Int, _ linked: Bool, _ f: (inout ChannelStrip) -> Void) {
        var mx = m.mixer
        f(&mx.channels[i])
        if linked { mx.channels[i ^ 1].mute = mx.channels[i].mute; mx.channels[i ^ 1].solo = mx.channels[i].solo }
        m.mixer = mx
    }

    // MARK: master

    private var masterColumn: some View {
        VStack(alignment: .leading, spacing: Self.rowGap) {
            HStack(alignment: .top, spacing: 4) {
                LEDMeter(reading: m.meter(mixerOut: 0)).frame(width: 18)
                LEDMeter(reading: m.meter(mixerOut: 1)).frame(width: 18)
                DBScale(marks: MeterScale.marks, pos: { MeterScale.frac(db: $0) }, topInset: MeterScale.clipH + MeterScale.clipGap,
                        alignment: .leading)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MIXER OUT").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.text)
                    Text("L  R").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                }
            }
            .frame(height: Self.meterH, alignment: .top)
            ForEach(0..<m.auxRows, id: \.self) { r in
                let k = r + 1
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        LEDMeter(reading: m.meter(mixerOut: 2 * k), showClip: false, segments: 15).frame(width: 6)
                        LEDMeter(reading: m.meter(mixerOut: 2 * k + 1), showClip: false, segments: 15).frame(width: 6)
                    }
                    .frame(height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AUX \(k) OUT").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.aux)
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
            .frame(height: Self.srcH)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .frame(width: Self.masterW, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.19)))
    }
}

/// Channel number + input source menu (like the original's numbered channel buttons).
struct SourceButton: View {
    @EnvironmentObject var m: ProFireModel
    let index: Int
    var body: some View {
        let src = m.mixer.channels[index].source
        VStack(spacing: 1) {
            Text("\(index + 1)").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.text).frame(height: 14)
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
            .frame(width: 44, height: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.24)))
            .accessibilityIdentifier("source.\(index + 1)")
        }
        .help("Channel \(index + 1) input: \(src.name)")
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
    static let meterW: CGFloat = 20, meterH: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Peak hold").foregroundStyle(.secondary)
                Picker("", selection: $m.peakHold) {
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

    private func bridge(_ title: String, _ groups: [(String, [(String, MeterReading)])]) -> some View {
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
                                    LEDMeter(reading: it.1).frame(width: Self.meterW, height: Self.meterH)
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

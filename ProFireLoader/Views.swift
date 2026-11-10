//
//  Views.swift
//  ProFire Control UI: mixer, router, hardware, meters, driver.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - building blocks

struct MeterBar: View {
    var level: Float
    var vertical = true
    var body: some View {
        GeometryReader { g in
            let db = level > 0 ? 20 * log10(Double(level)) : -96
            let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
            let color: Color = db > -3 ? .red : db > -12 ? .yellow : .green
            ZStack(alignment: vertical ? .bottom : .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 2).fill(color.gradient)
                    .frame(width: vertical ? nil : g.size.width * frac, height: vertical ? g.size.height * frac : nil)
            }
        }
        .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// Fader position (0...1) <-> dB (kSilenceDB ... +12), unity at ~0.65.
enum FaderCurve {
    static func db(_ p: Double) -> Double { p <= 0.002 ? kSilenceDB : max(kSilenceDB, 12 - pow(1 - p, 2) * 96) }
    static func pos(_ db: Double) -> Double { db <= kSilenceDB ? 0 : 1 - sqrt(max(0, (12 - db) / 96)) }
}

struct Fader: View {
    @Binding var db: Double
    var body: some View {
        GeometryReader { g in
            let h = g.size.height - 14
            let y = (1 - FaderCurve.pos(db)) * h
            ZStack(alignment: .top) {
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 4).frame(maxWidth: .infinity)
                // unity mark
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 18, height: 1)
                    .offset(y: (1 - FaderCurve.pos(0)) * h + 7)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1))
                    .frame(width: 26, height: 14)
                    .offset(y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let p = 1 - Double(min(max(0, v.location.y - 7), h) / h)
                db = FaderCurve.db(p)
            })
            .onTapGesture(count: 2) { db = 0 }
        }
    }
}

func dbText(_ db: Double) -> String { db <= kSilenceDB ? "-∞" : String(format: "%+.1f", db) }

// MARK: - mixer

struct ChannelStripView: View {
    @EnvironmentObject var m: ProFireModel
    let index: Int
    var linked: Bool

    var body: some View {
        let ch = m.mixer.channels[index]
        VStack(spacing: 6) {
            Menu {
                ForEach(MixerSources.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { s in
                            Button(s.name) { setSource(s) }
                        }
                    }
                }
            } label: {
                Text(shortName(ch.source)).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).frame(width: 54)

            HStack(spacing: 4) {
                MeterBar(level: m.level(mixerChannel: index))
                Fader(db: faderBinding).frame(width: 30)
            }
            .frame(height: 220)
            Text(dbText(faderBinding.wrappedValue)).font(.system(size: 10, design: .monospaced))

            if m.auxView == 0 && !linked {
                Slider(value: binding(\.pan), in: -1...1).controlSize(.mini).frame(width: 50)
                    .help("Pan (double-click a fader to reset it to 0 dB)")
            } else {
                Text(linked ? (index % 2 == 0 ? "L" : "R") : "pre").font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 14)
            }
            HStack(spacing: 3) {
                Toggle("M", isOn: binding(\.mute)).toggleStyle(.button).tint(.orange)
                Toggle("S", isOn: binding(\.solo)).toggleStyle(.button).tint(.yellow)
            }.controlSize(.small)
            Text("\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
        }
        .frame(width: 56)
    }

    private func shortName(_ s: Signal) -> String {
        switch s {
        case .analogIn(let c): return "Anlg \(c + 1)"
        case .adatAIn(let c): return "Opt A\(c + 1)"
        case .adatBIn(let c): return "Opt B\(c + 1)"
        case .spdifIn(let c): return c == 0 ? "S/PDIF L" : "S/PDIF R"
        case .spdifOptIn(let c): return c == 0 ? "Opt SP L" : "Opt SP R"
        case .swReturn(let c): return "Return \(c + 1)"
        case .mixerOut: return "Mix"
        case .off: return "Off"
        }
    }

    private func setSource(_ s: Signal) { m.mixer.channels[index].source = s }

    // In a linked pair, level / mute / solo / aux move together.
    private func binding<T>(_ kp: WritableKeyPath<ChannelStrip, T>) -> Binding<T> {
        Binding(get: { m.mixer.channels[index][keyPath: kp] }, set: { v in
            m.mixer.channels[index][keyPath: kp] = v
            if linked && kp != \ChannelStrip.pan { m.mixer.channels[index ^ 1][keyPath: kp] = v }
        })
    }

    private var faderBinding: Binding<Double> {
        if m.auxView == 0 { return binding(\.level) }
        let k = m.auxView - 1
        return Binding(get: { m.mixer.channels[index].aux[k] }, set: { v in
            m.mixer.channels[index].aux[k] = v
            if linked { m.mixer.channels[index ^ 1].aux[k] = v }
        })
    }
}

struct MixerView: View {
    @EnvironmentObject var m: ProFireModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Faders", selection: $m.auxView) {
                    Text("Master Mix").tag(0)
                    ForEach(1...7, id: \.self) { Text("Aux \($0)").tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 620)
                Spacer()
                Button("Reset Mixer") { m.resetMixer() }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(0..<(MixerSettings.channelCount / 2), id: \.self) { pair in
                        VStack(spacing: 4) {
                            Toggle("Link", isOn: Binding(get: { m.mixer.link[pair] }, set: { m.mixer.link[pair] = $0 }))
                                .toggleStyle(.button).controlSize(.mini)
                            HStack(spacing: 2) {
                                ChannelStripView(index: pair * 2, linked: m.mixer.link[pair])
                                ChannelStripView(index: pair * 2 + 1, linked: m.mixer.link[pair])
                            }
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    masterSection
                }
                .padding(.bottom, 8)
            }
            Text(m.auxView == 0
                 ? "Master Mix = mixer outputs 1/2. Route it to an output pair on the Router tab to hear it."
                 : "Aux \(m.auxView) send levels (pre-fader) = mixer outputs \(2 * m.auxView + 1)/\(2 * m.auxView + 2). Route \"Aux Send \(m.auxView)\" to an output.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var masterSection: some View {
        let o = m.auxView * 2
        return VStack(spacing: 6) {
            Text(m.auxView == 0 ? "MASTER" : "AUX \(m.auxView)").font(.system(size: 11, weight: .bold))
            HStack(spacing: 4) {
                MeterBar(level: m.level(mixerOut: o))
                MeterBar(level: m.level(mixerOut: o + 1))
                if m.auxView == 0 { Fader(db: $m.mixer.masterLevel).frame(width: 30) }
            }
            .frame(height: 220)
            if m.auxView == 0 { Text(dbText(m.mixer.masterLevel)).font(.system(size: 10, design: .monospaced)) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

// MARK: - router

struct SignalMenu: View {
    let current: Signal
    let set: (Signal) -> Void
    var body: some View {
        Menu {
            ForEach(Signal.groups, id: \.0) { group in
                Section(group.0) { ForEach(group.1, id: \.self) { sig in Button(sig.name) { set(sig) } } }
            }
        } label: { Text(current.name).lineLimit(1) }
        .frame(width: 210)
    }
}

struct RouterView: View {
    @EnvironmentObject var m: ProFireModel
    @State private var page = 0
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("", selection: $page) {
                    Text("Outputs (pairs)").tag(0)
                    Text("Outputs (channels)").tag(1)
                    Text("Computer Inputs").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 460)
                Spacer()
                Button("Load from ProFire") { m.loadRoutingFromDevice() }
                    .help("Adopt the routing that is active in the ProFire right now")
                Button("Reset Routing") { m.resetRouter() }
            }
            switch page {
            case 0: pairs
            case 1: channels(Dest.outputGroups)
            default: channels([("Core Audio inputs 1-26 (what you record)", Dest.computerInputs)])
            }
        }
    }

    private var pairs: some View {
        Form {
            ForEach(OutputPair.allCases) { pair in
                let ports = pair.ports(m.mode)
                HStack {
                    Text(pair.name).frame(width: 150, alignment: .leading)
                    let cur = m.pairSource(pair)
                    Menu {
                        ForEach(SourcePair.groups, id: \.0) { group in
                            Section(group.0) { ForEach(group.1) { sp in Button(sp.name) { m.setPair(pair, sp) } } }
                        }
                    } label: { Text(cur?.name ?? "Custom (see channels)") }
                    .frame(width: 220).disabled(ports == nil)
                    VStack(spacing: 3) {
                        MeterBar(level: m.level(dest: ports?.0), vertical: false)
                        MeterBar(level: m.level(dest: ports?.1), vertical: false)
                    }.frame(width: 160)
                    if ports == nil { Text("not available at \(m.rate / 1000) kHz (S/MUX)").font(.caption).foregroundStyle(.secondary) }
                    if pair == .spdifOpt && !m.opticalBIsSPDIF { Text("port B is in ADAT mode").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.formStyle(.grouped)
    }

    private func channels(_ groups: [(String, [Dest])]) -> some View {
        Form {
            ForEach(groups, id: \.0) { g in
                Section(g.0) {
                    ForEach(g.1) { d in
                        let port = d.port(m.mode)
                        HStack {
                            Text(d.name).frame(width: 170, alignment: .leading)
                            SignalMenu(current: m.router.source(d)) { m.router.routes[d] = $0 }.disabled(port == nil)
                            MeterBar(level: m.level(dest: port), vertical: false).frame(width: 160)
                            if port == nil { Text("not available at \(m.rate / 1000) kHz").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

// MARK: - hardware

struct HardwareView: View {
    @EnvironmentObject var m: ProFireModel
    @State private var saving = false
    @State private var saveResult: String?
    @State private var nickname = ""
    @State private var flashResult: String?

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Model") { Text("\(m.identity.vendor) \(m.identity.model)") }
                LabeledContent("GUID") { Text(m.identity.guid).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                LabeledContent("DICE firmware interface") { Text(m.identity.version) }
                HStack {
                    TextField("Nickname", text: $nickname).frame(width: 260)
                    Button("Rename") { m.setNickname(nickname) }.disabled(nickname.isEmpty || nickname == m.identity.nickname)
                }
                .onAppear { nickname = m.identity.nickname }
                .onChange(of: m.identity.nickname) { _, v in nickname = v }
            }
            Section("Clock") {
                Picker("Sample rate", selection: Binding(get: { m.rate }, set: { m.setRate($0) })) {
                    ForEach([44100, 48000, 88200, 96000], id: \.self) { Text(String(format: "%.1f kHz", Double($0) / 1000)).tag($0) }
                }
                Picker("Clock source", selection: Binding(get: { m.clockSource }, set: { m.setClockSource($0) })) {
                    ForEach(ClockSource.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("Status") {
                    HStack {
                        Circle().fill(m.locked ? Color.green : Color.red).frame(width: 9, height: 9)
                        Text(m.locked ? "Locked" : "Not locked")
                        Text(m.mode == .low ? "· Normal" : "· S/MUX II (ADAT carries 4 channels per port)")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("External inputs") {
                    HStack(spacing: 14) {
                        ForEach([ClockSource.spdifCoax, .opticalA, .opticalB, .wordClock]) { c in
                            HStack(spacing: 4) {
                                Circle().fill(m.extStatus & (c.lockBit ?? 0) != 0 ? Color.green : Color.gray.opacity(0.4)).frame(width: 8, height: 8)
                                Text(c.name).font(.callout)
                            }
                        }
                    }
                }
            }
            Section("Optical port B") {
                Picker("Mode", selection: Binding(get: { m.opticalBIsSPDIF }, set: { m.setOpticalB(spdif: $0) })) {
                    Text("ADAT").tag(false)
                    Text("S/PDIF (optical)").tag(true)
                }.pickerStyle(.segmented)
            }
            Section("Master volume knob controls") {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { p in
                        Toggle("Analog Out \(p * 2 + 1)/\(p * 2 + 2)", isOn: Binding(get: { m.knobPairs[p] }, set: { m.setKnob(pair: p, on: $0) }))
                    }
                }
            }
            Section("Standalone mode") {
                Picker("Standalone clock source", selection: Binding(get: { m.standaloneClock }, set: { m.setStandaloneClock($0) })) {
                    ForEach([ClockSource.internalClock, .spdifCoax, .opticalA, .wordClock]) { Text($0.name).tag($0) }
                }
                Picker("Standalone sample rate", selection: Binding(get: { m.standaloneRateIndex }, set: { m.setStandaloneRate($0) })) {
                    ForEach(Array([32000, 44100, 48000, 88200, 96000, 176400, 192000].enumerated()), id: \.0) { i, r in
                        Text(String(format: "%.1f kHz", Double(r) / 1000)).tag(i)
                    }
                }
                HStack {
                    Button(saving ? "Saving…" : "Save Settings to ProFire") {
                        saving = true
                        m.saveToDevice { ok in saving = false; saveResult = ok ? "Saved to the ProFire's memory." : "Save failed." }
                    }.disabled(saving)
                    if let r = saveResult { Text(r).foregroundStyle(.secondary) }
                }
                Text("Stores the current routing, mixer and settings in the ProFire so it uses them without a computer and after power-on.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Reload from ProFire's Memory") {
                        m.reloadFromFlash { ok in flashResult = ok ? "Reloaded the stored configuration." : "Reload failed." }
                    }
                    if let r = flashResult { Text(r).foregroundStyle(.secondary) }
                }
            }
            Section("Presets") {
                HStack {
                    Button("Save Preset…") { savePreset() }
                    Button("Load Preset…") { loadPreset() }
                    Spacer()
                    Button("Factory Reset (mixer + routing)", role: .destructive) { m.resetMixer(); m.resetRouter() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ProFire 2626 preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(m.preset).write(to: url) } catch { m.lastError = "Saving preset failed: \(error)" }
    }

    private func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { m.apply(try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))) }
        catch { m.lastError = "Loading preset failed: \(error)" }
    }
}

// MARK: - advanced

struct AdvancedView: View {
    @EnvironmentObject var m: ProFireModel
    @State private var addr = "0xE0200000"
    @State private var count = "18"
    @State private var writeValues = ""
    @State private var opcode = "0x0001"
    @State private var eapResult = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Active router (\(m.mode == .low ? "44.1/48 kHz" : "88.2/96 kHz")) · \(m.rawRoutes.count) routes").font(.headline)
                    Spacer()
                    Button("Refresh") { m.refreshRawRouter() }
                }
                Table(m.rawRoutes) {
                    TableColumn("#") { Text("\($0.id + 1)") }.width(32)
                    TableColumn("Source") { Text($0.source) }
                    TableColumn("Destination") { Text($0.dest) }
                    TableColumn("Entry") { Text(String(format: "%04x", $0.entry & 0xFFFF)).font(.system(.body, design: .monospaced)) }.width(60)
                    TableColumn("Level") { MeterBar(level: $0.level, vertical: false) }.width(90)
                }
            }
            .frame(minWidth: 460)
            .padding(.trailing, 8)
            .onAppear { m.refreshRawRouter() }
            .onChange(of: m.connected) { _, c in if c { m.refreshRawRouter() } }
            .onChange(of: m.rate) { _, _ in m.refreshRawRouter() }

            Form {
                Section("DICE registers (address = low 32 bits of 0xFFFF'xxxxxxxx)") {
                    HStack {
                        TextField("Address", text: $addr).frame(width: 190).font(.system(.body, design: .monospaced))
                        TextField("Quadlets", text: $count).frame(width: 110)
                        Button("Read") { if let a = num(addr), let n = Int(count) { m.rawRead(UInt32(a), quads: max(1, min(n, 1024))) } }
                    }
                    ScrollView {
                        Text(dump()).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                    HStack {
                        TextField("Values to write (hex, space separated)", text: $writeValues)
                        Button("Write") {
                            let vals = writeValues.split(separator: " ").compactMap { num(String($0)) }.map { UInt32(truncatingIfNeeded: $0) }
                            if let a = num(addr), !vals.isEmpty { m.rawWrite(UInt32(a), vals) }
                        }
                    }
                }
                Section("Quick addresses") {
                    if let map = m.mapInfo {
                        let items: [(String, UInt32, Int)] = [("Global section", map.global, 24), ("EAP section table", DICE.eapBase, 18),
                                                              ("Mixer (header + 18x16)", map.mixer, 32), ("Peak meters", map.peak, 64),
                                                              ("Current router (low)", map.currentRouter(mode: 0), 64),
                                                              ("Standalone config", map.standalone, 16), ("Application space", map.application, 4)]
                        ForEach(items, id: \.0) { it in
                            Button("\(it.0)  ·  0x\(String(it.1, radix: 16))") { addr = "0x" + String(it.1, radix: 16); count = "\(it.2)"; m.rawRead(it.1, quads: it.2) }
                                .buttonStyle(.link)
                        }
                    }
                }
                Section("EAP commands") {
                    HStack {
                        Button("Load router (all rates)") { run(DICE.ldRouter | DICE.flagLow | DICE.flagMid | DICE.flagHigh) }
                        Button("Load stream config") { run(DICE.ldStreamCfg | DICE.flagLow | DICE.flagMid | DICE.flagHigh) }
                    }
                    HStack {
                        Button("Load flash config") { run(DICE.ldFlashCfg) }
                        Button("Store flash config") { run(DICE.stFlashCfg) }
                    }
                    HStack {
                        TextField("Opcode", text: $opcode).frame(width: 120)
                        Button("Execute") { if let o = num(opcode) { run(UInt32(o)) } }
                        Text(eapResult).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)
        }
    }

    private func run(_ op: UInt32) { eapResult = "…"; m.rawEAP(op) { eapResult = $0 ? String(format: "0x%08x ok", op) : String(format: "0x%08x failed", op) } }

    private func num(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("0x") ? UInt64(t.dropFirst(2), radix: 16) : UInt64(t, radix: 16)
    }

    private func dump() -> String {
        guard let base = num(addr) else { return "" }
        var lines = [String](), line = ""
        for (i, v) in m.rawRegisters.enumerated() {
            if i % 4 == 0 { line = String(format: "%08x:", UInt32(truncatingIfNeeded: base) + UInt32(i * 4)) }
            line += String(format: " %08x", v)
            if i % 4 == 3 { lines.append(line); line = "" }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - meters

struct MetersView: View {
    @EnvironmentObject var m: ProFireModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Inputs").font(.title3.bold())
                HStack(alignment: .top, spacing: 28) {
                    group("Analog", (0..<8).map { (Signal.analogIn($0), "\($0 + 1)") })
                    group("ADAT A", (0..<8).map { (Signal.adatAIn($0), "\($0 + 1)") })
                    group("ADAT B", (0..<8).map { (Signal.adatBIn($0), "\($0 + 1)") })
                    group("S/PDIF", [(Signal.spdifIn(0), "L"), (Signal.spdifIn(1), "R"), (Signal.spdifOptIn(0), "oL"), (Signal.spdifOptIn(1), "oR")])
                }
                Text("Mixer Outputs").font(.title3.bold())
                group("", (0..<16).map { (Signal.mixerOut($0), $0 < 2 ? ($0 == 0 ? "ML" : "MR") : "A\($0 / 2)\($0 % 2 == 0 ? "L" : "R")") })
                Text("Software Returns (from the computer)").font(.title3.bold())
                group("", (0..<26).map { (Signal.swReturn($0), "\($0 + 1)") })
                Text("Hardware Outputs").font(.title3.bold())
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(OutputPair.allCases) { p in
                        let ports = p.ports(m.mode)
                        VStack(spacing: 3) {
                            HStack(spacing: 3) { MeterBar(level: m.level(dest: ports?.0)); MeterBar(level: m.level(dest: ports?.1)) }
                                .frame(height: 130)
                            Text(p.name.replacingOccurrences(of: " Out", with: "")).font(.system(size: 9)).multilineTextAlignment(.center).frame(width: 56).lineLimit(2)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group(_ title: String, _ items: [(Signal, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.headline) }
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(items, id: \.1) { item in
                    VStack(spacing: 3) {
                        MeterBar(level: m.level(source: item.0)).frame(height: 130)
                        Text(item.1).font(.system(size: 9))
                    }
                }
            }
        }
    }
}

// MARK: - driver

struct DriverView: View {
    @EnvironmentObject var ext: ExtensionManager
    @EnvironmentObject var m: ProFireModel
    var body: some View {
        Form {
            Section("ProFire driver") {
                LabeledContent("Connection") { Text(m.connected ? "Connected" : m.statusText) }
                LabeledContent("Streaming") { Text(m.streaming ? "Yes (audio running)" : "Idle") }
                HStack {
                    Button("Install / Update Driver") { ext.activate() }
                    Button("Uninstall Driver") { ext.deactivate() }
                }
                Text(ext.status).font(.callout).textSelection(.enabled)
            }
            Section("Notes") {
                Text("The driver needs System Integrity Protection disabled and system extension developer mode on. After installing, approve it in System Settings › General › Login Items & Extensions › Driver Extensions.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

// MARK: - window

struct ContentView: View {
    @EnvironmentObject var m: ProFireModel
    @State private var tab = ContentView.initialTab
    static var initialTab: Int {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let t = Int(a[i + 1]) { return t }
        return 0
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ProFire 2626").font(.title2.bold())
                Circle().fill(m.connected ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(m.connected ? "\(String(format: "%.1f", Double(m.rate) / 1000)) kHz · \(m.clockSource.name)\(m.locked ? "" : " (not locked)")" : m.statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                if let e = m.lastError {
                    Text(e).font(.callout).foregroundStyle(.red).lineLimit(1)
                    Button("✕") { m.lastError = nil }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal).padding(.top, 12).padding(.bottom, 6)
            TabView(selection: $tab) {
                MixerView().padding().tabItem { Text("Mixer") }.tag(0)
                RouterView().padding().tabItem { Text("Router") }.tag(1)
                HardwareView().padding().tabItem { Text("Hardware") }.tag(2)
                MetersView().tabItem { Text("Meters") }.tag(3)
                AdvancedView().padding().tabItem { Text("Advanced") }.tag(4)
                DriverView().padding().tabItem { Text("Driver") }.tag(5)
            }
            .disabled(!m.connected && tab != 5)
        }
        .frame(minWidth: 1180, minHeight: 640)
    }
}

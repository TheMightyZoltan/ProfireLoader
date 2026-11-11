//
//  Views.swift
//  ProFire Control UI: mixer, router, hardware, meters, driver.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - building blocks

struct MeterBar: View {
    var level: Float = 0
    var tap: MeterTap? = nil
    var vertical = true
    var body: some View {
        LEDMeter(tap: tap, fixed: tap == nil ? MeterReading(level: level) : nil, vertical: vertical, showClip: false, segments: vertical ? 30 : 40)
            .frame(width: vertical ? 8 : nil, height: vertical ? nil : 7)
    }
}

/// Fader position (0...1) <-> dB (kSilenceDB ... +12), unity at ~0.65.
enum FaderCurve {
    static func db(_ p: Double) -> Double { p <= 0.002 ? kSilenceDB : max(kSilenceDB, 12 - pow(1 - p, 2) * 96) }
    static func pos(_ db: Double) -> Double { db <= kSilenceDB ? 0 : 1 - sqrt(max(0, (12 - db) / 96)) }
}

func dbText(_ db: Double) -> String { db <= kSilenceDB ? "-∞" : String(format: "%+.1f", db) }

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
                        MeterBar(tap: m.meter(dest: ports?.0), vertical: false)
                        MeterBar(tap: m.meter(dest: ports?.1), vertical: false)
                    }.frame(width: 160)
                    if ports == nil { Text("not available at \(m.rate / 1000) kHz (S/MUX)").font(.caption).foregroundStyle(.secondary) }
                    if pair == .spdifOpt && !m.opticalBIsSPDIF { Text("inactive: optical port B is in ADAT mode").font(.caption).foregroundStyle(.secondary) }
                    if [.adatB12, .adatB34, .adatB56, .adatB78].contains(pair) && m.opticalBIsSPDIF { Text("inactive: optical port B is in S/PDIF mode").font(.caption).foregroundStyle(.secondary) }
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
                            MeterBar(tap: m.meter(dest: port), vertical: false).frame(width: 160)
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
                        Button("Reload stream configs") { eapResult = "…"; m.reloadStreamConfigs { eapResult = $0 ? "stream configs reloaded" : "reload failed" } }
                            .help("Reloads each rate mode from its own stored configuration")
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

// MARK: - driver

struct DriverView: View {
    @EnvironmentObject var ext: ExtensionManager
    @EnvironmentObject var m: ProFireModel
    @State private var v = DriverVersions()
    var body: some View {
        Form {
            Section("Versions") {
                LabeledContent("ProFire Control") { Text(v.app).textSelection(.enabled) }
                LabeledContent("Driver in this app") { Text(v.bundled).textSelection(.enabled) }
                LabeledContent("Installed in macOS") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if v.installed.isEmpty { Text("none").foregroundStyle(.secondary) }
                        ForEach(v.installed, id: \.self) { d in
                            Text("\(d.version) · \(d.state)").foregroundStyle(d.state.contains("activated enabled") ? .primary : .secondary)
                        }
                    }
                }
                LabeledContent("Running") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if v.running.isEmpty { Text("no FireWire controller found").foregroundStyle(.secondary) }
                        ForEach(v.running, id: \.self) { r in
                            Text("controller \(r.controller): " + (r.build.map { "driver build \($0)" } ?? "no driver"))
                                .foregroundStyle(r.build == nil ? Color.orange : .primary)
                        }
                    }
                }
                if v.upgradePending {
                    Text("A driver update is waiting: restart the Mac to finish it. Until then, newly connected FireWire controllers can't start the driver.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("Refresh") { v = DriverVersions.load() }
            }
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
        }
        .formStyle(.grouped)
        .onAppear { v = DriverVersions.load() }
        .onChange(of: ext.status) { _, _ in v = DriverVersions.load() }
    }
}

// MARK: - window

struct ContentView: View {
    @EnvironmentObject var m: ProFireModel
    @State private var tab = ContentView.initialTab
    static let tabs = ["Mixer", "Router", "Hardware", "Meters", "Advanced", "Driver"]
    static var initialTab: Int {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let t = Int(a[i + 1]) { return t }
        return 0
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("ProFire 2626").font(.title2.bold())
                Circle().fill(m.connected ? Theme.green : Theme.red).frame(width: 9, height: 9)
                Text(m.connected ? "\(String(format: "%.1f", Double(m.rate) / 1000)) kHz · \(m.clockSource.name)\(m.locked ? "" : " (not locked)")" : m.statusText)
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 20)
                if let e = m.lastError {
                    Text(e).font(.callout).foregroundStyle(Theme.red).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520, alignment: .trailing)
                    Button { m.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            HStack(spacing: 2) {
                ForEach(Array(Self.tabs.enumerated()), id: \.0) { i, name in
                    Button { tab = i } label: {
                        Text(name.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6)
                            .foregroundStyle(tab == i ? Color.black.opacity(0.85) : Theme.text.opacity(0.75))
                            .frame(width: 96, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tab == i ? Color(white: 0.82) : Color(white: 0.17)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab.\(name)")
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ZStack {
                switch tab {
                case 0: MixerView()
                case 1: RouterView().padding()
                case 2: HardwareView().padding()
                case 3: MetersView()
                case 4: AdvancedView().padding()
                default: DriverView().padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(!m.connected && tab != 5)
            .overlay {
                if !m.connected && tab != 5 {
                    Text("ProFire not connected — \(m.statusText)").padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                }
            }
        }
        .background(Color(white: 0.085))
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}

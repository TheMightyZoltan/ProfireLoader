//
//  ProFireModel.swift
//  Control-panel state, persisted settings, and device synchronisation.
//

import Foundation
import CoreAudio
import Combine

let kSilenceDB = -84.0   // original panel's "off"

func dbToLin(_ db: Double) -> Double { db <= kSilenceDB ? 0 : pow(10, db / 20) }

struct ChannelStrip: Codable, Equatable {
    var source: Signal
    var level: Double = 0            // dB, kSilenceDB = -inf
    var pan: Double = 0              // -1 ... +1
    var mute = false
    var solo = false
    var aux = [Double](repeating: kSilenceDB, count: 7)
}

struct MixerSettings: Codable, Equatable {
    var channels: [ChannelStrip]
    var link: [Bool]                 // per channel pair
    var masterLevel: Double = 0      // dB, applied to the master mix

    static var factory: MixerSettings {
        // Like the original factory settings: channel pairs on inputs 1..16 (analog, then ADAT A).
        var ch = [ChannelStrip]()
        for i in 0..<16 { ch.append(ChannelStrip(source: i < 8 ? .analogIn(i) : .adatAIn(i - 8), level: 0, pan: i % 2 == 0 ? -1 : 1)) }
        return MixerSettings(channels: ch, link: [Bool](repeating: true, count: 8))
    }
}

struct RouterSettings: Codable, Equatable {
    var outputs: [Int: SourcePair]   // OutputPair.rawValue -> source pair
    static var factory: RouterSettings {
        RouterSettings(outputs: Dictionary(uniqueKeysWithValues: OutputPair.allCases.map { ($0.rawValue, $0.defaultSource) }))
    }
}

enum ClockSource: Int, CaseIterable, Identifiable {
    case internalClock = 12, spdifCoax = 0, opticalA = 5, opticalB = 6, wordClock = 7
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .internalClock: return "Internal"
        case .spdifCoax: return "S/PDIF Coax"
        case .opticalA: return "Optical Port A"
        case .opticalB: return "Optical Port B"
        case .wordClock: return "Word Clock"
        }
    }
    /// DICE extended-status lock bit for this source.
    var lockBit: UInt32? {
        switch self {
        case .internalClock: return nil
        case .spdifCoax: return 0x1
        case .opticalA: return 0x10
        case .opticalB: return 0x20
        case .wordClock: return 0x400
        }
    }
}

@MainActor
final class ProFireModel: ObservableObject {
    // connection / status
    @Published var connected = false
    @Published var statusText = "Looking for the ProFire driver…"
    @Published var rate = 48000
    @Published var locked = false
    @Published var streaming = false
    @Published var extStatus: UInt32 = 0

    // hardware settings
    @Published var clockSource: ClockSource = .internalClock
    @Published var opticalBIsSPDIF = false
    @Published var knobPairs = [true, true, true, true]
    @Published var standaloneClock: ClockSource = .internalClock

    // mixer / router
    @Published var mixer: MixerSettings { didSet { if mixer != oldValue { persist(); scheduleMixerPush() } } }
    @Published var router: RouterSettings { didSet { if router != oldValue { persist(); scheduleRouterPush() } } }
    @Published var auxView = 0       // 0 = master faders, k = aux send k

    // meters (linear 0...1), keyed by router port id
    @Published var srcLevel = [UInt8: Float]()
    @Published var dstLevel = [UInt8: Float]()
    @Published var lastError: String?

    let link = DeviceLink()
    private let io = DispatchQueue(label: "local.profire.control.io")
    private var map: DiceMap?
    private var lastCoefs = [[UInt32]]()
    private var pollTimer: Timer?
    private var tick = 0
    private var mixerPushPending = false
    private var routerPushPending = false

    var mode: RateMode { RateMode.of(rate: rate) }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "mixer"), let m = try? JSONDecoder().decode(MixerSettings.self, from: data) { mixer = m }
        else { mixer = .factory }
        if let data = d.data(forKey: "router"), let r = try? JSONDecoder().decode(RouterSettings.self, from: data) { router = r }
        else { router = .factory }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(mixer), forKey: "mixer")
        d.set(try? JSONEncoder().encode(router), forKey: "router")
    }

    // MARK: - polling

    private func poll() {
        tick += 1
        if !connected {
            if tick % 10 == 1 { connect() }
            return
        }
        let readStatus = tick % 10 == 0
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                let peaks = try self.link.read(map.peak, quads: map.peakQuads)
                var src = [UInt8: Float](), dst = [UInt8: Float]()
                for v in peaks where v & 0xFFFF != 0 || v >> 16 != 0 {
                    let route = v & 0xFFFF
                    let level = Float((v >> 16) & 0xFFF) / 4095
                    let s = UInt8(route >> 8), t = UInt8(route & 0xFF)
                    src[s] = max(src[s] ?? 0, level)
                    dst[t] = max(dst[t] ?? 0, level)
                }
                var info: DriverInfo?, cs: UInt32 = 0, xs: UInt32 = 0
                if readStatus {
                    info = try self.link.info()
                    cs = try self.link.read(map.global + DICE.clockSelect)
                    xs = try self.link.read(map.global + DICE.extStatus)
                }
                DispatchQueue.main.async {
                    self.srcLevel = self.decay(self.srcLevel, src)
                    self.dstLevel = self.decay(self.dstLevel, dst)
                    if let info {
                        self.locked = info.locked; self.streaming = info.streaming
                        self.extStatus = xs
                        if let c = ClockSource(rawValue: Int(cs & 0xFF)) { self.clockSource = c }
                        let r = Int(self.currentCoreAudioRate() ?? Double(info.rate))
                        if r != self.rate { self.rate = r; self.scheduleRouterPush() }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.disconnected(error) }
            }
        }
    }

    private func decay(_ old: [UInt8: Float], _ new: [UInt8: Float]) -> [UInt8: Float] {
        var out = new
        for (k, v) in old { out[k] = max(new[k] ?? 0, v * 0.82) }
        return out
    }

    private func disconnected(_ error: Error) {
        connected = false
        map = nil
        lastCoefs = []
        statusText = "\(error)"
        link.close()
    }

    // MARK: - connect

    func connect() {
        io.async { [weak self] in
            guard let self else { return }
            do {
                let info = try self.link.info()
                guard info.found else { throw LinkError.noDriver }
                let map = try DiceMap.load(self.link)
                let cs = try self.link.read(map.global + DICE.clockSelect)
                let app = try self.link.read(map.application, quads: 4)
                let sa = try self.link.read(map.standalone, quads: 1)
                DispatchQueue.main.async {
                    self.map = map
                    self.connected = true
                    self.statusText = "Connected to ProFire 2626"
                    self.lastError = nil
                    self.rate = Int(self.currentCoreAudioRate() ?? Double(info.rate))
                    self.clockSource = ClockSource(rawValue: Int(cs & 0xFF)) ?? .internalClock
                    self.opticalBIsSPDIF = app[0] & 0x1000_0000 != 0
                    self.knobPairs = (0..<4).map { app[0] & (1 << $0) != 0 }
                    self.standaloneClock = ClockSource(rawValue: Int(sa[0] & 0xFF)) ?? .internalClock
                    // Restore the panel's settings to the device (the device boots with a muted mixer).
                    self.scheduleMixerPush()
                    self.scheduleRouterPush()
                }
            } catch {
                DispatchQueue.main.async { self.disconnected(error) }
            }
        }
    }

    // MARK: - mixer

    /// 16 x 18 coefficient matrix from the channel strips.
    func coefficients() -> [[UInt32]] {
        let ins = map?.mixerInputs ?? 18, outs = map?.mixerOutputs ?? 16
        var m = [[Double]](repeating: [Double](repeating: 0, count: ins), count: outs)
        let anySolo = mixer.channels.contains { $0.solo }
        let master = dbToLin(mixer.masterLevel)
        for (i, ch) in mixer.channels.enumerated() where i < ins {
            if ch.mute { continue }
            let pan = linkedPan(i)
            let l = pan <= 0 ? 1 : 1 - pan, r = pan >= 0 ? 1 : 1 + pan
            if !anySolo || ch.solo {
                let g = dbToLin(ch.level) * master
                m[0][i] += g * l; m[1][i] += g * r
            }
            for k in 0..<7 where 2 * k + 3 < outs {       // aux sends: pre-fader, follow pan
                let a = dbToLin(ch.aux[k])
                m[2 * k + 2][i] += a * l; m[2 * k + 3][i] += a * r
            }
        }
        return m.map { row in row.map { UInt32(min(0xFFFF, max(0, ($0 * 16384).rounded()))) } }
    }

    private func linkedPan(_ i: Int) -> Double {
        mixer.link[i / 2] ? (i % 2 == 0 ? -1 : 1) : mixer.channels[i].pan
    }

    private func scheduleMixerPush() {
        guard connected, !mixerPushPending else { return }
        mixerPushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.mixerPushPending = false
            let coefs = self.coefficients()
            let old = self.lastCoefs
            self.lastCoefs = coefs
            self.io.async {
                guard let map = self.map else { return }
                do {
                    for o in 0..<coefs.count {
                        if old.count == coefs.count && old[o] == coefs[o] { continue }
                        // The mixer region doesn't take block transfers reliably: quadlets only.
                        for i in 0..<coefs[o].count where old.count != coefs.count || coefs[o][i] != old[o][i] {
                            try self.link.write(map.mixerCoef(out: o, input: i), coefs[o][i])
                        }
                    }
                } catch {
                    DispatchQueue.main.async { self.lastCoefs = []; self.lastError = "Mixer update failed: \(error)" }
                }
            }
        }
    }

    // MARK: - router

    private func scheduleRouterPush() {
        guard connected, !routerPushPending else { return }
        routerPushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.routerPushPending = false
            let outputs = self.router.outputs
            let sources = self.mixer.channels.map { $0.source }
            self.io.async {
                guard let map = self.map else { return }
                do {
                    for mode in [RateMode.low, .mid] {
                        try self.applyRouter(map: map, mode: mode, outputs: outputs, mixerSources: sources)
                    }
                } catch {
                    DispatchQueue.main.async { self.lastError = "Router update failed: \(error)" }
                }
            }
        }
    }

    /// Start from the device's current routing for this rate mode (keeps the computer-input routes),
    /// replace output and mixer-input routes, and load it.
    nonisolated private func applyRouter(map: DiceMap, mode: RateMode, outputs: [Int: SourcePair], mixerSources: [Signal]) throws {
        let cur = map.currentRouter(mode: mode.rawValue)
        let n = Int(try link.read(cur))
        guard n > 0, n < map.routerQuads else { return }
        var routes = [UInt8: UInt8]()                      // destination -> source
        for e in try link.read(cur + 4, quads: n) { routes[UInt8(e & 0xFF)] = UInt8((e >> 8) & 0xFF) }

        for pair in OutputPair.allCases {
            guard let (dl, dr) = pair.ports(mode) else { continue }
            let sp = outputs[pair.rawValue] ?? .off
            let (sl, sr) = sp.signals
            routes[dl.id] = (sl.port(mode) ?? Port.muted).id
            routes[dr.id] = (sr.port(mode) ?? Port.muted).id
        }
        for (i, s) in mixerSources.enumerated() where i < 16 {
            routes[Port(Port.mixer, i).id] = (s.port(mode) ?? Port.muted).id
        }
        let entries = routes.keys.sorted().map { UInt32(routes[$0]!) << 8 | UInt32($0) }
        guard entries.count + 1 <= map.routerQuads else { throw LinkError.call(-1) }
        try link.write(map.router, [UInt32(entries.count)] + entries)
        try link.eap(DICE.ldRouter | mode.flag)
    }

    // MARK: - hardware settings

    func setClockSource(_ c: ClockSource) {
        clockSource = c
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                let cs = try self.link.read(map.global + DICE.clockSelect)
                try self.link.write(map.global + DICE.clockSelect, (cs & ~0xFF) | UInt32(c.rawValue))
            } catch { DispatchQueue.main.async { self.lastError = "Clock change failed: \(error)" } }
        }
    }

    private func updateApp(_ change: @escaping (inout UInt32) -> Void) {
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                var app = try self.link.read(map.application, quads: 4)
                change(&app[0])
                try self.link.write(map.application, app)
            } catch { DispatchQueue.main.async { self.lastError = "Setting failed: \(error)" } }
        }
    }

    func setOpticalB(spdif: Bool) {
        opticalBIsSPDIF = spdif
        updateApp { $0 = spdif ? ($0 | 0x1000_0000) : ($0 & ~0x1000_0000) }
    }

    func setKnob(pair: Int, on: Bool) {
        knobPairs[pair] = on
        updateApp { $0 = on ? ($0 | (1 << UInt32(pair))) : ($0 & ~(1 << UInt32(pair))) }
    }

    func setStandaloneClock(_ c: ClockSource) {
        standaloneClock = c
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                var sa = try self.link.read(map.standalone, quads: 1)
                sa[0] = (sa[0] & ~0xFF) | UInt32(c.rawValue)
                try self.link.write(map.standalone, sa)
            } catch { DispatchQueue.main.async { self.lastError = "Standalone clock failed: \(error)" } }
        }
    }

    /// Store routing, mixer and settings in the ProFire's flash (used in standalone mode and at power-on).
    func saveToDevice(_ done: @escaping (Bool) -> Void) {
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.link.eap(DICE.stFlashCfg)) ?? false
            DispatchQueue.main.async { done(ok) }
        }
    }

    func resetMixer() { mixer = .factory }

    /// Debug: temporarily route a mixer test path (see README), then restore and quit.
    func runSelfTest() {
        Task { @MainActor in
            while !connected { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let savedMixer = mixer, savedRouter = router
            var mx = MixerSettings.factory
            for i in 0..<16 { mx.channels[i].mute = true }
            mx.link[0] = false
            mx.channels[0] = ChannelStrip(source: .adatBIn(0), level: -6, pan: 0)
            mixer = mx
            router.outputs[OutputPair.adatA34.rawValue] = .mixerMaster
            print("SELFTEST applied"); fflush(stdout)
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            mixer = savedMixer
            router = savedRouter
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("SELFTEST restored"); fflush(stdout)
            exit(0)
        }
    }
    func resetRouter() { router = .factory }

    // MARK: - sample rate (through Core Audio so apps stay in sync)

    private func coreAudioDevice() -> AudioObjectID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        for id in ids {
            var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString?>.size)
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &na, 0, nil, &s, &n) == noErr, let str = n?.takeRetainedValue() as String?, str.contains("ProFire 2626") { return id }
        }
        return nil
    }

    func currentCoreAudioRate() -> Double? {
        guard let dev = coreAudioDevice() else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r: Float64 = 0; var s = UInt32(8)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &r) == noErr ? r : nil
    }

    func setRate(_ r: Int) {
        guard let dev = coreAudioDevice() else { lastError = "ProFire 2626 not found in Core Audio"; return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = Float64(r)
        let e = AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &v)
        if e != noErr { lastError = "Sample rate change failed (\(e))" } else { rate = r; scheduleRouterPush() }
    }

    // MARK: - meter helpers

    func level(source s: Signal) -> Float { s.port(mode).map { srcLevel[$0.id] ?? 0 } ?? 0 }
    func level(dest p: Port?) -> Float { p.map { dstLevel[$0.id] ?? 0 } ?? 0 }
    func level(mixerChannel i: Int) -> Float { dstLevel[Port(Port.mixer, i).id] ?? 0 }
    func level(mixerOut o: Int) -> Float { srcLevel[Port(Port.mixer, o).id] ?? 0 }
}

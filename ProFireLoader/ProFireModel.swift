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
    var masterMute: Bool? = nil
    var auxMute: [Bool]? = nil       // per aux send bus
    var masterMuted: Bool { masterMute ?? false }
    func auxMuted(_ k: Int) -> Bool { auxMute.map { k < $0.count && $0[k] } ?? false }

    static let channelCount = 18
    static var factory: MixerSettings {
        // Channels 1-8 analog, 9-16 ADAT A, 17-18 S/PDIF coax, in linked pairs at 0 dB.
        var ch = [ChannelStrip]()
        for i in 0..<channelCount { ch.append(ChannelStrip(source: Dest.mixerIn(i).defaultSource, level: 0, pan: i % 2 == 0 ? -1 : 1)) }
        return MixerSettings(channels: ch, link: [Bool](repeating: true, count: channelCount / 2))
    }
    /// Older saved settings had 16 channels.
    mutating func normalise() {
        while channels.count < MixerSettings.channelCount {
            let i = channels.count
            channels.append(ChannelStrip(source: Dest.mixerIn(i).defaultSource, level: 0, pan: i % 2 == 0 ? -1 : 1))
        }
        while link.count < MixerSettings.channelCount / 2 { link.append(true) }
    }
}

struct RouterSettings: Codable, Equatable {
    var routes: [Dest: Signal]       // every output and computer input -> its source
    static var factory: RouterSettings {
        RouterSettings(routes: Dictionary(uniqueKeysWithValues: Dest.routable.map { ($0, $0.defaultSource) }))
    }
    func source(_ d: Dest) -> Signal { routes[d] ?? d.defaultSource }
}

/// Everything the panel controls, for presets.
struct Preset: Codable {
    var mixer: MixerSettings
    var router: RouterSettings
    var knobPairs: [Bool]?
    var opticalBIsSPDIF: Bool?
}

struct DeviceIdentity {
    var nickname = "", version = "", guid = "", vendor = "", model = ""
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
    @Published var auxRows = 2 { didSet { UserDefaults.standard.set(auxRows, forKey: "auxRows") } }

    // peak hold: seconds (0 = off, -1 = until reset); clip LEDs latch until reset
    @Published var peakHold: Double = 3 { didSet { UserDefaults.standard.set(peakHold, forKey: "peakHold"); meters.peakHold = peakHold } }

    /// Meter levels live in their own store, so a meter update redraws only the meters, not every view.
    let meters = MeterStore()
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
        if let data = d.data(forKey: "mixer"), var m = try? JSONDecoder().decode(MixerSettings.self, from: data) { m.normalise(); mixer = m }
        else { mixer = .factory }
        if let data = d.data(forKey: "router2"), let r = try? JSONDecoder().decode(RouterSettings.self, from: data) { router = r }
        else { router = .factory }
        if d.object(forKey: "auxRows") != nil { auxRows = max(1, min(7, d.integer(forKey: "auxRows"))) }
        if d.object(forKey: "peakHold") != nil { peakHold = d.double(forKey: "peakHold") }
        meters.peakHold = peakHold
        // One-time: earlier versions left the mixer unrouted (inaudible). Like M-Audio's factory
        // setup, feed Analog Out 1/2 from the mixer master and put SW returns 1/2 on mixer 17/18.
        if !d.bool(forKey: "mixerRoutedV1") {
            d.set(true, forKey: "mixerRoutedV1")
            let usesMixer = router.routes.values.contains { if case .mixerOut = $0 { return true }; return false }
            if !usesMixer {
                router.routes[.analogOut(0)] = .mixerOut(0); router.routes[.analogOut(1)] = .mixerOut(1)
                if mixer.channels[16].source == .spdifIn(0) && mixer.channels[17].source == .spdifIn(1) {
                    mixer.channels[16].source = .swReturn(0); mixer.channels[17].source = .swReturn(1)
                    mixer.channels[16].level = 0; mixer.channels[17].level = 0
                    mixer.channels[16].mute = false; mixer.channels[17].mute = false
                }
                persist()
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(mixer), forKey: "mixer")
        d.set(try? JSONEncoder().encode(router), forKey: "router2")
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
                    self.meters.update(src: src, dst: dst)
                    if let info {
                        if self.locked != info.locked { self.locked = info.locked }
                        if self.streaming != info.streaming { self.streaming = info.streaming }
                        if self.extStatus != xs { self.extStatus = xs }
                        if let c = ClockSource(rawValue: Int(cs & 0xFF)), c != self.clockSource { self.clockSource = c }
                        let r = Int(self.currentCoreAudioRate() ?? Double(info.rate))
                        if r != self.rate { self.rate = r; self.scheduleRouterPush() }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.disconnected(error) }
            }
        }
    }

    func resetPeaks() { meters.reset() }

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
                    self.opticalBIsSPDIF = app[0] & DICE.appOpticalBSPDIF != 0
                    self.knobPairs = (0..<4).map { app[0] & (1 << $0) != 0 }
                    self.standaloneClock = ClockSource(rawValue: Int(sa[0] & 0xFF)) ?? .internalClock
                    self.loadIdentity()
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
            if (!anySolo || ch.solo) && !mixer.masterMuted {
                let g = dbToLin(ch.level) * master
                m[0][i] += g * l; m[1][i] += g * r
            }
            for k in 0..<7 where 2 * k + 3 < outs && !mixer.auxMuted(k) {   // aux sends: pre-fader, follow pan
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
            let routes = self.router.routes
            let sources = self.mixer.channels.map { $0.source }
            let optB = self.opticalBIsSPDIF
            self.io.async {
                guard let map = self.map else { return }
                do {
                    for mode in [RateMode.low, .mid] {
                        try self.applyRouter(map: map, mode: mode, routes: routes, mixerSources: sources, opticalBIsSPDIF: optB)
                    }
                } catch {
                    DispatchQueue.main.async { self.lastError = "Router update failed: \(error)" }
                }
            }
        }
    }

    /// Start from the device's current routing for this rate mode (keeps the computer-input routes),
    /// replace output and mixer-input routes, and load it.
    nonisolated private func applyRouter(map: DiceMap, mode: RateMode, routes newRoutes: [Dest: Signal], mixerSources: [Signal],
                                         opticalBIsSPDIF: Bool) throws {
        let cur = map.currentRouter(mode: mode.rawValue)
        let n = Int(try link.read(cur))
        guard n > 0, n < map.routerQuads else { return }
        var routes = [UInt8: UInt8]()                      // destination -> source
        for e in try link.read(cur + 4, quads: n) { routes[UInt8(e & 0xFF)] = UInt8((e >> 8) & 0xFF) }

        for d in Dest.routable {
            guard let dp = d.port(mode) else { continue }
            // Optical port B is either ADAT or S/PDIF: driving the inactive side's transmitter
            // disturbs the port (measured: AES1 routes corrupt ADAT B input). Remove those routes.
            var inactive = false
            if case .spdifOptOut = d { inactive = !opticalBIsSPDIF }
            if case .adatBOut = d { inactive = opticalBIsSPDIF }
            if inactive { routes.removeValue(forKey: dp.id); continue }
            let src = newRoutes[d] ?? d.defaultSource
            routes[dp.id] = (src.port(mode) ?? Port.muted).id
        }
        for (i, s) in mixerSources.enumerated() {
            guard let dp = Dest.mixerIn(i).port(mode) else { continue }
            routes[dp.id] = (s.port(mode) ?? Port.muted).id
        }
        let entries = Self.orderedEntries(routes)
        guard entries.count + 1 <= map.routerQuads else { throw LinkError.call(-1) }
        try link.write(map.router, [UInt32(entries.count)] + entries)
        try link.eap(DICE.ldRouter | mode.flag)
    }

    /// Router entries in the ProFire's own order. The firmware drives the front-panel input LEDs
    /// from fixed peak-meter slots: entries 1-8 must carry analog inputs 1-8 (at power-on they are
    /// analog in -> computer). After that come the computer inputs, the outputs and the mixer inputs.
    nonisolated static func orderedEntries(_ routes: [UInt8: UInt8]) -> [UInt32] {
        var left = routes                                  // destination -> source
        var order = [UInt8]()
        let computer: [UInt8] = Array(0xB0...0xBF) + Array(0xC0...0xCF)
        for k in 0..<8 {
            let src = UInt8(Port.ins1 << 4) | UInt8(k)
            let cands = left.filter { $0.value == src }.map { $0.key }
            if let d = cands.filter({ computer.contains($0) }).min() ?? cands.min() {
                order.append(d); left.removeValue(forKey: d)
            }
        }
        func take(_ ds: [UInt8]) { for d in ds where left[d] != nil { order.append(d); left.removeValue(forKey: d) } }
        take(computer)
        take(Array(0x50...0x5F))                           // analog outputs
        take(Array(0x00...0x0F))                           // AES (S/PDIF coax / optical)
        take(Array(0x10...0x1F))                           // ADAT
        take(Array(0x20...0x3F))                           // mixer inputs
        order += left.keys.sorted()
        return order.map { UInt32(routes[$0]!) << 8 | UInt32($0) }
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

    /// Optical port B: ADAT or S/PDIF (application quadlet 0, bit 4 - M-Audio's kext writes it as
    /// 0x10000000 into a little-endian copy of the big-endian quadlet). The ProFire applies it when
    /// the clock is (re)selected.
    func setOpticalB(spdif: Bool) {
        guard spdif != opticalBIsSPDIF else { return }
        opticalBIsSPDIF = spdif
        // Move the routes that used the port's other mode (like the original panel's channel reassignment).
        var r = router
        for c in 0..<26 {
            let d = Dest.computerIn(c)
            switch r.source(d) {
            case .adatBIn(let k) where spdif: r.routes[d] = k < 2 ? .spdifOptIn(k) : .off
            case .spdifOptIn(let k) where !spdif: r.routes[d] = .adatBIn(k)
            default: break
            }
        }
        if spdif, r.source(.spdifOptOut(0)) == .off, r.source(.spdifOptOut(1)) == .off {
            r.routes[.spdifOptOut(0)] = r.source(.adatBOut(0))
            r.routes[.spdifOptOut(1)] = r.source(.adatBOut(1))
        }
        router = r
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                var app = try self.link.read(map.application, quads: 4)
                app[0] = spdif ? (app[0] | DICE.appOpticalBSPDIF) : (app[0] & ~DICE.appOpticalBSPDIF)
                try self.link.write(map.application, app)
                let cs = try self.link.read(map.global + DICE.clockSelect)
                try self.link.write(map.global + DICE.clockSelect, cs)        // apply the port mode
            } catch { DispatchQueue.main.async { self.lastError = "Optical port B change failed: \(error)" } }
        }
        scheduleRouterPush()
    }

    /// Reload each rate mode's stream configuration from its own stored copy (never from whatever
    /// happens to sit in the EAP staging area).
    func reloadStreamConfigs(_ done: @escaping (Bool) -> Void) {
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            var ok = true
            for mode in [RateMode.low, .mid, .high] {
                do {
                    let cfg = try self.link.read(map.currentRouter(mode: mode.rawValue) + 0x1000, quads: map.streamQuads)
                    guard cfg[0] > 0, cfg[0] < 8 else { continue }
                    try self.link.write(map.stream, cfg)
                    ok = try self.link.eap(DICE.ldStreamCfg | mode.flag) && ok
                } catch { ok = false }
            }
            DispatchQueue.main.async { done(ok) }
        }
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

    /// Debug: switch optical port B to S/PDIF, loop SW returns 11/12 through it into computer inputs 25/26.
    func runSPDIFSelfTest() {
        Task { @MainActor in
            while !connected { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let savedRouter = router, savedB = opticalBIsSPDIF
            setOpticalB(spdif: true)
            router.routes[.spdifOptOut(0)] = .swReturn(10)
            router.routes[.spdifOptOut(1)] = .swReturn(11)
            router.routes[.computerIn(24)] = .spdifOptIn(0)
            router.routes[.computerIn(25)] = .spdifOptIn(1)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("SPDIFTEST applied"); fflush(stdout)
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            setOpticalB(spdif: savedB)
            router = savedRouter
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("SPDIFTEST restored"); fflush(stdout)
            exit(0)
        }
    }

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
            setPair(.adatA34, .mixerMaster)
            router.routes[.computerIn(25)] = .adatBIn(0)
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

    // MARK: - pair helpers for the simple router view

    func pairSource(_ p: OutputPair) -> SourcePair? {
        let (l, r) = p.dests
        return SourcePair.from(router.source(l), router.source(r))
    }
    func setPair(_ p: OutputPair, _ sp: SourcePair) {
        let (l, r) = p.dests, (a, b) = sp.signals
        router.routes[l] = a; router.routes[r] = b
    }

    // MARK: - device identity, standalone rate, flash, presets

    @Published var identity = DeviceIdentity()
    @Published var standaloneRateIndex = 2

    func loadIdentity() {
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            var id = DeviceIdentity()
            if let q = try? self.link.read(map.global + 0x0C, quads: 16) { id.nickname = Self.diceString(q) }
            if let v = try? self.link.read(map.global + 0x60) { id.version = "\(v >> 24).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)" }
            if let rom = try? self.link.read(0xF000_0400, quads: 5) { id.guid = String(format: "%08x%08x", rom[3], rom[4]) }
            id.vendor = "M-Audio"; id.model = "ProFire 2626"
            let sa = (try? self.link.read(map.standalone, quads: 5)) ?? []
            DispatchQueue.main.async {
                self.identity = id
                if sa.count == 5 { self.standaloneRateIndex = Int(sa[4] & 0xFF) }
            }
        }
    }

    /// DICE strings: first character in the low byte of each quadlet.
    static func diceString(_ q: [UInt32]) -> String {
        var bytes = [UInt8]()
        for v in q { for b in 0..<4 { let c = UInt8((v >> (8 * UInt32(b))) & 0xFF); if c == 0 { return String(decoding: bytes, as: UTF8.self) }; bytes.append(c) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    func setNickname(_ name: String) {
        var bytes = Array(name.utf8.prefix(63)); bytes.append(0)
        while bytes.count < 64 { bytes.append(0) }
        var q = [UInt32]()
        for i in stride(from: 0, to: 64, by: 4) {
            var v: UInt32 = UInt32(bytes[i])
            v |= UInt32(bytes[i + 1]) << 8
            v |= UInt32(bytes[i + 2]) << 16
            v |= UInt32(bytes[i + 3]) << 24
            q.append(v)
        }
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do { try self.link.write(map.global + 0x0C, q) } catch { DispatchQueue.main.async { self.lastError = "Nickname failed: \(error)" } }
            DispatchQueue.main.async { self.loadIdentity() }
        }
    }

    func setStandaloneRate(_ idx: Int) {
        standaloneRateIndex = idx
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                var sa = try self.link.read(map.standalone, quads: 5)
                sa[4] = (sa[4] & ~0xFF) | UInt32(idx)
                try self.link.write(map.standalone + 16, sa[4])
            } catch { DispatchQueue.main.async { self.lastError = "Standalone rate failed: \(error)" } }
        }
    }

    /// Reload the configuration stored in the ProFire's flash, then adopt its routing.
    func reloadFromFlash(_ done: @escaping (Bool) -> Void) {
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.link.eap(DICE.ldFlashCfg)) ?? false
            DispatchQueue.main.async {
                done(ok)
                if ok { self.loadRoutingFromDevice(); self.connect() }
            }
        }
    }

    /// Adopt the device's active routing (current rate mode) as the panel's routing.
    func loadRoutingFromDevice() {
        let mode = self.mode
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                let cur = map.currentRouter(mode: mode.rawValue)
                let n = Int(try self.link.read(cur))
                var byDest = [UInt8: UInt8]()
                for e in try self.link.read(cur + 4, quads: n) { byDest[UInt8(e & 0xFF)] = UInt8((e >> 8) & 0xFF) }
                var routes = [Dest: Signal]()
                for d in Dest.routable {
                    guard let dp = d.port(mode) else { continue }
                    routes[d] = byDest[dp.id].flatMap { Signal.from(Port(id: $0), mode: mode) } ?? .off
                }
                var sources = [Signal?]()
                for i in 0..<MixerSettings.channelCount {
                    sources.append(Dest.mixerIn(i).port(mode).flatMap { byDest[$0.id] }.flatMap { Signal.from(Port(id: $0), mode: mode) })
                }
                DispatchQueue.main.async {
                    var r = self.router
                    for (k, v) in routes { r.routes[k] = v }
                    self.router = r
                    var mx = self.mixer
                    for (i, s) in sources.enumerated() { if let s { mx.channels[i].source = s } }
                    self.mixer = mx
                }
            } catch { DispatchQueue.main.async { self.lastError = "Reading routing failed: \(error)" } }
        }
    }

    var preset: Preset { Preset(mixer: mixer, router: router, knobPairs: knobPairs, opticalBIsSPDIF: opticalBIsSPDIF) }

    func apply(_ p: Preset) {
        var mx = p.mixer; mx.normalise()
        mixer = mx
        router = p.router
        if let k = p.knobPairs { for i in 0..<min(4, k.count) where k[i] != knobPairs[i] { setKnob(pair: i, on: k[i]) } }
        if let o = p.opticalBIsSPDIF, o != opticalBIsSPDIF { setOpticalB(spdif: o) }
    }

    // MARK: - advanced (raw) access

    struct RawRoute: Identifiable { let id: Int; let entry: UInt32; let source: String; let dest: String; let level: Float }
    @Published var rawRoutes = [RawRoute]()
    @Published var rawRegisters = [UInt32]()

    static func portName(_ id: UInt8, asDest: Bool) -> String {
        let b = id >> 4, c = Int(id & 0xF)
        switch b {
        case 0: return c < 2 ? "S/PDIF Coax \(c == 0 ? "L" : "R")" : (c == 6 || c == 7) ? "S/PDIF Optical \(c == 6 ? "L" : "R")" : "AES \(c + 1)"
        case 1: return c < 8 ? "ADAT A \(c + 1)" : "ADAT B \(c - 7)"
        case 2: return asDest ? "Mixer In \(c + 1)" : (c < 2 ? "Mixer Master \(c == 0 ? "L" : "R")" : "Aux \(c / 2) \(c % 2 == 0 ? "L" : "R")")
        case 3: return "Mixer In \(c + 17)"
        case 5: return asDest ? "Analog Out \(c + 1)" : "Analog In \(c + 1)"
        case 11: return asDest ? "To Computer \(c + 1)" : "From Computer \(c + 1)"
        case 12: return asDest ? "To Computer \(c + 11)" : "From Computer \(c + 11)"
        case 15: return "Mute"
        default: return "Block \(b) ch \(c + 1)"
        }
    }

    func refreshRawRouter() {
        let mode = self.mode
        io.async { [weak self] in
            guard let self, let map = self.map else { return }
            do {
                let cur = map.currentRouter(mode: mode.rawValue)
                let n = Int(try self.link.read(cur))
                let entries = try self.link.read(cur + 4, quads: n)
                let peaks = try self.link.read(map.peak, quads: map.peakQuads)
                var lv = [UInt32: Float]()
                for v in peaks { lv[v & 0xFFFF] = Float((v >> 16) & 0xFFF) / 4095 }
                let rows = entries.enumerated().map { (i, e) in
                    RawRoute(id: i, entry: e, source: Self.portName(UInt8((e >> 8) & 0xFF), asDest: false),
                             dest: Self.portName(UInt8(e & 0xFF), asDest: true), level: lv[e & 0xFFFF] ?? 0)
                }
                DispatchQueue.main.async { self.rawRoutes = rows }
            } catch { DispatchQueue.main.async { self.lastError = "Raw router read failed: \(error)" } }
        }
    }

    func rawRead(_ addr: UInt32, quads: Int) {
        io.async { [weak self] in
            guard let self else { return }
            do { let v = try self.link.read(addr, quads: quads); DispatchQueue.main.async { self.rawRegisters = v } }
            catch { DispatchQueue.main.async { self.lastError = "Read failed: \(error)" } }
        }
    }

    func rawWrite(_ addr: UInt32, _ values: [UInt32]) {
        io.async { [weak self] in
            guard let self else { return }
            do { try self.link.write(addr, values) } catch { DispatchQueue.main.async { self.lastError = "Write failed: \(error)" } }
        }
    }

    func rawEAP(_ opcode: UInt32, _ done: @escaping (Bool) -> Void) {
        io.async { [weak self] in
            guard let self else { return }
            let ok = (try? self.link.eap(opcode)) ?? false
            DispatchQueue.main.async { done(ok) }
        }
    }

    var eapBase: UInt32 { DICE.eapBase }
    var mapInfo: DiceMap? { map }

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

    func level(source s: Signal) -> Float { meters.snap.src[s.port(mode)?.id ?? 0xFF] ?? 0 }
    func level(dest p: Port?) -> Float { p.map { meters.snap.dst[$0.id] ?? 0 } ?? 0 }

    // meter taps (what a meter view shows), resolved for the current rate mode
    func meter(source s: Signal) -> MeterTap { MeterTap(isSource: true, id: s.port(mode)?.id) }
    func meter(dest p: Port?) -> MeterTap { MeterTap(isSource: false, id: p?.id) }
    func meter(mixerChannel i: Int) -> MeterTap { MeterTap(isSource: false, id: Dest.mixerIn(i).port(mode)?.id) }
    func meter(mixerOut o: Int) -> MeterTap { MeterTap(isSource: true, id: Port(Port.mixer, o).id) }

    // MARK: - mix bus outputs (which output pairs carry the master / an aux bus)

    /// bus 0 = master, k = aux k
    func busPair(_ bus: Int) -> SourcePair { bus == 0 ? .mixerMaster : .aux(bus) }
    func outputs(ofBus bus: Int) -> [OutputPair] { OutputPair.allCases.filter { pairSource($0) == busPair(bus) } }
    func setOutput(_ p: OutputPair, bus: Int, on: Bool) {
        if on { setPair(p, busPair(bus)); return }
        let (l, r) = p.dests
        router.routes[l] = l.playbackSource; router.routes[r] = r.playbackSource
    }
}

struct MeterReading: Equatable {
    var level: Float = 0, peak: Float = 0, clip = false
}

struct MeterTap: Hashable { var isSource: Bool; var id: UInt8? }

struct MeterSnapshot: Equatable {
    var src = [UInt8: Float](), dst = [UInt8: Float]()           // decayed levels
    var srcPeak = [UInt8: Float](), dstPeak = [UInt8: Float]()   // held peaks
    var srcClip = Set<UInt8>(), dstClip = Set<UInt8>()
}

/// Router peak meters with decay, peak hold and latching clip. Published once per poll.
@MainActor
final class MeterStore: ObservableObject {
    @Published private(set) var snap = MeterSnapshot()
    var peakHold: Double = 3
    private var srcTime = [UInt8: Date](), dstTime = [UInt8: Date]()

    func reading(_ t: MeterTap) -> MeterReading {
        guard let id = t.id else { return MeterReading() }
        return t.isSource ? MeterReading(level: snap.src[id] ?? 0, peak: snap.srcPeak[id] ?? 0, clip: snap.srcClip.contains(id))
                          : MeterReading(level: snap.dst[id] ?? 0, peak: snap.dstPeak[id] ?? 0, clip: snap.dstClip.contains(id))
    }

    func update(src: [UInt8: Float], dst: [UInt8: Float]) {
        var n = snap
        n.src = Self.decay(n.src, src); n.dst = Self.decay(n.dst, dst)
        Self.peaks(src, &n.srcPeak, &srcTime, &n.srcClip, peakHold)
        Self.peaks(dst, &n.dstPeak, &dstTime, &n.dstClip, peakHold)
        if n != snap { snap = n }
    }

    func reset() { srcTime = [:]; dstTime = [:]; snap.srcPeak = [:]; snap.dstPeak = [:]; snap.srcClip = []; snap.dstClip = [] }

    private static func decay(_ old: [UInt8: Float], _ new: [UInt8: Float]) -> [UInt8: Float] {
        var out = new
        for (k, v) in old { let d = max(new[k] ?? 0, v * 0.82); out[k] = d < 0.0002 ? nil : d }
        return out
    }

    private static func peaks(_ raw: [UInt8: Float], _ peak: inout [UInt8: Float], _ time: inout [UInt8: Date], _ clip: inout Set<UInt8>, _ hold: Double) {
        for (k, v) in raw where v >= 0.999 { clip.insert(k) }
        guard hold != 0 else { peak = [:]; return }
        let now = Date()
        for k in Set(raw.keys).union(peak.keys) {
            let v = raw[k] ?? 0, held = peak[k] ?? 0
            let expired = hold > 0 && now.timeIntervalSince(time[k] ?? .distantPast) > hold
            if v >= held || expired { peak[k] = v > 0 ? v : nil; time[k] = now }
        }
    }
}

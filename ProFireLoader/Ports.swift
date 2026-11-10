//
//  Ports.swift
//  ProFire 2626 router port map (DICE EAP router block/channel IDs).
//
//  A router entry is (source << 8) | destination, each byte = block << 4 | channel.
//

import Foundation

enum RateMode: Int { case low = 0, mid = 1, high = 2
    static func of(rate: Int) -> RateMode { rate > 96000 ? .high : rate > 48000 ? .mid : .low }
    var flag: UInt32 { [DICE.flagLow, DICE.flagMid, DICE.flagHigh][rawValue] }
}

struct Port: Hashable, Codable {
    var block: UInt8, channel: UInt8
    var id: UInt8 { block << 4 | channel }
    init(_ block: UInt8, _ channel: Int) { self.block = block; self.channel = UInt8(channel) }
    init(id: UInt8) { block = id >> 4; channel = id & 0xF }

    static let aes: UInt8 = 0, adat: UInt8 = 1, mixer: UInt8 = 2, mixer1: UInt8 = 3,
               ins1: UInt8 = 5, arx0: UInt8 = 11, arx1: UInt8 = 12, mute: UInt8 = 15
    static let muted = Port(mute, 0)
}

/// A logical, rate-independent signal (what the user picks), mapped to a router port per rate mode.
enum Signal: Hashable, Codable {
    case analogIn(Int)      // 0..7
    case adatAIn(Int)       // 0..7
    case adatBIn(Int)       // 0..7
    case spdifIn(Int)       // 0..1 (coax, AES0)
    case spdifOptIn(Int)    // 0..1 (optical port B in S/PDIF mode = AES channels 7/8, the "TOS" receiver)
    case swReturn(Int)      // 0..25 (computer playback channel)
    case mixerOut(Int)      // 0..15 (0/1 master, 2k/2k+1 aux k)
    case off

    func port(_ mode: RateMode) -> Port? {
        let smux = mode != .low
        switch self {
        case .analogIn(let c): return Port(Port.ins1, c)
        case .adatAIn(let c): return smux ? (c < 4 ? Port(Port.adat, c) : nil) : Port(Port.adat, c)
        case .adatBIn(let c): return smux ? (c < 4 ? Port(Port.adat, 4 + c) : nil) : Port(Port.adat, 8 + c)
        case .spdifIn(let c): return Port(Port.aes, c)
        case .spdifOptIn(let c): return Port(Port.aes, 6 + c)
        case .swReturn(let c):
            if c < 10 { return Port(Port.arx0, c) }
            let k = c - 10
            return k < (smux ? 8 : 16) ? Port(Port.arx1, k) : nil
        case .mixerOut(let c): return Port(Port.mixer, c)
        case .off: return Port.muted
        }
    }

    var name: String {
        switch self {
        case .analogIn(let c): return "Analog In \(c + 1)"
        case .adatAIn(let c): return "ADAT A In \(c + 1)"
        case .adatBIn(let c): return "ADAT B In \(c + 1)"
        case .spdifIn(let c): return "S/PDIF Coax In \(c == 0 ? "L" : "R")"
        case .spdifOptIn(let c): return "S/PDIF Optical In \(c == 0 ? "L" : "R")"
        case .swReturn(let c): return "SW Return \(c + 1)"
        case .mixerOut(let c):
            let side = c % 2 == 0 ? "L" : "R"
            return c < 2 ? "Mixer Master \(side)" : "Aux \(c / 2) \(side)"
        case .off: return "Off"
        }
    }

    static var all: [Signal] {
        (0..<8).map { .analogIn($0) } + (0..<8).map { .adatAIn($0) } + (0..<8).map { .adatBIn($0) } +
        [.spdifIn(0), .spdifIn(1), .spdifOptIn(0), .spdifOptIn(1)] + (0..<26).map { .swReturn($0) } +
        (0..<16).map { .mixerOut($0) } + [.off]
    }
    static func from(_ p: Port, mode: RateMode) -> Signal? {
        if p.block == Port.mute { return .off }
        return all.first { $0.port(mode) == p }
    }
    static var groups: [(String, [Signal])] {
        [("Software Returns", (0..<26).map { .swReturn($0) }),
         ("Mixer", (0..<16).map { .mixerOut($0) }),
         ("Analog Inputs", (0..<8).map { .analogIn($0) }),
         ("ADAT A Inputs", (0..<8).map { .adatAIn($0) }),
         ("ADAT B Inputs", (0..<8).map { .adatBIn($0) }),
         ("S/PDIF Inputs", [.spdifIn(0), .spdifIn(1), .spdifOptIn(0), .spdifOptIn(1)]),
         ("", [.off])]
    }
}

/// Every router destination, rate independent.
enum Dest: Hashable, Codable, Identifiable {
    case analogOut(Int), spdifOut(Int), spdifOptOut(Int), adatAOut(Int), adatBOut(Int), computerIn(Int), mixerIn(Int)

    var id: String { name }

    func port(_ mode: RateMode) -> Port? {
        let smux = mode != .low
        switch self {
        case .analogOut(let c): return Port(Port.ins1, c)
        case .spdifOut(let c): return Port(Port.aes, c)
        case .spdifOptOut(let c): return Port(Port.aes, 6 + c)
        case .adatAOut(let c): return smux ? (c < 4 ? Port(Port.adat, c) : nil) : Port(Port.adat, c)
        case .adatBOut(let c): return smux ? (c < 4 ? Port(Port.adat, 4 + c) : nil) : Port(Port.adat, 8 + c)
        case .computerIn(let c):
            if c < 10 { return Port(Port.arx0, c) }          // ATX0 has block id 0xB as a destination
            let k = c - 10
            return k < (smux ? 8 : 16) ? Port(Port.arx1, k) : nil
        case .mixerIn(let c): return c < 16 ? Port(Port.mixer, c) : Port(Port.mixer1, c - 16)
        }
    }

    var name: String {
        switch self {
        case .analogOut(let c): return "Analog Out \(c + 1)"
        case .spdifOut(let c): return "S/PDIF Coax Out \(c == 0 ? "L" : "R")"
        case .spdifOptOut(let c): return "S/PDIF Optical Out \(c == 0 ? "L" : "R")"
        case .adatAOut(let c): return "ADAT A Out \(c + 1)"
        case .adatBOut(let c): return "ADAT B Out \(c + 1)"
        case .computerIn(let c): return "Computer In \(c + 1)"
        case .mixerIn(let c): return "Mixer In \(c + 1)"
        }
    }

    /// Factory routing, like M-Audio's: Analog Out 1/2 = mixer master (the mixer carries
    /// software returns 1/2 on channels 17/18), everything else straight from the computer.
    var defaultSource: Signal {
        switch self {
        case .analogOut(let c) where c < 2: return .mixerOut(c)
        case .mixerIn(let c) where c >= 16: return .swReturn(c - 16)
        default: return playbackSource
        }
    }

    /// The plain "sound card" source: software return for outputs, inputs for the computer.
    var playbackSource: Signal {
        switch self {
        case .analogOut(let c): return .swReturn(c)
        case .spdifOut(let c): return .swReturn(8 + c)
        case .spdifOptOut: return .off
        case .adatAOut(let c): return .swReturn(10 + c)
        case .adatBOut(let c): return .swReturn(18 + c)
        case .computerIn(let c):
            if c < 8 { return .analogIn(c) }
            if c < 10 { return .spdifIn(c - 8) }
            if c < 18 { return .adatAIn(c - 10) }
            return .adatBIn(c - 18)
        case .mixerIn(let c): return c < 8 ? .analogIn(c) : c < 16 ? .adatAIn(c - 8) : .spdifIn(c - 16)
        }
    }

    static var outputGroups: [(String, [Dest])] {
        [("Analog Outputs", (0..<8).map { .analogOut($0) }),
         ("S/PDIF Outputs", [.spdifOut(0), .spdifOut(1), .spdifOptOut(0), .spdifOptOut(1)]),
         ("ADAT A Outputs", (0..<8).map { .adatAOut($0) }),
         ("ADAT B Outputs", (0..<8).map { .adatBOut($0) })]
    }
    static var computerInputs: [Dest] { (0..<26).map { .computerIn($0) } }
    static var routable: [Dest] { outputGroups.flatMap { $0.1 } + computerInputs }
}

/// Hardware outputs, as the original panel's router lists them (by pair).
enum OutputPair: Int, CaseIterable, Identifiable, Codable {
    case analog12, analog34, analog56, analog78, spdif, spdifOpt, adatA12, adatA34, adatA56, adatA78, adatB12, adatB34, adatB56, adatB78
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .analog12: return "Analog Out 1/2"
        case .analog34: return "Analog Out 3/4"
        case .analog56: return "Analog Out 5/6"
        case .analog78: return "Analog Out 7/8"
        case .spdif: return "S/PDIF Coax Out"
        case .spdifOpt: return "S/PDIF Optical Out"
        case .adatA12: return "ADAT A Out 1/2"
        case .adatA34: return "ADAT A Out 3/4"
        case .adatA56: return "ADAT A Out 5/6"
        case .adatA78: return "ADAT A Out 7/8"
        case .adatB12: return "ADAT B Out 1/2"
        case .adatB34: return "ADAT B Out 3/4"
        case .adatB56: return "ADAT B Out 5/6"
        case .adatB78: return "ADAT B Out 7/8"
        }
    }
    var dests: (Dest, Dest) {
        switch self {
        case .analog12: return (.analogOut(0), .analogOut(1))
        case .analog34: return (.analogOut(2), .analogOut(3))
        case .analog56: return (.analogOut(4), .analogOut(5))
        case .analog78: return (.analogOut(6), .analogOut(7))
        case .spdif: return (.spdifOut(0), .spdifOut(1))
        case .spdifOpt: return (.spdifOptOut(0), .spdifOptOut(1))
        case .adatA12, .adatA34, .adatA56, .adatA78:
            let c = (rawValue - OutputPair.adatA12.rawValue) * 2; return (.adatAOut(c), .adatAOut(c + 1))
        case .adatB12, .adatB34, .adatB56, .adatB78:
            let c = (rawValue - OutputPair.adatB12.rawValue) * 2; return (.adatBOut(c), .adatBOut(c + 1))
        }
    }
    func ports(_ mode: RateMode) -> (Port, Port)? {
        let (l, r) = dests
        guard let pl = l.port(mode), let pr = r.port(mode) else { return nil }
        return (pl, pr)
    }
}

/// What feeds an output pair (the original panel routes pairs).
enum SourcePair: Hashable, Codable, Identifiable {
    case analogIn(Int), adatAIn(Int), adatBIn(Int), spdifIn, spdifOptIn, swReturn(Int), mixerMaster, aux(Int), off
    var id: String { name }
    var name: String {
        switch self {
        case .analogIn(let p): return "Analog In \(p * 2 + 1)/\(p * 2 + 2)"
        case .adatAIn(let p): return "ADAT A In \(p * 2 + 1)/\(p * 2 + 2)"
        case .adatBIn(let p): return "ADAT B In \(p * 2 + 1)/\(p * 2 + 2)"
        case .spdifIn: return "S/PDIF Coax In"
        case .spdifOptIn: return "S/PDIF Optical In"
        case .swReturn(let p): return "SW Return \(p * 2 + 1)/\(p * 2 + 2)"
        case .mixerMaster: return "Mixer Master"
        case .aux(let k): return "Aux Send \(k)"
        case .off: return "Off"
        }
    }
    var signals: (Signal, Signal) {
        switch self {
        case .analogIn(let p): return (.analogIn(2 * p), .analogIn(2 * p + 1))
        case .adatAIn(let p): return (.adatAIn(2 * p), .adatAIn(2 * p + 1))
        case .adatBIn(let p): return (.adatBIn(2 * p), .adatBIn(2 * p + 1))
        case .spdifIn: return (.spdifIn(0), .spdifIn(1))
        case .spdifOptIn: return (.spdifOptIn(0), .spdifOptIn(1))
        case .swReturn(let p): return (.swReturn(2 * p), .swReturn(2 * p + 1))
        case .mixerMaster: return (.mixerOut(0), .mixerOut(1))
        case .aux(let k): return (.mixerOut(2 * k), .mixerOut(2 * k + 1))
        case .off: return (.off, .off)
        }
    }
    static var groups: [(String, [SourcePair])] {
        [("Mixer", [.mixerMaster] + (1...7).map { .aux($0) }),
         ("Software Returns", (0..<13).map { .swReturn($0) }),
         ("Analog Inputs", (0..<4).map { .analogIn($0) }),
         ("ADAT A Inputs", (0..<4).map { .adatAIn($0) }),
         ("ADAT B Inputs", (0..<4).map { .adatBIn($0) }),
         ("Digital Inputs", [.spdifIn, .spdifOptIn]),
         ("", [.off])]
    }
    /// Identify a pair from two channel sources; nil = not a standard pair ("Custom").
    static func from(_ l: Signal, _ r: Signal) -> SourcePair? {
        for (_, list) in groups { for sp in list where sp.signals == (l, r) { return sp } }
        return nil
    }
}

/// Inputs a mixer channel can take (single channels, like the original's channel source menus).
enum MixerSources {
    static var groups: [(String, [Signal])] {
        [("Analog Inputs", (0..<8).map { .analogIn($0) }),
         ("ADAT A Inputs", (0..<8).map { .adatAIn($0) }),
         ("ADAT B Inputs", (0..<8).map { .adatBIn($0) }),
         ("S/PDIF", [.spdifIn(0), .spdifIn(1), .spdifOptIn(0), .spdifOptIn(1)]),
         ("Software Returns", (0..<26).map { .swReturn($0) }),
         ("", [.off])]
    }
}

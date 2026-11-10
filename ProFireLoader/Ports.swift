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
    case spdifIn(Int)       // 0..1 (coax)
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
        case .spdifIn(let c): return "S/PDIF In \(c == 0 ? "L" : "R")"
        case .swReturn(let c): return "SW Return \(c + 1)"
        case .mixerOut(let c):
            let side = c % 2 == 0 ? "L" : "R"
            return c < 2 ? "Mixer Master \(side)" : "Aux \(c / 2) \(side)"
        case .off: return "Off"
        }
    }
}

/// Hardware outputs, as the original panel's router lists them (by pair).
enum OutputPair: Int, CaseIterable, Identifiable, Codable {
    case analog12, analog34, analog56, analog78, spdif, adatA12, adatA34, adatA56, adatA78, adatB12, adatB34, adatB56, adatB78
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .analog12: return "Analog Out 1/2"
        case .analog34: return "Analog Out 3/4"
        case .analog56: return "Analog Out 5/6"
        case .analog78: return "Analog Out 7/8"
        case .spdif: return "S/PDIF Coax Out"
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
    /// Destination ports (left, right) for a rate mode; nil when the port doesn't exist at that rate.
    func ports(_ mode: RateMode) -> (Port, Port)? {
        let smux = mode != .low
        func adat(_ base: Int, _ pair: Int) -> (Port, Port)? {
            let c = pair * 2
            if smux { return c + 1 < 4 ? (Port(Port.adat, base / 2 + c), Port(Port.adat, base / 2 + c + 1)) : nil }
            return (Port(Port.adat, base + c), Port(Port.adat, base + c + 1))
        }
        switch self {
        case .analog12: return (Port(Port.ins1, 0), Port(Port.ins1, 1))
        case .analog34: return (Port(Port.ins1, 2), Port(Port.ins1, 3))
        case .analog56: return (Port(Port.ins1, 4), Port(Port.ins1, 5))
        case .analog78: return (Port(Port.ins1, 6), Port(Port.ins1, 7))
        case .spdif: return (Port(Port.aes, 0), Port(Port.aes, 1))
        case .adatA12: return adat(0, 0)
        case .adatA34: return adat(0, 1)
        case .adatA56: return adat(0, 2)
        case .adatA78: return adat(0, 3)
        case .adatB12: return adat(8, 0)
        case .adatB34: return adat(8, 1)
        case .adatB56: return adat(8, 2)
        case .adatB78: return adat(8, 3)
        }
    }
    /// Factory default: SW returns in order.
    var defaultSource: SourcePair {
        switch self {
        case .analog12: return .swReturn(0)
        case .analog34: return .swReturn(1)
        case .analog56: return .swReturn(2)
        case .analog78: return .swReturn(3)
        case .spdif: return .swReturn(4)
        default: return .swReturn(5 + rawValue - OutputPair.adatA12.rawValue)
        }
    }
}

/// What feeds an output pair (the original panel routes pairs).
enum SourcePair: Hashable, Codable, Identifiable {
    case analogIn(Int), adatAIn(Int), adatBIn(Int), spdifIn, swReturn(Int), mixerMaster, aux(Int), off
    var id: String { name }
    var name: String {
        switch self {
        case .analogIn(let p): return "Analog In \(p * 2 + 1)/\(p * 2 + 2)"
        case .adatAIn(let p): return "ADAT A In \(p * 2 + 1)/\(p * 2 + 2)"
        case .adatBIn(let p): return "ADAT B In \(p * 2 + 1)/\(p * 2 + 2)"
        case .spdifIn: return "S/PDIF Coax In"
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
         ("Digital Inputs", [.spdifIn]),
         ("", [.off])]
    }
    /// Identify a pair from the two router sources (for reading the device state back).
    static func from(_ l: Port?, _ r: Port?, mode: RateMode) -> SourcePair? {
        for (_, list) in groups {
            for sp in list {
                let (a, b) = sp.signals
                if a.port(mode) == l && b.port(mode) == r { return sp }
            }
        }
        return nil
    }
}

/// Inputs a mixer channel can take (single channels, like the original's channel source menus).
enum MixerSources {
    static var groups: [(String, [Signal])] {
        [("Analog Inputs", (0..<8).map { .analogIn($0) }),
         ("ADAT A Inputs", (0..<8).map { .adatAIn($0) }),
         ("ADAT B Inputs", (0..<8).map { .adatBIn($0) }),
         ("S/PDIF", [.spdifIn(0), .spdifIn(1)]),
         ("Software Returns", (0..<26).map { .swReturn($0) }),
         ("", [.off])]
    }
}

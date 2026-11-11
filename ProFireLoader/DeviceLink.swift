//
//  DeviceLink.swift
//  Talks to the ProFire driver's control user client (DICE register space).
//

import Foundation
import IOKit

enum LinkError: Error, CustomStringConvertible {
    case noDriver, open(kern_return_t), call(kern_return_t)
    var description: String {
        switch self {
        case .noDriver: return "ProFire driver not running"
        case .open(let k): return String(format: "cannot open driver (0x%x)", k)
        case .call(let k): return String(format: "driver call failed (0x%x)", k)
        }
    }
}

struct DriverInfo {
    var found = false, node: UInt64 = 0, rate: Int = 0, streaming = false, locked = false
    var controllerGUID: UInt64 = 0        // the FireWire controller this driver instance runs on
}

/// Raw DICE access. All calls are synchronous; use from a background queue.
final class DeviceLink {
    private var conn: io_connect_t = 0
    /// Registry entry ID of the driver instance (one per FireWire controller); nil = the first one.
    let serviceID: UInt64?

    init(serviceID: UInt64? = nil) { self.serviceID = serviceID }

    /// Registry IDs of all running driver instances.
    static func services() -> [UInt64] {
        var ids = [UInt64]()
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI"), &it) == KERN_SUCCESS else { return ids }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 { var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(s, &id); ids.append(id); IOObjectRelease(s); s = IOIteratorNext(it) }
        return ids.sorted()
    }

    deinit { close() }

    var isOpen: Bool { conn != 0 }

    func open() throws {
        if conn != 0 { return }
        let svc: io_service_t
        if let serviceID, let m = IORegistryEntryIDMatching(serviceID) { svc = IOServiceGetMatchingService(kIOMainPortDefault, m) }
        else { svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI")) }
        guard svc != 0 else { throw LinkError.noDriver }
        defer { IOObjectRelease(svc) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(svc, mach_task_self_, 0xFD000000, &c)
        guard kr == KERN_SUCCESS else { throw LinkError.open(kr) }
        conn = c
    }

    func close() {
        if conn != 0 { IOServiceClose(conn); conn = 0 }
    }

    func info() throws -> DriverInfo {
        try open()
        var out = [UInt64](repeating: 0, count: 8); var n: UInt32 = 8
        let kr = IOConnectCallScalarMethod(conn, 0, nil, 0, &out, &n)
        guard kr == KERN_SUCCESS else { close(); throw LinkError.call(kr) }
        return DriverInfo(found: out[0] != 0, node: out[1], rate: Int(out[2]), streaming: out[3] != 0, locked: out[4] != 0,
                          controllerGUID: out[7])
    }

    func read(_ lo: UInt32, quads: Int) throws -> [UInt32] {
        try open()
        var result = [UInt32]()
        var addr = lo, left = quads
        while left > 0 {
            let n = min(left, 1024)
            var inp: [UInt64] = [UInt64(addr), UInt64(n * 4)]
            var buf = [UInt8](repeating: 0, count: n * 4); var sz = n * 4
            let kr = IOConnectCallMethod(conn, 1, &inp, 2, nil, 0, nil, nil, &buf, &sz)
            guard kr == KERN_SUCCESS else { if kr == kIOReturnNotAttached { close() }; throw LinkError.call(kr) }
            for i in stride(from: 0, to: sz, by: 4) {
                result.append(UInt32(buf[i]) << 24 | UInt32(buf[i + 1]) << 16 | UInt32(buf[i + 2]) << 8 | UInt32(buf[i + 3]))
            }
            addr += UInt32(n * 4); left -= n
        }
        return result
    }

    func read(_ lo: UInt32) throws -> UInt32 { try read(lo, quads: 1)[0] }

    func write(_ lo: UInt32, _ values: [UInt32]) throws {
        try open()
        var data = [UInt8](); data.reserveCapacity(values.count * 4)
        for v in values { data += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var inp: [UInt64] = [UInt64(lo)]
        let kr = IOConnectCallMethod(conn, 2, &inp, 1, data, data.count, nil, nil, nil, nil)
        guard kr == KERN_SUCCESS else { throw LinkError.call(kr) }
    }

    func write(_ lo: UInt32, _ value: UInt32) throws { try write(lo, [value]) }

    @discardableResult
    func eap(_ opcode: UInt32) throws -> Bool {
        try open()
        var inp: [UInt64] = [UInt64(opcode)]
        var out: [UInt64] = [0]; var n: UInt32 = 1
        let kr = IOConnectCallScalarMethod(conn, 3, &inp, 1, &out, &n)
        guard kr == KERN_SUCCESS else { throw LinkError.call(kr) }
        return out[0] == 1
    }
}

// MARK: - DICE / EAP layout

enum DICE {
    static let base: UInt32 = 0xE000_0000
    static let eapBase: UInt32 = 0xE020_0000

    // Global section byte offsets
    static let clockSelect: UInt32 = 0x4C
    static let status: UInt32 = 0x54
    static let extStatus: UInt32 = 0x58
    static let sampleRate: UInt32 = 0x5C

    // EAP command opcodes / flags
    static let ldRouter: UInt32 = 0x0001
    static let ldStreamCfg: UInt32 = 0x0002
    static let ldFlashCfg: UInt32 = 0x0004
    static let stFlashCfg: UInt32 = 0x0005
    static let flagLow: UInt32 = 1 << 16
    static let flagMid: UInt32 = 1 << 17
    static let flagHigh: UInt32 = 1 << 18

    // Application space quadlet 0
    static let appKnobMask: UInt32 = 0x0F           // master volume knob: analog out pairs
    static let appOpticalBSPDIF: UInt32 = 0x10      // optical port B in S/PDIF mode
}

/// Offsets (bytes, absolute addrLo) of the DICE global section and the EAP sections.
struct DiceMap {
    var global: UInt32 = 0
    var mixer: UInt32 = 0, mixerQuads = 0
    var peak: UInt32 = 0, peakQuads = 0
    var router: UInt32 = 0, routerQuads = 0
    var stream: UInt32 = 0, streamQuads = 0
    var current: UInt32 = 0
    var standalone: UInt32 = 0
    var application: UInt32 = 0
    var mixerInputs = 18, mixerOutputs = 16

    static func load(_ link: DeviceLink) throws -> DiceMap {
        var m = DiceMap()
        let sec = try link.read(DICE.base, quads: 10)
        m.global = DICE.base + sec[0] * 4
        let ext = try link.read(DICE.eapBase, quads: 18)
        m.mixer = DICE.eapBase + ext[4] * 4; m.mixerQuads = Int(ext[5])
        m.peak = DICE.eapBase + ext[6] * 4; m.peakQuads = Int(ext[7])
        m.router = DICE.eapBase + ext[8] * 4; m.routerQuads = Int(ext[9])
        m.stream = DICE.eapBase + ext[10] * 4; m.streamQuads = Int(ext[11])
        m.current = DICE.eapBase + ext[12] * 4
        m.standalone = DICE.eapBase + ext[14] * 4
        m.application = DICE.eapBase + ext[16] * 4
        let caps = try link.read(DICE.eapBase + ext[0] * 4, quads: 2)
        let mixCaps = caps[1]
        if mixCaps & 1 != 0 {
            m.mixerInputs = Int((mixCaps >> 16) & 0xFF)
            m.mixerOutputs = Int((mixCaps >> 24) & 0xFF)
        }
        return m
    }

    /// Router of the current configuration for a rate mode (0 low, 1 mid, 2 high).
    func currentRouter(mode: Int) -> UInt32 { current + UInt32(mode) * 0x2000 }
    func mixerCoef(out: Int, input: Int) -> UInt32 { mixer + UInt32(4 * (1 + out * mixerInputs + input)) }
}

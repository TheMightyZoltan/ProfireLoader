// pfreg: raw DICE register access through the ProFire driver's control user client.
//   pfreg read  <addrLo> [bytes=4]      print quadlets (big-endian values)
//   pfreg write <addrLo> <value> [...]  write consecutive quadlets
//   pfreg eap   <opcode>                run an EAP command (execute bit added)
//   pfreg info
// Addresses are the low 32 bits of the DICE private space (e.g. 0xE0200000 = EAP base).
import IOKit
import Foundation

func num(_ s: String) -> UInt64 { s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16)! : UInt64(s)! }

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: pfreg read|write|eap|info ..."); exit(2) }
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("ProFireOHCI"))
guard svc != 0 else { print("driver not found"); exit(1) }
var conn: io_connect_t = 0
let kr = IOServiceOpen(svc, mach_task_self_, 0xFD000000, &conn)
guard kr == KERN_SUCCESS else { print(String(format: "open failed 0x%x", kr)); exit(1) }
defer { IOServiceClose(conn) }

switch args[1] {
case "info":
    var out = [UInt64](repeating: 0, count: 8); var n: UInt32 = 8
    IOConnectCallScalarMethod(conn, 0, nil, 0, &out, &n)
    print("found \(out[0]) node 0x\(String(out[1], radix: 16)) rate \(out[2]) streaming \(out[3]) locked \(out[4]) tx \(out[5]) rx \(out[6])")
case "read":
    let lo = num(args[2]); let bytes = args.count > 3 ? Int(num(args[3])) : 4
    var inp: [UInt64] = [lo, UInt64(bytes)]
    var buf = [UInt8](repeating: 0, count: bytes); var sz = bytes
    let r = IOConnectCallMethod(conn, 1, &inp, 2, nil, 0, nil, nil, &buf, &sz)
    guard r == KERN_SUCCESS else { print(String(format: "read failed 0x%x", r)); exit(1) }
    var line = ""
    for i in stride(from: 0, to: sz, by: 4) {
        let v = UInt32(buf[i]) << 24 | UInt32(buf[i+1]) << 16 | UInt32(buf[i+2]) << 8 | UInt32(buf[i+3])
        line += String(format: "%08x ", v)
        if (i / 4) % 8 == 7 { print(String(format: "%08x: ", UInt32(lo) + UInt32(i) - 28) + line); line = "" }
    }
    if !line.isEmpty { print(line) }
case "write":
    let lo = num(args[2])
    var data = [UInt8]()
    for a in args[3...] { let v = UInt32(num(a)); data += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    var inp: [UInt64] = [lo]
    let r = IOConnectCallMethod(conn, 2, &inp, 1, data, data.count, nil, nil, nil, nil)
    print(r == KERN_SUCCESS ? "ok" : String(format: "write failed 0x%x", r))
case "eap":
    var inp: [UInt64] = [num(args[2])]
    var out: [UInt64] = [0]; var n: UInt32 = 1
    let r = IOConnectCallScalarMethod(conn, 3, &inp, 1, &out, &n)
    print(r == KERN_SUCCESS && out[0] == 1 ? "ok" : "failed (\(r), \(out[0]))")
default:
    print("unknown command")
}

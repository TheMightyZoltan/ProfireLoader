//
//  DriverVersions.swift
//  Which driver versions are bundled, installed and running (for the Driver tab).
//

import Foundation
import IOKit

struct DriverVersions {
    struct Installed: Hashable { var version: String; var state: String }
    struct Instance: Hashable { var controller: String; var build: Int? }

    var app = ""
    var bundled = ""
    var installed: [Installed] = []
    var running: [Instance] = []

    /// macOS keeps the old driver until it is replaced; new controllers can't start meanwhile.
    var upgradePending: Bool { installed.contains { $0.state.contains("terminating") || $0.state.contains("waiting") } }

    static func load() -> DriverVersions {
        var v = DriverVersions()
        let b = Bundle.main
        v.app = "\(b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"
        let dext = b.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/local.profire.Loader.ProFireOHCI.dext")
        v.bundled = (Bundle(url: dext)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        v.installed = installedDrivers()
        v.running = runningInstances()
        return v
    }

    /// `systemextensionsctl list` lines for our driver: "(0.5.65/65) ... [activated enabled]".
    private static func installedDrivers() -> [Installed] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.split(separator: "\n").compactMap { line -> Installed? in
            guard line.contains("local.profire.Loader.ProFireOHCI ("),
                  let o = line.range(of: "ProFireOHCI ("), let c = line[o.upperBound...].firstIndex(of: ")") else { return nil }
            let ver = String(line[o.upperBound..<c]).split(separator: "/").first.map(String.init) ?? "?"
            let state = line.range(of: "[").flatMap { s in line[s.upperBound...].firstIndex(of: "]").map { String(line[s.upperBound..<$0]) } } ?? ""
            return Installed(version: ver, state: state)
        }
    }

    /// FireWire controllers (LSI FW643) and the build of the driver instance on each.
    /// The driver's match score is 10000 + build, so the matched personality tells the version.
    private static func runningInstances() -> [Instance] {
        var result = [Instance]()
        guard let match = IOServiceNameMatching("pci11c1,5901") else { return result }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(svc, &id)
            var build: Int?
            // The driver instance is the controller's "ProFireOHCI" child service.
            var kids: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(svc, kIOServicePlane, &kids) == KERN_SUCCESS {
                var kid = IOIteratorNext(kids)
                while kid != 0 {
                    var name = [CChar](repeating: 0, count: 128)
                    IORegistryEntryGetName(kid, &name)
                    if String(cString: name) == "ProFireOHCI",
                       let pers = IORegistryEntryCreateCFProperty(kid, "IOMatchedPersonality" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                       let score = pers["IOProbeScore"] as? Int {
                        build = score - 10000
                    }
                    IOObjectRelease(kid)
                    kid = IOIteratorNext(kids)
                }
                IOObjectRelease(kids)
            }
            result.append(Instance(controller: String(format: "0x%llx", id), build: build))
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        return result
    }
}

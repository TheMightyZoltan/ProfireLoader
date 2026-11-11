//
//  DeviceManager.swift
//  One ProFireModel per driver instance (FireWire controller), which ProFires the mixer shows,
//  and which one the single-device tabs (Router, Hardware, Meters, Advanced) edit.
//

import Foundation
import Combine

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var models: [ProFireModel] = []
    @Published var currentGUID: String { didSet { UserDefaults.standard.set(currentGUID, forKey: "currentDevice") } }
    @Published var hidden: Set<String> { didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenInMixer") } }
    @Published var auxRows: Int { didSet { UserDefaults.standard.set(auxRows, forKey: "auxRows"); for m in models { m.auxRows = auxRows } } }
    @Published var peakHold: Double { didSet { for m in models { m.peakHold = peakHold } } }
    @Published var keepStreaming: Bool {
        didSet { UserDefaults.standard.set(keepStreaming, forKey: "keepStreaming"); for m in devices { m.setKeepStreaming(keepStreaming) } }
    }

    private var subs = [UInt64: AnyCancellable]()
    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        currentGUID = d.string(forKey: "currentDevice") ?? ""
        hidden = Set(d.stringArray(forKey: "hiddenInMixer") ?? [])
        auxRows = d.object(forKey: "auxRows") != nil ? max(1, min(7, d.integer(forKey: "auxRows"))) : 2
        peakHold = d.object(forKey: "peakHold") != nil ? d.double(forKey: "peakHold") : 3
        keepStreaming = d.object(forKey: "keepStreaming") as? Bool ?? true
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } }
    }

    /// Track driver instances: a model per instance; a placeholder (service 0 = "first one")
    /// while none is running, so the window can show the driver status.
    func scan() {
        let ids = DeviceLink.services()
        var changed = false
        for id in ids where !models.contains(where: { $0.serviceID == id }) { add(ProFireModel(serviceID: id)); changed = true }
        for m in models where m.serviceID == 0 ? !ids.isEmpty : !ids.contains(m.serviceID) {
            m.shutdown(); subs[m.serviceID] = nil; changed = true
        }
        models.removeAll { $0.serviceID == 0 ? !ids.isEmpty : !ids.contains($0.serviceID) }
        if models.isEmpty { add(ProFireModel(serviceID: 0)); changed = true }
        if changed { objectWillChange.send() }
    }

    private func add(_ m: ProFireModel) {
        m.auxRows = auxRows; m.peakHold = peakHold
        models.append(m)
        // Republish when a ProFire appears, disappears or is renamed (not on every mixer move).
        subs[m.serviceID] = m.$connected.combineLatest(m.$controllerGUID, m.$identity.map(\.nickname))
            .dropFirst().removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// ProFires found (a controller without a ProFire isn't one).
    var devices: [ProFireModel] { models.filter { $0.connected && !$0.key.isEmpty } }

    /// The ProFire for the header status, and for every tab when only one is shown.
    var current: ProFireModel { shownInMixer.first { $0.key == currentGUID } ?? devices.filter { !hidden.contains($0.key) }.first ?? devices.first ?? models[0] }

    var shownInMixer: [ProFireModel] {
        let s = devices.filter { !hidden.contains($0.key) }
        return s.isEmpty ? [devices.first ?? models[0]] : s
    }

    func toggleShown(_ m: ProFireModel) {
        if hidden.contains(m.key) { hidden.remove(m.key) }
        else if devices.filter({ !hidden.contains($0.key) }).count > 1 { hidden.insert(m.key) }   // keep at least one
    }
}

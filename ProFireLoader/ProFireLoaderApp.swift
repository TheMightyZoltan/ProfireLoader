//
//  ProFireLoaderApp.swift
//  Tiny host app whose only job is to install/uninstall the ProFireOHCI dext.
//

import SwiftUI
import AppKit
import SystemExtensions

private let dextIdentifier = "local.profire.Loader.ProFireOHCI"

final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Idle"

    func activate() {
        status = "Requesting activation…"
        let req = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: dextIdentifier, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func deactivate() {
        status = "Requesting deactivation…"
        let req = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: dextIdentifier, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        status = "Replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)…"
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve it in System Settings › General › Login Items & Extensions › Driver Extensions."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:     status = "Done."
        case .willCompleteAfterReboot: status = "Done, takes effect after reboot."
        @unknown default:    status = "Finished (\(result.rawValue))."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        status = "Failed: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }
}

@main
struct ProFireLoaderApp: App {
    @StateObject private var manager = ExtensionManager()
    @StateObject private var model = ProFireModel()

    var body: some Scene {
        Window("ProFire Control", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.meters)
                .environmentObject(manager)
                .onAppear {
                    // `open ProFireLoader.app --args --activate` / `--deactivate` for scripted installs.
                    let args = CommandLine.arguments
                    if args.contains("--activate") { manager.activate() }
                    else if args.contains("--deactivate") { manager.deactivate() }
                    if args.contains("--selftest") { model.runSelfTest() }
                    if args.contains("--selftest-spdif") { model.runSPDIFSelfTest() }
                    // Debug: `--snapshot /path.png` renders this app's own window (no screen recording needed).
                    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                        let path = args[i + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { snapshotOwnWindow(to: path) }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)     // always open the panel, even if it was closed at last quit
        .restorationBehavior(.disabled)
    }
}

func snapshotOwnWindow(to path: String) {
    let wins = NSApp.windows
    FileHandle.standardError.write("snapshot: \(wins.count) windows: \(wins.map { "\($0.title) visible=\($0.isVisible) \($0.frame)" })\n".data(using: .utf8)!)
    guard let view = (wins.first(where: { $0.isVisible && $0.contentView != nil }) ?? wins.first)?.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

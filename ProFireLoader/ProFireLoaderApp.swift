//
//  ProFireLoaderApp.swift
//  Tiny host app whose only job is to install/uninstall the ProFireOHCI dext.
//

import SwiftUI
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

    var body: some Scene {
        WindowGroup("ProFire Driver Loader") {
            VStack(alignment: .leading, spacing: 14) {
                Text("ProFire OHCI test driver").font(.headline)
                Text("Stage 1: brings up the FireWire bus and logs each device's config ROM.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Install / Activate") { manager.activate() }
                    Button("Uninstall") { manager.deactivate() }
                }
                Text(manager.status).font(.callout).textSelection(.enabled)
                Divider()
                Text("Watch the driver log in Terminal:").font(.callout)
                Text("log stream --level debug --predicate 'eventMessage CONTAINS \"ProFireOHCI\"'")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .padding(20)
            .frame(minWidth: 520)
            .onAppear {
                // `open ProFireLoader.app --args --activate` / `--deactivate` for scripted testing.
                let args = CommandLine.arguments
                if args.contains("--activate") { manager.activate() }
                else if args.contains("--deactivate") { manager.deactivate() }
            }
        }
        .windowResizability(.contentSize)
    }
}

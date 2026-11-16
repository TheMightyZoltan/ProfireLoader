// profire-launch: started by launchd (LaunchAgent local.profire.autolaunch) when the driver
// publishes a ProFireUnit service, i.e. a ProFire appeared on the FireWire bus.
// It consumes the IOKit matching event (otherwise launchd relaunches it every ~10 s) and
// opens ProFire Control unless it is already running or the user turned the option off.
// Lives in ProFireLoader.app/Contents/Helpers/.
import AppKit
import XPC

let appID = "local.profire.Loader"

xpc_set_event_stream_handler("com.apple.iokit.matching", DispatchQueue.main) { _ in }

func openAppIfWanted() {
    let prefs = UserDefaults(suiteName: appID)
    if prefs?.object(forKey: "autoOpen") as? Bool == false { return }
    if !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty { return }
    // Helper: <app>/Contents/Helpers/profire-launch -> <app>
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, err in
        if let err { NSLog("profire-launch: could not open %@: %@", app.path, err.localizedDescription) }
    }
}

DispatchQueue.main.async { openAppIfWanted() }
// Stay a moment so launchd can deliver every pending match event, then exit.
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
dispatchMain()

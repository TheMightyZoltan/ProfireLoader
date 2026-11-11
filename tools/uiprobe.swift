// uiprobe: click-tests ProFire Control through the accessibility API and reports elements that move.
//   uiprobe dump                 list identified elements with frames
//   uiprobe test                 run the built-in click script, report moved elements per step
import Cocoa
import ApplicationServices

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
struct El { var key: String; var frame: CGRect; var el: AXUIElement }

guard AXIsProcessTrusted() else { print("NOT TRUSTED for accessibility"); exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.profire.Loader").first else { print("app not running"); exit(1) }
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func window() -> AXUIElement? {
    let ws = (attr(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return ws.first { (attr($0, kAXTitleAttribute) as? String) == "ProFire Control" } ?? ws.first
}

func collect() -> [El] {
    guard let w = window() else { return [] }
    var out = [El](), counts = [String: Int]()
    func walk(_ e: AXUIElement, _ depth: Int) {
        if depth > 40 { return }
        let id = attr(e, "AXIdentifier") as? String ?? ""
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        let title = (attr(e, kAXTitleAttribute) as? String) ?? (attr(e, kAXDescriptionAttribute) as? String) ?? ""
        var key = !id.isEmpty ? id : (["AXButton", "AXStaticText", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXSlider"].contains(role) && !title.isEmpty ? "\(role):\(title)" : "")
        if role == "AXStaticText", let v = attr(e, kAXValueAttribute) as? String, id.isEmpty { key = "text:\(v)" }
        if !key.isEmpty, let f = frame(e), f.width > 0 {
            let n = counts[key, default: 0]; counts[key] = n + 1
            out.append(El(key: n == 0 ? key : "\(key)#\(n)", frame: f, el: e))
        }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
    }
    walk(w, 0)
    return out
}

func mouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func click(_ p: CGPoint) { mouse(.leftMouseDown, p); usleep(40_000); mouse(.leftMouseUp, p); usleep(350_000) }
func drag(_ p: CGPoint, dy: CGFloat) {
    mouse(.leftMouseDown, p); usleep(50_000)
    for i in 1...10 { mouse(.leftMouseDragged, CGPoint(x: p.x, y: p.y + dy * CGFloat(i) / 10)); usleep(20_000) }
    mouse(.leftMouseUp, CGPoint(x: p.x, y: p.y + dy)); usleep(350_000)
}
func find(_ key: String) -> El? { collect().first { $0.key == key } }
func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
func escape() { let s = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: s, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap); usleep(300_000) }

func compare(_ label: String, _ a: [El], _ b: [El]) -> Int {
    let bm = Dictionary(b.map { ($0.key, $0.frame) }, uniquingKeysWith: { x, _ in x })
    var moved = [String]()
    for e in a { if let f = bm[e.key], abs(f.minX - e.frame.minX) > 0.5 || abs(f.minY - e.frame.minY) > 0.5 || abs(f.width - e.frame.width) > 0.5 || abs(f.height - e.frame.height) > 0.5 {
        moved.append("\(e.key) \(Int(e.frame.minX)),\(Int(e.frame.minY)) \(Int(e.frame.width))x\(Int(e.frame.height)) -> \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))") } }
    let gone = a.filter { bm[$0.key] == nil }.count
    print("[\(label)] \(a.count) elements, moved \(moved.count), disappeared \(gone)")
    for m in moved.prefix(12) { print("    moved: \(m)") }
    return moved.count
}

let args = CommandLine.arguments
app.activate()
usleep(500_000)
if args.count > 2 && args[1] == "shot" {   // capture only this app's window
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
       let n = w[kCGWindowNumber as String] as? Int {
        let t = Process(); t.launchPath = "/usr/sbin/screencapture"; t.arguments = ["-x", "-o", "-l\(n)", args[2]]; t.launch(); t.waitUntilExit()
    }
    exit(0)
}
if args.count > 1 && args[1] == "winsize" {
    if let w = window(), let f = frame(w) { print("window \(Int(f.width))x\(Int(f.height)) at \(Int(f.minX)),\(Int(f.minY))") }
    exit(0)
}
if args.count > 1 && args[1] == "dump" {
    let only = args.count > 2 ? Set(args[2...]) : nil
    for e in collect() where only == nil || only!.contains(e.key) {
        print(e.key, Int(e.frame.minX), Int(e.frame.minY), Int(e.frame.width), Int(e.frame.height), (attr(e.el, kAXValueAttribute) as? String) ?? "")
    }
    exit(0)
}

// Actions: (label, element key, kind) kinds: click, menu (click then escape), drag+/drag-
let steps: [(String, String, String)] = args.count > 2 ? [(args[2], args[2], args.count > 3 ? args[3] : "click")] : [
    ("tab Mixer", "tab.Mixer", "click"),
    ("mute 3", "mute.3", "click"), ("mute 3 off", "mute.3", "click"),
    ("solo 5", "solo.5", "click"), ("solo 5 off", "solo.5", "click"),
    ("unlink pair 2", "link.2", "click"), ("pan 3 drag", "pan.3", "drag-"), ("pan 3 dbl", "pan.3", "dbl"), ("relink pair 2", "link.2", "click"),
    ("aux1 ch1 up", "aux1.1", "drag-"), ("aux1 ch1 off", "aux1.1", "dbl"),
    ("fader 9 down", "fader.9", "drag+"), ("fader 9 0dB", "fader.9", "dbl"),
    ("aux mute 1", "auxmute.1", "click"), ("aux mute 1 off", "auxmute.1", "click"),
    ("master mute", "mute.master", "click"), ("master mute off", "mute.master", "click"),
    ("source menu 1", "source.1", "menu"), ("aux1 output menu", "busout.1", "menu"), ("master output menu", "busout.0", "menu"),
    ("peak hold", "peakhold", "click"),
    ("tab Router", "tab.Router", "click"),
    ("router channels", "AXRadioButton:Outputs (channels)", "click"), ("router computer", "AXRadioButton:Computer Inputs", "click"),
    ("router pairs", "AXRadioButton:Outputs (pairs)", "click"), ("tab Hardware", "tab.Hardware", "click"), ("tab Meters", "tab.Meters", "click"),
    ("tab Advanced", "tab.Advanced", "click"), ("tab Driver", "tab.Driver", "click"), ("back to Mixer", "tab.Mixer", "click"),
    ("aux rows +", "auxrows.plus", "click"), ("aux rows -", "auxrows.minus", "click"),
]
let tabKeys = Set(["tab.Mixer", "tab.Router", "tab.Hardware", "tab.Meters", "tab.Advanced", "tab.Driver"])
var total = 0
for (label, key, kind) in steps {
    guard let e = find(key) else { print("[\(label)] element \(key) NOT FOUND"); total += 1; continue }
    let before = collect()
    let p = center(e.frame)
    switch kind {
    case "drag-": drag(p, dy: -40)
    case "drag+": drag(p, dy: 40)
    case "dbl": mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
        let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!; d.setIntegerValueField(.mouseEventClickState, value: 2); d.post(tap: .cghidEventTap)
        let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!; u.setIntegerValueField(.mouseEventClickState, value: 2); u.post(tap: .cghidEventTap)
        usleep(400_000)
    case "menu": click(p); usleep(300_000); escape()
    case "sclick", "cclick":
        let fl: CGEventFlags = kind == "sclick" ? .maskShift : .maskCommand
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
            ev.flags = fl; ev.post(tap: .cghidEventTap); usleep(40_000)
        }
        usleep(350_000)
    case "sdrag-", "sdrag+":
        let dy: CGFloat = kind == "sdrag-" ? -40 : 40
        func ev(_ t: CGEventType, _ q: CGPoint) { let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: q, mouseButton: .left)!; e.flags = .maskShift; e.post(tap: .cghidEventTap) }
        ev(.leftMouseDown, p); usleep(50_000)
        for i in 1...10 { ev(.leftMouseDragged, CGPoint(x: p.x, y: p.y + dy * CGFloat(i) / 10)); usleep(20_000) }
        ev(.leftMouseUp, CGPoint(x: p.x, y: p.y + dy)); usleep(350_000)
    case let k where k.hasPrefix("rmenu"):      // right-click, then pick menu item N (1-based) with arrows
        let n = Int(k.dropFirst(5)) ?? 1
        for t in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)!.post(tap: .cghidEventTap); usleep(40_000)
        }
        usleep(400_000)
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n { CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: false)?.post(tap: .cghidEventTap); usleep(120_000) }
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(400_000)
    case let k where k.hasPrefix("type:"):
        click(p)
        let src = CGEventSource(stateID: .hidSystemState)
        // select all + delete first, so the field ends up holding exactly the text
        let a1 = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!; a1.flags = .maskCommand; a1.post(tap: .cghidEventTap)
        let a2 = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!; a2.flags = .maskCommand; a2.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(50_000)
        for ch in k.dropFirst(5).utf16 {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
                var c = ch; e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); e.post(tap: .cghidEventTap)
            }
            usleep(30_000)
        }
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(300_000)
    case "rclick", "orclick":
        let flags: CGEventFlags = kind == "orclick" ? .maskAlternate : []
        for t in [CGEventType.rightMouseDown, .rightMouseUp] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .right)!
            ev.flags = flags; ev.post(tap: .cghidEventTap); usleep(40_000)
        }
        usleep(350_000)
    default: click(p)
    }
    let after = collect()
    let ae = find(key)?.el ?? e.el
    let v = (attr(ae, kAXValueAttribute) as? String) ?? ""
    let extra = key.hasPrefix("fader.") ? " (label: \((find("val." + key.dropFirst(6)).flatMap { attr($0.el, kAXValueAttribute) as? String }) ?? "?"))" : ""
    print("  \(label): \(key) value = \(v)\(extra)")
    // switching tabs legitimately replaces the content: only the tab bar / header must stay put
    if key.hasPrefix("auxrows") {   // adding a knob row pushes the rows below it down; only check horizontal stability
        let bm = Dictionary(after.map { ($0.key, $0.frame) }, uniquingKeysWith: { x, _ in x })
        let h = before.filter { b in bm[b.key].map { abs($0.minX - b.frame.minX) > 0.5 } ?? false }
        print("[\(label)] horizontal moves: \(h.count) \(h.map { $0.key })"); total += h.count
    } else if key.hasPrefix("AXRadioButton:") {
        total += compare(label, before.filter { tabKeys.contains($0.key) || $0.key.hasPrefix("AXRadioButton:Outputs") || $0.key.hasPrefix("AXRadioButton:Computer") }, after)
    } else if tabKeys.contains(key) { total += compare(label, before.filter { tabKeys.contains($0.key) || $0.key.hasPrefix("text:ProFire") }, after) }
    else { total += compare(label, before, after) }
}
print("TOTAL moved/missing: \(total)")

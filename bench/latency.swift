// How long Frost takes to slide under a window that just came to the front. Run it through bench/run.sh,
// which wraps it in an app bundle so it can be the front app.
//   keys <out>   switches between its own two windows like ⌘` does (the app stays in front)
//   raise <out>  raises its windows from the background, like another app's window popping up
// Writes "avg max count misses" in milliseconds to <out>, or "nofront" when another app kept the front.
import AppKit

let mode = CommandLine.arguments[1], out = CommandLine.arguments[2]
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let top = NSScreen.screens[0].frame.maxY
func window(_ x: CGFloat) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    w.title = "Frost bench"
    w.setFrameTopLeftPoint(NSPoint(x: x, y: top - 200))
    return w
}
let a = window(200), b = window(600)

// ms until the window is the front normal-layer window with a Frost pane right under it (nil after 1.5s)
func frostUnder(_ w: NSWindow) -> Double? {
    let start = Date()
    while Date().timeIntervalSince(start) < 1.5 {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = list.filter { $0[kCGWindowLayer as String] as? Int == 0 }
        if normal.count > 1, normal[0][kCGWindowNumber as String] as? Int == w.windowNumber,
           normal[1][kCGWindowOwnerName as String] as? String == "Frost" {
            return Date().timeIntervalSince(start) * 1000
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    return nil
}

func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    var times: [Double?] = []
    if mode == "keys" {
        b.makeKeyAndOrderFront(nil)
        a.makeKeyAndOrderFront(nil)
        app.activate()
        let start = Date()
        while !app.isActive && Date().timeIntervalSince(start) < 3 { pause(0.05) }
        if !app.isActive {  // someone is using another app; switches here would measure nothing
            try? "nofront\n".write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        pause(0.6)
        for i in 0..<12 {
            let w = i % 2 == 0 ? b : a
            w.makeKeyAndOrderFront(nil)
            times.append(frostUnder(w))
            pause(Double.random(in: 0.3...0.55))  // random, so switches don't line up with Frost's 0.1s check
        }
    } else {
        for i in 0..<9 {
            let w = i % 2 == 0 ? a : b
            w.orderFrontRegardless()
            times.append(frostUnder(w))
            pause(Double.random(in: 0.3...0.55))
        }
    }
    let ok = times.compactMap { $0 }
    let line = ok.isEmpty ? "0 0 0 \(times.count)"
        : String(format: "%.0f %.0f %d %d", ok.reduce(0, +) / Double(ok.count), ok.max()!, ok.count, times.count - ok.count)
    try? (line + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    exit(0)
}
app.run()

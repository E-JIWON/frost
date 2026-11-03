import AppKit
import ServiceManagement
import SwiftUI

// Private APIs (shipping apps use these), all looked up at run time, so a macOS that drops one
// loses that feature instead of Frost failing to launch:
// - CABackdropLayer + windowServerAware blurs what's behind the window (the engine under NSVisualEffectView);
//   its variableBlur filter takes a strength mask, which gives the blur shapes.
// - CoreDock toggles Dock auto-hide.
// - The CGS Space calls tell a full-screen Space apart from a desktop.
func privateFunction<T>(_ name: String, as type: T.Type) -> T? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }  // -2 = RTLD_DEFAULT, every loaded image
}
let dockAutoHide = privateFunction("CoreDockGetAutoHideEnabled", as: (@convention(c) () -> Bool).self)
let setDockAutoHide = privateFunction("CoreDockSetAutoHideEnabled", as: (@convention(c) (Bool) -> Void).self)
let cgsConnection = privateFunction("CGSMainConnectionID", as: (@convention(c) () -> Int32).self)
let displaySpace = privateFunction("CGSManagedDisplayGetCurrentSpace", as: (@convention(c) (Int32, CFString) -> UInt64).self)
let spaceType = privateFunction("CGSSpaceGetType", as: (@convention(c) (Int32, UInt64) -> Int32).self)

// (value, title)
let modes = [("deep", "깊게"), ("ambient", "은은하게")]
let shapes = [("even", "균일"), ("bottom", "아래로"), ("top", "위로"), ("edges", "가장자리")]
// BDS ink, then the BDS comment colors deepened toward #241E18 in oklab (45%), like BDS deepens active text (62%).
let swatches = [("141210", "잉크"), ("3D483A", "세이지"), ("3D5961", "스카이"), ("685432", "샌드"), ("446148", "민트"), ("694144", "핑크")]
let bdsSage = "5A8268"

// MARK: layout

struct Win: Equatable { let id: Int; let rect: CGRect; let app: String }  // rect in window-list (top-left origin) coordinates

// Window-list rect -> rounded shape in the layer coordinates (bottom-left origin) of a pane covering `bounds`.
func localPath(_ r: CGRect, in bounds: CGRect) -> CGPath {
    let rect = CGRect(x: r.minX - bounds.minX, y: bounds.maxY - r.maxY, width: r.width, height: r.height)
    return CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
}

// For a pane covering `bounds`: the window it sits below (0 = none), and the windows under it that stay sharp
// anyway, as holes: excluded apps, and the topmost window of each app grouped with the focused one.
// `wins` runs front to back.
func layout(_ bounds: CGRect, _ wins: [Win], excluded: Set<String>, groups: [[String]], perScreen: Bool) -> (Int, CGPath) {
    let candidates = perScreen ? wins.filter { bounds.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) } : wins
    guard let front = candidates.first(where: { !excluded.contains($0.app) }),
          // a window filling the whole pane (a full-screen app) leaves nothing to frost, and in a
          // full-screen Space the pane would land on top of it instead of below
          !front.rect.contains(bounds)
    else { return (0, CGMutablePath()) }

    var partners = Set(groups.filter { $0.contains(front.app) }.joined())
    partners.remove(front.app)
    let below = wins.drop(while: { $0.id != front.id }).dropFirst()
    var sharp = Set<Int>()
    for w in below where partners.remove(w.app) != nil { sharp.insert(w.id) }  // first hit = topmost window

    // paint back to front: a sharp window opens a hole, any window above it closes that part again
    var holes: CGPath = CGMutablePath()
    for w in below.reversed() {
        let shape = localPath(w.rect, in: bounds)
        holes = excluded.contains(w.app) || sharp.contains(w.id) ? holes.union(shape) : holes.subtracting(shape)
    }
    return (front.id, holes)
}

// True once a condition has held for `after` seconds straight; any break restarts the clock.
struct Linger {
    let after: TimeInterval
    var since: TimeInterval?

    mutating func update(_ holds: Bool, at t: TimeInterval) -> Bool {
        guard holds else { since = nil; return false }
        if since == nil { since = t }
        return t - since! >= after
    }
}

// MARK: settings

// Prefs-backed settings shared by the panel and the engine. The look is saved per mode.
final class Settings: ObservableObject {
    let prefs = UserDefaults.standard
    var onChange: (String) -> Void = { _ in }  // gets the changed key
    @Published var enabled = true { didSet { onChange("enabled") } }

    init() {
        var defaults: [String: Any] = [
            "mode": "deep", "perScreen": true, "hideDock": true, "softenOnRest": true, "excluded": [String](),
            "appGroups": [["com.anthropic.claudefordesktop", "com.microsoft.VSCode"],
                          ["com.anthropic.claudefordesktop", "com.google.Chrome"]],
        ]
        for (m, blur, grain, tint) in [("ambient", 12.0, 0.04, 0.08), ("deep", 28.0, 0.08, 0.18)] {
            defaults["\(m).blur"] = blur
            defaults["\(m).grain"] = grain
            defaults["\(m).tint"] = tint
            defaults["\(m).color"] = "141210"
            defaults["\(m).shape"] = "even"
        }
        prefs.register(defaults: defaults)
    }

    var mode: String { get { prefs.string(forKey: "mode") ?? "deep" } set { save("mode", newValue) } }
    var blur: Double { get { prefs.double(forKey: look("blur")) } set { save(look("blur"), newValue) } }
    var grain: Double { get { prefs.double(forKey: look("grain")) } set { save(look("grain"), newValue) } }
    var tint: Double { get { prefs.double(forKey: look("tint")) } set { save(look("tint"), newValue) } }
    var color: String { get { prefs.string(forKey: look("color")) ?? "141210" } set { save(look("color"), newValue) } }
    var shape: String { get { prefs.string(forKey: look("shape")) ?? "even" } set { save(look("shape"), newValue) } }
    var perScreen: Bool { get { prefs.bool(forKey: "perScreen") } set { save("perScreen", newValue) } }
    var hideDock: Bool { get { prefs.bool(forKey: "hideDock") } set { save("hideDock", newValue) } }
    var softenOnRest: Bool { get { prefs.bool(forKey: "softenOnRest") } set { save("softenOnRest", newValue) } }
    var excluded: [String] { get { prefs.stringArray(forKey: "excluded") ?? [] } set { save("excluded", newValue) } }
    var groups: [[String]] { get { prefs.array(forKey: "appGroups") as? [[String]] ?? [] } set { save("appGroups", newValue) } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    private func look(_ k: String) -> String { "\(mode).\(k)" }

    private func save(_ k: String, _ v: Any) {
        objectWillChange.send()
        prefs.set(v, forKey: k)
        onChange(k)
    }
}

// MARK: engine

// A click-through pane of backdrop blur + tint + grain, one per screen, kept below a window.
@MainActor final class Overlay {
    let window: NSWindow
    let bounds: CGRect  // the pane, in window-list coordinates
    let display: CGDirectDisplayID
    let menuBar: CGFloat  // height of the menu bar strip at its top
    let content = CALayer()  // holds the three layers; its mask cuts holes for windows that stay sharp
    let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type ?? CALayer.self).init()  // plain layer = no blur
    let tint = CALayer()
    let grain = CALayer()
    var target = -1  // window number we sit below, 0 = hidden, -1 = reorder on next tick
    var holes: CGPath = CGMutablePath()
    var above: [CGRect] = []  // windows over the pane, the target included
    var soft = false  // faded down because the pointer rests on it

    init(screen: NSScreen) {
        let frame = screen.frame
        menuBar = frame.maxY - screen.visibleFrame.maxY
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .none  // keep out of screenshots and screen recordings
        // every Space incl. full-screen ones; .transient hides it in Mission Control
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.contentView = NSView()
        window.contentView!.wantsLayer = true
        window.setFrame(frame, display: false)
        bounds = CGRect(x: frame.minX, y: NSScreen.screens[0].frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0

        backdrop.setValue(true, forKey: "windowServerAware")  // (its "scale" key, for cheaper half-res blur, turns the blur off)
        grain.contents = noise(frame.size)
        grain.magnificationFilter = .nearest
        for l in [content, backdrop, tint, grain] { l.frame = CGRect(origin: .zero, size: frame.size) }
        [backdrop, tint, grain].forEach(content.addSublayer)
        window.contentView!.layer!.addSublayer(content)
    }

    // Whether this window-list point shows frost: on the pane, and not on a window above it, a hole or the menu bar.
    func isFrosted(at p: CGPoint) -> Bool {
        target != 0 && bounds.contains(p) && p.y >= bounds.minY + menuBar && !above.contains { $0.contains(p) }
            && !holes.contains(CGPoint(x: p.x - bounds.minX, y: bounds.maxY - p.y))
    }
}

@MainActor final class Frost: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let s = Settings()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    var overlays: [Overlay] = []
    var lastWins: [Win] = []
    var dirty = true  // settings or overlays changed since the last layout
    var tickQueued = false
    var resting = Linger(after: 0.5)  // pointer on frosted background
    var awayFromPanel = Linger(after: 0.6)
    var bundleIDs: [pid_t: String] = [:]
    let quitOnTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    var focusWatch: AXObserver?  // the front app's windows, see watchFrontApp
    var watchTries = 0
    var poll: Timer?
    var unseen: Set<String> = [] { didSet { setPolling() } }  // why nobody can see the screen right now

    func applicationDidFinishLaunching(_ note: Notification) {
        s.onChange = { [weak self] k in self?.settingChanged(k) }
        item.button?.image = menuIcon(on: true)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        let host = NSHostingController(rootView: Panel(s: s))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .semitransient  // stays open while the color panel is in use
        popover.delegate = self

        buildOverlays()
        syncDock()

        // React at once instead of waiting for the poll: app switches, Space changes,
        // clicks (focus can move within an app) and drags (windows move).
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(self, selector: #selector(soon), name: name, object: nil)
        }
        ws.addObserver(self, selector: #selector(appQuit), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(watchFrontApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Accessibility makes keyboard window switches (⌘`, ⌘N) show at once; without it those wait for the poll
        // below. Asked once per build (a new build is signed anew and needs it again); after that the panel offers it.
        let build = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { "\($0.timeIntervalSince1970)" } ?? ""
        if !AXIsProcessTrusted(), s.prefs.string(forKey: "askedAccessibility") != build {
            s.prefs.set(build, forKey: "askedAccessibility")
            askAccessibility()
        }
        watchFrontApp()
        NotificationCenter.default.addObserver(self, selector: #selector(buildOverlays),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] _ in self?.soon() }
        // The poll stops while nobody can see the screen: display asleep, another user's session, screen locked.
        let pauses: [(NotificationCenter, Notification.Name, Notification.Name, String)] = [
            (ws, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "asleep"),
            (ws, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "away"),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"),
             Notification.Name("com.apple.screenIsUnlocked"), "locked"),
        ]
        for (center, stop, resume, why) in pauses {
            center.addObserver(forName: stop, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.unseen.insert(why) }
            }
            center.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.unseen.remove(why)
                    self?.soon()
                }
            }
        }
        setPolling()
        // kill/pkill quit properly too, so the Dock gets put back
        signal(SIGTERM, SIG_IGN)
        quitOnTerm.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        quitOnTerm.resume()
    }

    // Catches what no event reports, like a background app's window popping up (a window list costs ~0.6ms).
    func setPolling() {
        if unseen.isEmpty, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {  // on the main run loop
                    self?.tick()
                    self?.followPointer()
                }
            }
        } else if !unseen.isEmpty {
            poll?.invalidate()
            poll = nil
        }
    }

    func followPointer() {
        guard let main = NSScreen.screens.first else { return }  // none for a moment while displays reconfigure
        let now = ProcessInfo.processInfo.systemUptime
        let p = NSEvent.mouseLocation
        let point = CGPoint(x: p.x, y: main.frame.maxY - p.y)  // window-list coordinates

        // Pointer resting on the background for 0.5s: you may be about to switch, so let the windows show through.
        let under = s.enabled && s.softenOnRest && !popover.isShown ? overlays.first { $0.isFrosted(at: point) } : nil
        soften(resting.update(under != nil, at: now) ? under : nil)

        // Close the panel once the pointer has been away from it, its menu bar icon and the color panel
        // (when that is actually on screen) for a moment.
        var away = false
        if popover.isShown, let panel = popover.contentViewController?.view.window?.frame, let icon = item.button?.window?.frame {
            var inside = panel.union(icon)
            if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.occlusionState.contains(.visible) {
                inside = inside.union(NSColorPanel.shared.frame)
            }
            away = !inside.insetBy(dx: -16, dy: -16).contains(p)
        }
        if awayFromPanel.update(away, at: now) { popover.performClose(nil) }
    }

    // A color panel left open without the panel's color well just floats there.
    func popoverDidClose(_ note: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
    }

    // Fade one overlay down to a light frost, and any other softened one back up.
    func soften(_ target: Overlay?) {
        for o in overlays where o.soft != (o === target) {
            o.soft = o === target
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = o.soft ? 0.35 : 0.25
                o.window.animator().alphaValue = o.soft ? 0.25 : 1
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        s.enabled = false
    }

    func settingChanged(_ k: String) {
        switch k {
        case "enabled": applyEnabled()
        case "hideDock": syncDock()
        case "softenOnRest": break  // followPointer reads it
        case "perScreen", "excluded", "appGroups":
            dirty = true
            tick()
        default: applyLook()  // mode and the per-mode look
        }
    }

    @objc func buildOverlays() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        applyLook()
        dirty = true
    }

    func applyLook() {
        let blur = variableBlur(s.blur, shapeMask(s.shape))
        let tint = color(s.color).withAlphaComponent(s.tint).cgColor
        for o in overlays {
            o.backdrop.filters = blur.map { [$0] }
            o.tint.backgroundColor = tint
            o.grain.opacity = Float(s.grain)
        }
    }

    // Coalesce bursts (a drag fires ~120 events a second) into one tick per frame.
    @objc func soon() {
        guard !tickQueued else { return }
        tickQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.tickQueued = false
            self?.tick()
        }
    }

    // Window focus, creation and moves inside the front app (keyboard-only changes no other event reports).
    // Re-attached on every app switch; a no-op until Frost has the Accessibility permission.
    @objc func watchFrontApp() {
        if let old = focusWatch { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes) }
        focusWatch = nil
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        var observer: AXObserver?
        let changed: AXObserverCallback = { _, _, _, me in  // on the main run loop, where the source is added
            MainActor.assumeIsolated { Unmanaged<Frost>.fromOpaque(me!).takeUnretainedValue().soon() }
        }
        guard AXObserverCreate(pid, changed, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid), me = Unmanaged.passUnretained(self).toOpaque()
        let added = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification].map {
            AXObserverAddNotification(observer, app, $0 as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        focusWatch = observer
        // An app that is still launching can't take observers yet: try again for a few seconds.
        watchTries = added.contains(.cannotComplete) ? watchTries + 1 : 0
        if (1...10).contains(watchTries) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { self?.watchFrontApp() }
            }
        }
    }

    @objc func appQuit() {
        bundleIDs.removeAll()  // pids get reused
        soon()
    }

    func tick() {
        guard s.enabled else { return }
        let wins = windowList()
        guard dirty || wins != lastWins else { return }  // nothing moved: skip the path math
        lastWins = wins
        dirty = false
        let excluded = Set(s.excluded), groups = s.groups, perScreen = s.perScreen
        for o in overlays {
            var (target, holes) = layout(o.bounds, wins, excluded: excluded, groups: groups, perScreen: perScreen)
            // In a full-screen Space (a full-screen app or Split View) the window server keeps the pane above the
            // app's windows, where it would frost the window you're using: stay out of those.
            if showsFullScreenSpace(o.display) { target = 0 }
            o.target = target
            o.above = wins.firstIndex { $0.id == target }.map { wins[...$0].map(\.rect) } ?? []
            if target == 0 { o.window.orderOut(nil) } else { o.window.order(.below, relativeTo: target) }
            if holes != o.holes {
                o.holes = holes
                let mask = CAShapeLayer()
                mask.path = CGPath(rect: o.content.bounds, transform: nil).subtracting(holes)
                o.content.mask = holes.isEmpty ? nil : mask
            }
        }
    }

    // Real windows of other apps, front to back.
    func windowList() -> [Win] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  info[kCGWindowAlpha as String] as? Double ?? 0 > 0,
                  let d = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: d), r.width > 50, r.height > 50,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let app = bundleID(pid)
            else { return nil }
            return Win(id: id, rect: r, app: app)
        }
    }

    // nil when the owner isn't an app, like the screencapture tool, which lays an invisible window over the
    // focused one while you pick what to capture; taking that as the top window frosted the window being captured.
    func bundleID(_ pid: pid_t) -> String? {
        if let id = bundleIDs[pid] { return id }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        bundleIDs[pid] = app.bundleIdentifier ?? ""
        return bundleIDs[pid]
    }

    func applyEnabled() {
        item.button?.image = menuIcon(on: s.enabled)
        syncDock()
        if s.enabled {
            dirty = true
            tick()
            fade(to: 1)
        } else {
            fade(to: 0) { [self] in if !s.enabled { overlays.forEach { $0.window.orderOut(nil) } } }
        }
    }

    func fade(to alpha: CGFloat, then done: (@MainActor @Sendable () -> Void)? = nil) {
        overlays.forEach { $0.soft = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            overlays.forEach { $0.window.animator().alphaValue = alpha }
        }, completionHandler: { MainActor.assumeIsolated { done?() } })
    }

    // Auto-hides the Dock while Frost is on and puts the user's own setting back when it's off.
    // The original is saved in prefs (a crash or kill can't lose it) and only read when the option is switched on,
    // so Frost on/off or a relaunch never mistakes our own hiding for the user's setting.
    func syncDock() {
        guard let dockAutoHide, let setDockAutoHide else { return }
        let prefs = s.prefs
        if s.hideDock, prefs.object(forKey: "dockWasHidden") == nil { prefs.set(dockAutoHide(), forKey: "dockWasHidden") }
        guard let was = prefs.object(forKey: "dockWasHidden") as? Bool else { return }
        let want = s.enabled && s.hideDock ? true : was
        if dockAutoHide() != want { setDockAutoHide(want) }
        if !s.hideDock { prefs.removeObject(forKey: "dockWasHidden") }
    }

    @objc func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: panel

struct Panel: View {
    @ObservedObject var s: Settings
    @State private var draft: Set<String>?  // apps picked for a new group, nil while not making one
    @State private var trusted = AXIsProcessTrusted()  // Accessibility, checked again each time the panel opens

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("모드", selection: $s.mode) { ForEach(modes, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
            Card {
                SliderRow(icon: "drop", title: "블러", value: $s.blur, max: 50)
                SliderRow(icon: "aqi.medium", title: "그레인", value: $s.grain, max: 0.2)
                SliderRow(icon: "circle.lefthalf.filled", title: "색 농도", value: $s.tint, max: 0.8)
                Divider()
                swatchRow
                HStack {
                    Text("모양").font(.system(size: 12)).frame(width: 74, alignment: .leading)
                    Picker("모양", selection: $s.shape) { ForEach(shapes, id: \.0) { Text($0.1).tag($0.0) } }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                }
            }
            Card {
                ToggleRow(title: "화면별 포커스", detail: "화면마다 맨 위 창을 선명하게", isOn: $s.perScreen)
                ToggleRow(title: "머물면 흐림 줄이기", detail: "바깥 영역에 잠깐(0.5초) 머물면 뒤 창이 비쳐 보여요", isOn: $s.softenOnRest)
                ToggleRow(title: "Dock 자동 숨기기", detail: "켜져 있는 동안만, 끄면 원래대로", isOn: $s.hideDock)
                if !trusted {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("손쉬운 사용 권한").font(.system(size: 12, weight: .medium))
                            Text("주면 키보드로 창을 바꿀 때 바로 따라가요").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("허용") { askAccessibility() }.controlSize(.small)
                    }
                }
            }
            Card { excludedSection }
            Card { groupsSection }
            HStack {
                Toggle("로그인 시 실행", isOn: $s.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 330)
        .tint(Color(nsColor: color(bdsSage)))
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Frost").font(.system(size: 14, weight: .semibold))
                Text(s.enabled ? "켜짐" : "꺼짐 · 오른쪽 버튼으로 켜요")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { s.enabled.toggle() } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(s.enabled ? Color.white : Color.secondary)
                    .background(Circle().fill(s.enabled ? Color(nsColor: color(bdsSage)) : Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(s.enabled ? "끄기" : "켜기")
        }
    }

    var swatchRow: some View {
        HStack(spacing: 7) {
            Text("색상").font(.system(size: 12)).frame(width: 74, alignment: .leading)
            ForEach(swatches, id: \.0) { hex, name in
                Button { s.color = hex } label: {
                    Circle()
                        .fill(Color(nsColor: color(hex)))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(s.color == hex ? 0.85 : 0.15), lineWidth: s.color == hex ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(name)
            }
            ColorPicker("자세히", selection: Binding(get: { Color(nsColor: color(s.color)) }, set: { s.color = hex($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .help("자세히 고르기")
        }
    }

    @ViewBuilder var excludedSection: some View {
        SectionHeader(title: "앱 제외", detail: "항상 선명하고, 포커스도 가져가지 않아요") {
            Menu {
                ForEach(runningApps().filter { !s.excluded.contains($0) }, id: \.self) { id in
                    Button { s.excluded.append(id) } label: { Label { Text(appName(id)) } icon: { Image(nsImage: appIcon(id, size: 16)) } }
                }
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("실행 중인 앱에서 추가")
        }
        ForEach(s.excluded, id: \.self) { id in
            AppRow(apps: [id]) { s.excluded.removeAll { $0 == id } }
        }
        if s.excluded.isEmpty { Text("없음").font(.system(size: 11)).foregroundStyle(.tertiary) }
    }

    @ViewBuilder var groupsSection: some View {
        SectionHeader(title: "앱 그룹", detail: "한 앱을 쓰는 동안 나머지 앱도 선명하게") {
            Button { draft = draft == nil ? [] : nil } label: { Image(systemName: draft == nil ? "plus" : "xmark") }
                .buttonStyle(.borderless)
                .help(draft == nil ? "새 그룹" : "취소")
        }
        ForEach(Array(s.groups.enumerated()), id: \.offset) { i, group in
            AppRow(apps: group) { s.groups.remove(at: i) }
        }
        if s.groups.isEmpty && draft == nil { Text("없음").font(.system(size: 11)).foregroundStyle(.tertiary) }
        if let picked = draft {
            VStack(alignment: .leading, spacing: 6) {
                Text("함께 쓸 앱을 2개 이상 고르세요").font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(runningApps(), id: \.self) { id in
                            Toggle(isOn: Binding(get: { picked.contains(id) },
                                                 set: { on in if on { draft?.insert(id) } else { draft?.remove(id) } })) {
                                HStack(spacing: 6) {
                                    Image(nsImage: appIcon(id, size: 16))
                                    Text(appName(id)).font(.system(size: 12))
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 170)
                Button("그룹 만들기") {
                    s.groups.append(picked.sorted { appName($0) < appName($1) })
                    draft = nil
                }
                .controlSize(.small)
                .disabled(picked.count < 2)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SliderRow: View {
    let icon: String
    let title: String
    @Binding var value: Double
    let max: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(title).frame(width: 50, alignment: .leading)
            Slider(value: $value, in: 0...max)
            Text("\(Int((value / max * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .font(.system(size: 12))
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

// One app, or a group of them, with a remove button.
struct AppRow: View {
    let apps: [String]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: -4) {
                ForEach(apps, id: \.self) { Image(nsImage: appIcon($0, size: 18)) }
            }
            Text(apps.map(appName).joined(separator: " + ")).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain)
                .help("빼기")
        }
    }
}

// MARK: helpers

// Whether a display shows a full-screen Space (a full-screen app or Split View) right now.
func showsFullScreenSpace(_ display: CGDirectDisplayID) -> Bool {
    guard let cgsConnection, let displaySpace, let spaceType,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let name = CFUUIDCreateString(nil, uuid) else { return false }
    let connection = cgsConnection()
    return spaceType(connection, displaySpace(connection, name)) == 4  // 0 is a desktop, 4 full screen
}

// Shows macOS's Accessibility prompt, which leads to System Settings.
func askAccessibility() {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
}

// Bundle ids of the apps with a Dock presence, by name.
func runningApps() -> [String] {
    let me = Bundle.main.bundleIdentifier
    let ids = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap(\.bundleIdentifier)
        .filter { $0 != me }
    return Array(Set(ids)).sorted { appName($0).localizedStandardCompare(appName($1)) == .orderedAscending }
}

// Name and icon for a bundle id, running or not.
func appName(_ id: String) -> String {
    if let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName { return name }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
    return url.deletingPathExtension().lastPathComponent
}

func appIcon(_ id: String, size: CGFloat) -> NSImage {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    let icon = (url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)).copy() as! NSImage
    icon.size = NSSize(width: size, height: size)
    return icon
}

// Menu bar glyph: a sharp window in a field of frost dots; just the window's outline when Frost is off.
func menuIcon(on: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let window = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5, width: 9, height: 8), xRadius: 2, yRadius: 2)
        NSColor.black.set()
        if on {
            for x in stride(from: 1.5, through: 16.5, by: 3.75) {
                for y in stride(from: 1.5, through: 16.5, by: 3.75) {
                    NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)).fill()
                }
            }
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 3, y: 3.5, width: 12, height: 11), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            window.fill()
        } else {
            window.lineWidth = 1.4
            window.stroke()
        }
        return true
    }
    image.isTemplate = true
    return image
}

func variableBlur(_ radius: Double, _ mask: CGImage) -> NSObject? {
    let make = NSSelectorFromString("filterWithType:")
    guard let type = NSClassFromString("CAFilter") as? NSObject.Type, type.responds(to: make),
          let filter = type.perform(make, with: "variableBlur")?.takeUnretainedValue() as? NSObject
    else { return nil }
    filter.setValue(radius, forKey: "inputRadius")
    filter.setValue(mask, forKey: "inputMaskImage")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    return filter
}

// Blur strength map (alpha = share of the radius), drawn with CG's bottom-left origin and stretched to the pane.
func shapeMask(_ shape: String) -> CGImage {
    let rgb = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let soft = CGColor(red: 0, green: 0, blue: 0, alpha: 0.15), full = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient { CGGradient(colorsSpace: rgb, colors: [a, b] as CFArray, locations: nil)! }
    let mid = CGPoint(x: 64, y: 64)
    switch shape {
    case "bottom": ctx.drawLinearGradient(gradient(full, soft), start: .zero, end: CGPoint(x: 0, y: 128), options: [])
    case "top": ctx.drawLinearGradient(gradient(soft, full), start: .zero, end: CGPoint(x: 0, y: 128), options: [])
    case "edges": ctx.drawRadialGradient(gradient(soft, full), startCenter: mid, startRadius: 0, endCenter: mid, endRadius: 91, options: [])
    default: ctx.setFillColor(full); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    }
    return ctx.makeImage()!
}

func color(_ hex: String) -> NSColor {
    let v = Int(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func hex(_ c: Color) -> String {
    guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return "141210" }
    return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
}

// Gray static, one byte per point.
func noise(_ size: CGSize) -> CGImage {
    let w = Int(size.width), h = Int(size.height)
    let px = Data((0..<w * h).map { _ in UInt8.random(in: 0...255) })
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: CGDataProvider(data: px as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

// MARK: self-check

if CommandLine.arguments.contains("--selftest") {
    var rest = Linger(after: 0.5)
    precondition(!rest.update(true, at: 0) && !rest.update(true, at: 0.25) && rest.update(true, at: 0.5), "resting 0.5s softens")
    precondition(!rest.update(false, at: 0.75), "moving onto a sharp window restores at once")
    precondition(!rest.update(true, at: 1) && !rest.update(true, at: 1.25) && rest.update(true, at: 1.5), "and the 0.5s starts over")

    // One 1000x800 screen, windows front to back: a over b; c and c2 (same app) further down; b overlaps c's corner.
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let a = Win(id: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 300), app: "a")
    let b = Win(id: 2, rect: CGRect(x: 300, y: 200, width: 400, height: 300), app: "b")
    let c = Win(id: 3, rect: CGRect(x: 600, y: 400, width: 300, height: 300), app: "c")
    let c2 = Win(id: 4, rect: CGRect(x: 50, y: 500, width: 200, height: 200), app: "c")
    let wins = [a, b, c, c2]
    func run(excluded: Set<String> = [], groups: [[String]] = [], perScreen: Bool = false, on bounds: CGRect = screen) -> (Int, CGPath) {
        layout(bounds, wins, excluded: excluded, groups: groups, perScreen: perScreen)
    }
    func sharp(_ holes: CGPath, _ x: CGFloat, _ y: CGFloat) -> Bool { holes.contains(CGPoint(x: x, y: screen.maxY - y)) }

    let plain = run()
    precondition(plain.0 == 1 && plain.1.isEmpty, "focus goes to the top window, nothing else stays sharp")

    precondition(run(excluded: ["a"]).0 == 2, "an excluded app never takes focus")

    let ex = run(excluded: ["c"]).1
    precondition(sharp(ex, 800, 600) && sharp(ex, 100, 600), "every window of an excluded app stays sharp")
    precondition(!sharp(ex, 650, 450), "except where another window covers it")
    precondition(!sharp(ex, 400, 300), "windows of other apps stay frosted")

    let grouped = run(groups: [["a", "c"]]).1
    precondition(sharp(grouped, 800, 600), "a grouped app's topmost window stays sharp")
    precondition(!sharp(grouped, 100, 600), "its other windows don't")
    precondition(!sharp(grouped, 650, 450), "nor the part another window covers")
    precondition(run(groups: [["b", "c"]]).1.isEmpty, "groups without the focused app do nothing")

    let right = CGRect(x: 1000, y: 0, width: 800, height: 800)
    let d = Win(id: 5, rect: CGRect(x: 1100, y: 100, width: 300, height: 300), app: "d")
    precondition(layout(right, wins + [d], excluded: [], groups: [], perScreen: true).0 == 5, "per screen: each screen focuses its own top window")
    precondition(layout(right, wins + [d], excluded: [], groups: [], perScreen: false).0 == 1, "global: every screen follows the one top window")
    precondition(layout(right, wins, excluded: [], groups: [], perScreen: true).0 == 0, "a screen with no windows has nothing to focus")
    let full = Win(id: 6, rect: right, app: "e")
    precondition(layout(right, [full] + wins + [d], excluded: [], groups: [], perScreen: true).0 == 0, "a full-screen window hides its screen's pane")
    precondition(layout(screen, [full] + wins, excluded: [], groups: [], perScreen: false).0 == 6, "but not the other screens' panes")

    print("selftest ok")
    exit(0)
}

let delegate = MainActor.assumeIsolated { Frost() }  // top-level code runs on the main thread
NSApplication.shared.delegate = delegate
NSApplication.shared.run()

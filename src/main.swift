// Swyp — turn your trackpad edges into volume & brightness sliders, with a
// menu-bar control panel, quick-mute corner, media skip, and haptic feedback.
//
// Independent open-source reimplementation inspired by EdgeBar (edgebar.xyz).
//
// Gestures:
//   * Right edge  — slide up/down  -> Volume
//   * Left edge   — slide up/down  -> Brightness (built-in display)
//   * Bottom edge — swipe sideways -> Skip track (Media Strip)
//   * Top-right corner — double-tap -> Quick Mute
//   * Edge tap    — Play / Pause (optional)
//
// Engine uses private frameworks via dlopen (MultitouchSupport, DisplayServices,
// MediaRemote) plus public CoreAudio and AppKit.

import AppKit
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - MultitouchSupport interop ----------------------------------------

struct MTPoint { var x: Float = 0; var y: Float = 0 }
struct MTVector { var position = MTPoint(); var velocity = MTPoint() }
struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var pathIndex: Int32 = 0
    var state: Int32 = 0
    var fingerID: Int32 = 0
    var handID: Int32 = 0
    var normalized = MTVector()
    var zTotal: Float = 0
    var unknown2: Int32 = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absolute = MTVector()
    var unknown3: Int32 = 0
    var unknown4: Int32 = 0
    var zDensity: Float = 0
}

typealias MTContactCallback = @convention(c)
    (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias MTDeviceCreateDefaultFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void

final class Multitouch {
    private var device: UnsafeMutableRawPointer?
    private var start: MTStartFn?
    static let shared = Multitouch()
    func begin() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return false }
        guard let cDef = dlsym(h, "MTDeviceCreateDefault"),
              let cReg = dlsym(h, "MTRegisterContactFrameCallback"),
              let cStart = dlsym(h, "MTDeviceStart") else { return false }
        let create = unsafeBitCast(cDef, to: MTDeviceCreateDefaultFn.self)
        let register = unsafeBitCast(cReg, to: MTRegisterFn.self)
        start = unsafeBitCast(cStart, to: MTStartFn.self)
        device = create()
        guard device != nil else { return false }
        register(device, edgeCallback)
        start?(device, 0)
        return true
    }
}

private func edgeCallback(_ dev: Int32, _ raw: UnsafeMutableRawPointer?,
                          _ n: Int32, _ ts: Double, _ frame: Int32) -> Int32 {
    guard let raw = raw, n > 0 else {
        DispatchQueue.main.async { Engine.shared.fingersLifted() }
        return 0
    }
    let data = raw.assumingMemoryBound(to: MTTouch.self)
    var best = data[0]
    for i in 1..<Int(n) where data[i].zTotal > best.zTotal { best = data[i] }
    let p = best.normalized.position
    DispatchQueue.main.async { Engine.shared.finger(x: p.x, y: p.y) }
    return 0
}

// MARK: - Brightness --------------------------------------------------------

typealias DSSetFn = @convention(c) (UInt32, Float) -> Int32
typealias DSGetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
final class Brightness {
    private var setFn: DSSetFn?; private var getFn: DSGetFn?
    private let display = CGMainDisplayID()
    static let shared = Brightness()
    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: DSSetFn.self) }
            if let g = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(g, to: DSGetFn.self) }
        }
    }
    var available: Bool { setFn != nil && getFn != nil }
    func get() -> Float { var v: Float = 0; _ = getFn?(display, &v); return v }
    func set(_ v: Float) { _ = setFn?(display, max(0, min(1, v))) }
}

// MARK: - Volume ------------------------------------------------------------

final class Volume {
    static let shared = Volume()
    private func device() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    private func addr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    func get() -> Float { var v: Float32 = 0; var s = UInt32(MemoryLayout<Float32>.size); var a = addr(); AudioObjectGetPropertyData(device(), &a, 0, nil, &s, &v); return v }
    func set(_ v: Float) { var val = Float32(max(0, min(1, v))); let s = UInt32(MemoryLayout<Float32>.size); var a = addr(); AudioObjectSetPropertyData(device(), &a, 0, nil, s, &val) }
}

// MARK: - Music (MediaRemote) ----------------------------------------------

typealias MRSendFn = @convention(c) (Int32, CFDictionary?) -> Bool
final class Music {
    private var send: MRSendFn?
    static let shared = Music()
    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let s = dlsym(h, "MRMediaRemoteSendCommand") { send = unsafeBitCast(s, to: MRSendFn.self) }
    }
    var available: Bool { send != nil }
    func togglePlayPause() { _ = send?(2, nil) }   // kMRTogglePlayPause
    func next() { _ = send?(4, nil) }              // kMRNextTrack
    func previous() { _ = send?(5, nil) }          // kMRPreviousTrack
}

// MARK: - Haptics -----------------------------------------------------------

enum HapticStrength: Int, CaseIterable { case off = 0, light, medium, strong
    var label: String { ["Off","Light","Medium","Strong"][rawValue] }
}
enum Haptic {
    static func tick() {
        let p: NSHapticFeedbackManager.FeedbackPattern
        switch Settings.shared.haptic {
        case .off: return
        case .light: p = .generic
        case .medium: p = .alignment
        case .strong: p = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
    }
}

// MARK: - Settings ----------------------------------------------------------

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    init() {
        d.register(defaults: ["haptic": HapticStrength.strong.rawValue, "quickMute": true,
                              "mediaStrip": true, "tapPlayPause": false,
                              "sensitivity": 1.5, "edgeWidth": 0.06, "enabled": true])
    }
    var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    var haptic: HapticStrength { get { HapticStrength(rawValue: d.integer(forKey: "haptic")) ?? .strong } set { d.set(newValue.rawValue, forKey: "haptic") } }
    var quickMute: Bool { get { d.bool(forKey: "quickMute") } set { d.set(newValue, forKey: "quickMute") } }
    var mediaStrip: Bool { get { d.bool(forKey: "mediaStrip") } set { d.set(newValue, forKey: "mediaStrip") } }
    var tapPlayPause: Bool { get { d.bool(forKey: "tapPlayPause") } set { d.set(newValue, forKey: "tapPlayPause") } }
    var sensitivity: Double { get { d.double(forKey: "sensitivity") } set { d.set(newValue, forKey: "sensitivity") } }
    var edgeWidth: Double { get { d.double(forKey: "edgeWidth") } set { d.set(newValue, forKey: "edgeWidth") } }
}

// MARK: - HUD ---------------------------------------------------------------

final class HUD {
    private var window: NSWindow?
    private let bar = NSView(); private let fill = NSView()
    private let icon = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    static let shared = HUD()
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 240),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar; w.isOpaque = false; w.backgroundColor = .clear
        w.ignoresMouseEvents = true; w.hasShadow = true
        let root = NSView(frame: w.contentView!.bounds); root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        root.layer?.cornerRadius = 18
        bar.frame = NSRect(x: 26, y: 46, width: 12, height: 150); bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1).cgColor; bar.layer?.cornerRadius = 6
        fill.wantsLayer = true; fill.layer?.backgroundColor = NSColor.white.cgColor; fill.layer?.cornerRadius = 6
        bar.addSubview(fill)
        icon.frame = NSRect(x: 0, y: 200, width: 64, height: 28); icon.alignment = .center
        icon.font = .systemFont(ofSize: 20); icon.textColor = .white; icon.backgroundColor = .clear; icon.isBordered = false
        root.addSubview(bar); root.addSubview(icon); w.contentView?.addSubview(root); window = w
    }
    func show(symbol: String, value: Float, onLeft: Bool) {
        if window == nil { build() }
        guard let w = window, let screen = NSScreen.main else { return }
        icon.stringValue = symbol
        fill.frame = NSRect(x: 0, y: 0, width: 12, height: max(2, CGFloat(value) * 150))
        let f = screen.frame
        w.setFrameOrigin(NSPoint(x: onLeft ? f.minX + 24 : f.maxX - 88, y: f.midY - 120))
        w.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { w.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

// MARK: - Engine ------------------------------------------------------------

final class Engine {
    static let shared = Engine()
    private var tracking: Character = " "      // V, B, M (media), or space
    private var anchorX: Float = 0; private var anchorY: Float = 0; private var anchorValue: Float = 0
    private var lastStep = -1
    private var touchStart = Date.distantPast
    private var startX: Float = 0; private var startY: Float = 0
    private var moved = false
    private var firedMediaSkip = false
    // mute state
    private(set) var muted = false
    private var preMuteVolume: Float = 0.5
    // double-tap corner
    private var lastCornerTap = Date.distantPast

    private var edge: Float { Float(Settings.shared.edgeWidth) }
    private var sens: Float { Float(Settings.shared.sensitivity) }

    func finger(x: Float, y: Float) {
        guard Settings.shared.enabled else { return }
        if tracking == " " {
            startX = x; startY = y; anchorX = x; anchorY = y
            touchStart = Date(); moved = false; firedMediaSkip = false
            let onRight = x > (1 - edge), onLeft = x < edge, onBottom = y < edge
            // top-right corner is reserved for quick-mute taps, not volume drags
            let topRightCorner = x > 0.9 && y > 0.9
            if topRightCorner { tracking = "C" }
            else if onRight { tracking = "V"; anchorValue = Volume.shared.get() }
            else if onLeft { tracking = "B"; anchorValue = Brightness.shared.get() }
            else if onBottom && Settings.shared.mediaStrip { tracking = "M" }
            else { tracking = "-" }   // started in the dead zone; ignore until lift
            return
        }
        let dx = x - anchorX, dy = y - anchorY
        if abs(x - startX) > 0.01 || abs(y - startY) > 0.01 { moved = true }

        switch tracking {
        case "V":
            let v = max(0, min(1, anchorValue + dy * sens)); Volume.shared.set(v)
            if v > 0.001 { muted = false }
            HUD.shared.show(symbol: v < 0.01 ? "🔇" : "🔊", value: v, onLeft: false)
            step(v)
        case "B":
            let v = max(0, min(1, anchorValue + dy * sens)); Brightness.shared.set(v)
            HUD.shared.show(symbol: "☀", value: v, onLeft: true)
            step(v)
        case "M":
            if !firedMediaSkip && abs(dx) > 0.22 {
                if dx > 0 { Music.shared.next(); HUD.shared.show(symbol: "⏭", value: 0.5, onLeft: false) }
                else { Music.shared.previous(); HUD.shared.show(symbol: "⏮", value: 0.5, onLeft: true) }
                Haptic.tick(); firedMediaSkip = true
            }
        default: break
        }
    }

    private func step(_ v: Float) {
        let s = Int((v * 16).rounded())
        if s != lastStep { Haptic.tick(); lastStep = s }
    }

    func fingersLifted() {
        let quick = Date().timeIntervalSince(touchStart) < 0.25 && !moved
        if tracking == "C" && quick && Settings.shared.quickMute {
            // double-tap top-right corner -> toggle mute
            if Date().timeIntervalSince(lastCornerTap) < 0.45 {
                toggleMute(); lastCornerTap = .distantPast
            } else { lastCornerTap = Date() }
        } else if (tracking == "V" || tracking == "B") && quick && Settings.shared.tapPlayPause {
            Music.shared.togglePlayPause()
            HUD.shared.show(symbol: "⏯", value: 0.5, onLeft: tracking == "B")
            Haptic.tick()
        }
        tracking = " "; lastStep = -1
    }

    func toggleMute() {
        if muted { Volume.shared.set(preMuteVolume); muted = false }
        else { preMuteVolume = max(0.05, Volume.shared.get()); Volume.shared.set(0); muted = true }
        HUD.shared.show(symbol: muted ? "🔇" : "🔊", value: muted ? 0 : preMuteVolume, onLeft: false)
        Haptic.tick()
    }
}

// MARK: - Control panel (menu-bar popover) ----------------------------------

final class Meter: NSView {
    private let bBar = NSView(); private let bFill = NSView()
    private let vBar = NSView(); private let vFill = NSView()
    private let bLabel = NSTextField(labelWithString: "0%")
    private let vLabel = NSTextField(labelWithString: "0%")
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.12).cgColor; layer?.cornerRadius = 14
        func barPair(_ x: CGFloat, _ color: NSColor) -> (NSView, NSView) {
            let track = NSView(frame: NSRect(x: x, y: 16, width: 10, height: 120)); track.wantsLayer = true
            track.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.25).cgColor; track.layer?.cornerRadius = 5
            let fill = NSView(); fill.wantsLayer = true; fill.layer?.backgroundColor = color.cgColor; fill.layer?.cornerRadius = 5
            track.addSubview(fill); addSubview(track); return (track, fill)
        }
        let (bt, bf) = barPair(18, .systemOrange); bBar.frame = bt.frame
        let (vt, vf) = barPair(bounds.width - 28, .systemBlue); vBar.frame = vt.frame
        _ = bt; _ = vt
        bFillRef = bf; vFillRef = vf
        let bTitle = NSTextField(labelWithString: "☀ BRIGHTNESS"); style(bTitle, 10, .secondaryLabelColor); bTitle.frame = NSRect(x: 36, y: 118, width: 150, height: 14)
        let vTitle = NSTextField(labelWithString: "VOLUME 🔊"); style(vTitle, 10, .secondaryLabelColor); vTitle.alignment = .right; vTitle.frame = NSRect(x: bounds.width - 186, y: 118, width: 150, height: 14)
        style(bLabel, 30, .labelColor); bLabel.frame = NSRect(x: 36, y: 60, width: 120, height: 36)
        style(vLabel, 30, .labelColor); vLabel.alignment = .right; vLabel.frame = NSRect(x: bounds.width - 156, y: 60, width: 120, height: 36)
        addSubview(bTitle); addSubview(vTitle); addSubview(bLabel); addSubview(vLabel)
    }
    required init?(coder: NSCoder) { nil }
    private var bFillRef: NSView?; private var vFillRef: NSView?
    private func style(_ t: NSTextField, _ sz: CGFloat, _ c: NSColor) {
        t.font = .systemFont(ofSize: sz, weight: .semibold); t.textColor = c; t.backgroundColor = .clear; t.isBordered = false
    }
    func update() {
        let b = Brightness.shared.available ? Brightness.shared.get() : 0
        let v = Volume.shared.get()
        bLabel.stringValue = "\(Int((b*100).rounded()))%"
        vLabel.stringValue = Engine.shared.muted ? "Muted" : "\(Int((v*100).rounded()))%"
        bFillRef?.frame = NSRect(x: 0, y: 0, width: 10, height: max(2, CGFloat(b)*120))
        vFillRef?.frame = NSRect(x: 0, y: 0, width: 10, height: max(2, CGFloat(v)*120))
    }
}

final class PanelController: NSViewController {
    private let meter = Meter(frame: NSRect(x: 16, y: 300, width: 328, height: 150))
    private var timer: Timer?
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 470)); v.wantsLayer = true
        // header
        let title = NSTextField(labelWithString: "Swyp"); title.font = .boldSystemFont(ofSize: 18)
        title.textColor = .labelColor; title.backgroundColor = .clear; title.isBordered = false
        title.frame = NSRect(x: 18, y: 436, width: 120, height: 24)
        let ready = NSTextField(labelWithString: "● Ready"); ready.font = .systemFont(ofSize: 12)
        ready.textColor = .systemGreen; ready.alignment = .right; ready.backgroundColor = .clear; ready.isBordered = false
        ready.frame = NSRect(x: 220, y: 438, width: 122, height: 18)
        v.addSubview(title); v.addSubview(ready); v.addSubview(meter)

        var y = 262
        func row(_ icon: String, _ name: String, _ sub: String, _ control: NSView) -> NSView {
            let r = NSView(frame: NSRect(x: 16, y: y, width: 328, height: 44))
            let i = NSTextField(labelWithString: icon); i.font = .systemFont(ofSize: 18); i.backgroundColor = .clear; i.isBordered = false
            i.frame = NSRect(x: 0, y: 8, width: 28, height: 28)
            let n = NSTextField(labelWithString: name); n.font = .boldSystemFont(ofSize: 14); n.textColor = .labelColor; n.backgroundColor = .clear; n.isBordered = false
            n.frame = NSRect(x: 34, y: 22, width: 220, height: 18)
            let s = NSTextField(labelWithString: sub); s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor; s.backgroundColor = .clear; s.isBordered = false
            s.frame = NSRect(x: 34, y: 4, width: 240, height: 16)
            r.addSubview(i); r.addSubview(n); r.addSubview(s); r.addSubview(control)
            v.addSubview(r); y -= 50; return r
        }
        // Haptic strength popup
        let hpop = NSPopUpButton(frame: NSRect(x: 230, y: 8, width: 96, height: 26))
        hpop.addItems(withTitles: HapticStrength.allCases.map { $0.label })
        hpop.selectItem(at: Settings.shared.haptic.rawValue)
        hpop.target = self; hpop.action = #selector(hapticChanged(_:))
        _ = row("👆", "Haptic Feedback", "Clicks as you slide", hpop)
        // Quick Mute toggle
        _ = row("🔇", "Quick Mute", "Double-tap the top-right corner", makeToggle(Settings.shared.quickMute, #selector(muteToggled(_:))))
        // Media Strip toggle
        _ = row("⏩", "Media Strip", "Swipe the bottom edge to skip songs", makeToggle(Settings.shared.mediaStrip, #selector(mediaToggled(_:))))
        // Tap play/pause toggle
        _ = row("⏯", "Tap to Play or Pause", "Clicks near the edge can set it off", makeToggle(Settings.shared.tapPlayPause, #selector(tapToggled(_:))))

        // Sensitivity slider
        let sens = NSSlider(value: Settings.shared.sensitivity, minValue: 0.5, maxValue: 3.0, target: self, action: #selector(sensChanged(_:)))
        sens.frame = NSRect(x: 16, y: 44, width: 328, height: 20)
        let sensT = NSTextField(labelWithString: "Sensitivity"); sensT.font = .boldSystemFont(ofSize: 13); sensT.textColor = .labelColor; sensT.backgroundColor = .clear; sensT.isBordered = false
        sensT.frame = NSRect(x: 16, y: 66, width: 200, height: 16)
        sensValue.frame = NSRect(x: 244, y: 66, width: 100, height: 16); sensValue.alignment = .right
        sensValue.font = .boldSystemFont(ofSize: 13); sensValue.textColor = .labelColor; sensValue.backgroundColor = .clear; sensValue.isBordered = false
        v.addSubview(sensT); v.addSubview(sens); v.addSubview(sensValue)
        // quit
        let quit = NSButton(title: "Quit Swyp", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.frame = NSRect(x: 16, y: 10, width: 100, height: 26); quit.bezelStyle = .rounded
        v.addSubview(quit)
        updateSensLabel()
        self.view = v
    }
    private let sensValue = NSTextField(labelWithString: "")
    private func updateSensLabel() { sensValue.stringValue = String(format: "%.2fx  ·  edge \(Int(Settings.shared.edgeWidth*100))%%", Settings.shared.sensitivity) }
    private func makeToggle(_ on: Bool, _ action: Selector) -> NSSwitch {
        let s = NSSwitch(frame: NSRect(x: 288, y: 8, width: 40, height: 26))
        s.state = on ? .on : .off; s.target = self; s.action = action; return s
    }
    @objc private func hapticChanged(_ s: NSPopUpButton) { Settings.shared.haptic = HapticStrength(rawValue: s.indexOfSelectedItem) ?? .strong; Haptic.tick() }
    @objc private func muteToggled(_ s: NSSwitch) { Settings.shared.quickMute = (s.state == .on) }
    @objc private func mediaToggled(_ s: NSSwitch) { Settings.shared.mediaStrip = (s.state == .on) }
    @objc private func tapToggled(_ s: NSSwitch) { Settings.shared.tapPlayPause = (s.state == .on) }
    @objc private func sensChanged(_ s: NSSlider) { Settings.shared.sensitivity = s.doubleValue; updateSensLabel() }
    func startLive() { timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.meter.update() }; meter.update() }
    func stopLive() { timer?.invalidate(); timer = nil }
}

// MARK: - App ---------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let panel = PanelController()
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▐"; statusItem.button?.toolTip = "Swyp"
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover(_:))
        popover.contentViewController = panel
        popover.behavior = .transient
        if !Multitouch.shared.begin() { statusItem.button?.title = "▐!" }
    }
    @objc func togglePopover(_ sender: Any?) {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(sender); panel.stopLive() }
        else { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY); panel.startLive(); NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Self-test ---------------------------------------------------------

func selfTest() -> Int32 {
    func line(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    var ok = true
    line("Swyp self-test")
    let v0 = Volume.shared.get(); Volume.shared.set(0.3); usleep(120_000); let vMid = Volume.shared.get(); Volume.shared.set(v0)
    let volOK = abs(vMid - 0.3) < 0.12; ok = ok && volOK
    line("  volume    : set0.3->\(String(format:"%.2f",vMid)) \(volOK ? "OK":"FAIL")")
    if Brightness.shared.available {
        let b0 = Brightness.shared.get(); Brightness.shared.set(max(0,b0-0.15)); usleep(150_000); let bMid = Brightness.shared.get(); Brightness.shared.set(b0)
        let brOK = abs(bMid - max(0,b0-0.15)) < 0.15; ok = ok && brOK
        line("  brightness: stepped->\(String(format:"%.2f",bMid)) \(brOK ? "OK":"FAIL")")
    } else { line("  brightness: UNAVAILABLE"); ok = false }
    line("  music     : MediaRemote \(Music.shared.available ? "(play/next/prev) OK":"FAIL")"); ok = ok && Music.shared.available
    // quick mute logic
    let vb = Volume.shared.get(); Engine.shared.toggleMute(); usleep(80_000); let vm = Volume.shared.get(); Engine.shared.toggleMute(); usleep(80_000); let vr = Volume.shared.get()
    let muteOK = vm < 0.02 && abs(vr - vb) < 0.1; ok = ok && muteOK
    line("  quick mute: \(String(format:"%.2f",vb))->mute \(String(format:"%.2f",vm))->restore \(String(format:"%.2f",vr)) \(muteOK ? "OK":"FAIL")")
    let mt = Multitouch.shared.begin(); ok = ok && mt
    line("  trackpad  : \(mt ? "device started OK":"FAIL")")
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    _ = PanelController().view
    line("  panel     : control panel built OK")
    HUD.shared.show(symbol: "🔊", value: 0.7, onLeft: false); line("  hud       : rendered OK")
    Haptic.tick(); line("  haptic    : fired OK")
    line(ok ? "RESULT: PASS" : "RESULT: PARTIAL")
    return ok ? 0 : 2
}

// MARK: - Entry -------------------------------------------------------------

if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i+1 < CommandLine.arguments.count {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
    let pc = PanelController(); let v = pc.view; pc.startLive()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i+1]))
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

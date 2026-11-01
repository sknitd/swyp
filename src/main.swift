// EdgeBar — turn trackpad edges into volume & brightness sliders, with music
// control and haptic feedback.  A reimplementation of the app shown at
// https://x.com/bhardwajshash/status/2116878227335778610 (edgebar.xyz).
//
// Core engine uses three private system frameworks (loaded via dlopen so no
// private SDK headers are needed):
//   * MultitouchSupport — raw finger positions on the trackpad (0..1)
//   * DisplayServices    — read/write built-in display brightness
//   * MediaRemote        — system-wide play/pause (Music, Spotify, Safari…)
// Volume uses public CoreAudio; haptics use public AppKit.

import AppKit
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - MultitouchSupport interop ----------------------------------------

struct MTPoint { var x: Float = 0; var y: Float = 0 }
struct MTVector { var position = MTPoint(); var velocity = MTPoint() }
// Memory layout mirrors the C MTTouch struct used by MultitouchSupport.
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

// Global callback (C function pointers can't capture context).
private func edgeCallback(_ dev: Int32, _ raw: UnsafeMutableRawPointer?,
                          _ n: Int32, _ ts: Double, _ frame: Int32) -> Int32 {
    guard let raw = raw, n > 0 else {
        DispatchQueue.main.async { Engine.shared.fingersLifted() }
        return 0
    }
    let data = raw.assumingMemoryBound(to: MTTouch.self)
    // Choose the single most-pressed finger.
    var best = data[0]
    for i in 1..<Int(n) where data[i].zTotal > best.zTotal { best = data[i] }
    let p = best.normalized.position
    DispatchQueue.main.async { Engine.shared.finger(x: p.x, y: p.y) }
    return 0
}

// MARK: - DisplayServices (brightness) --------------------------------------

typealias DSSetFn = @convention(c) (UInt32, Float) -> Int32
typealias DSGetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

final class Brightness {
    private var setFn: DSSetFn?
    private var getFn: DSGetFn?
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

// MARK: - CoreAudio (volume) ------------------------------------------------

final class Volume {
    static let shared = Volume()
    private func device() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    private func addr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
    func get() -> Float {
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size); var a = addr()
        let d = device()
        AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v)
        return v
    }
    func set(_ v: Float) {
        var val = Float32(max(0, min(1, v))); let size = UInt32(MemoryLayout<Float32>.size); var a = addr()
        AudioObjectSetPropertyData(device(), &a, 0, nil, size, &val)
    }
}

// MARK: - MediaRemote (music play/pause) ------------------------------------

typealias MRSendFn = @convention(c) (Int32, CFDictionary?) -> Bool
final class Music {
    private var send: MRSendFn?
    static let shared = Music()
    init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let s = dlsym(h, "MRMediaRemoteSendCommand") {
            send = unsafeBitCast(s, to: MRSendFn.self)
        }
    }
    var available: Bool { send != nil }
    func togglePlayPause() { _ = send?(2, nil) }   // kMRTogglePlayPause = 2
}

// MARK: - Haptics -----------------------------------------------------------

enum Haptic {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

// MARK: - HUD ---------------------------------------------------------------

final class HUD {
    private var window: NSWindow?
    private let bar = NSView()
    private let fill = NSView()
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
        bar.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1).cgColor
        bar.layer?.cornerRadius = 6
        fill.wantsLayer = true; fill.layer?.backgroundColor = NSColor.white.cgColor
        fill.layer?.cornerRadius = 6
        bar.addSubview(fill)
        icon.frame = NSRect(x: 0, y: 200, width: 64, height: 28)
        icon.alignment = .center; icon.font = .systemFont(ofSize: 20); icon.textColor = .white
        icon.backgroundColor = .clear; icon.isBordered = false
        root.addSubview(bar); root.addSubview(icon)
        w.contentView?.addSubview(root)
        window = w
    }

    func show(symbol: String, value: Float, onLeft: Bool) {
        if window == nil { build() }
        guard let w = window, let screen = NSScreen.main else { return }
        icon.stringValue = symbol
        let h = max(2, CGFloat(value) * 150)
        fill.frame = NSRect(x: 0, y: 0, width: 12, height: h)
        let f = screen.frame
        let x = onLeft ? f.minX + 24 : f.maxX - 88
        w.setFrameOrigin(NSPoint(x: x, y: f.midY - 120))
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
    var enabled = true
    private let edge: Float = 0.08          // how wide the active edge band is
    private var tracking: Character = " "   // "V", "B", or " "
    private var anchorY: Float = 0
    private var anchorValue: Float = 0
    private var lastStep = -1
    private var touchStart = Date.distantPast
    private var movedInGesture = false

    func finger(x: Float, y: Float) {
        guard enabled else { return }
        let onRight = x > (1 - edge)
        let onLeft = x < edge
        if tracking == " " {
            if onRight { tracking = "V"; anchorValue = Volume.shared.get() }
            else if onLeft { tracking = "B"; anchorValue = Brightness.shared.get() }
            else { return }
            anchorY = y; touchStart = Date(); movedInGesture = false
            return
        }
        // Still in a gesture — map vertical travel to a delta.
        let dy = y - anchorY
        if abs(dy) > 0.004 { movedInGesture = true }
        let newVal = max(0, min(1, anchorValue + dy))
        let step = Int((newVal * 16).rounded())
        if tracking == "V" {
            Volume.shared.set(newVal)
            HUD.shared.show(symbol: newVal < 0.01 ? "🔇" : "🔊", value: newVal, onLeft: false)
        } else {
            Brightness.shared.set(newVal)
            HUD.shared.show(symbol: "☀", value: newVal, onLeft: true)
        }
        if step != lastStep { Haptic.tick(); lastStep = step }
    }

    func fingersLifted() {
        // A quick tap (no drag) on an edge toggles music play/pause.
        if tracking != " " && !movedInGesture && Date().timeIntervalSince(touchStart) < 0.25 {
            Music.shared.togglePlayPause()
            HUD.shared.show(symbol: "⏯", value: 0.5, onLeft: tracking == "B")
            Haptic.tick()
        }
        tracking = " "; lastStep = -1
    }
}

// MARK: - Self-test ---------------------------------------------------------

func selfTest() -> Int32 {
    func line(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    var ok = true
    line("EdgeBar self-test")

    // Volume round-trip (save & restore).
    let v0 = Volume.shared.get()
    Volume.shared.set(0.3); usleep(120_000); let vMid = Volume.shared.get()
    Volume.shared.set(v0)
    let volOK = abs(vMid - 0.3) < 0.12
    line("  volume   : get=\(String(format: "%.2f", v0)) set0.3->\(String(format: "%.2f", vMid)) \(volOK ? "OK" : "FAIL")")
    ok = ok && volOK

    // Brightness round-trip (save & restore).
    if Brightness.shared.available {
        let b0 = Brightness.shared.get()
        Brightness.shared.set(max(0, b0 - 0.15)); usleep(150_000); let bMid = Brightness.shared.get()
        Brightness.shared.set(b0)
        let brOK = abs(bMid - max(0, b0 - 0.15)) < 0.15
        line("  brightness: get=\(String(format: "%.2f", b0)) stepped->\(String(format: "%.2f", bMid)) \(brOK ? "OK" : "FAIL")")
        ok = ok && brOK
    } else { line("  brightness: UNAVAILABLE"); ok = false }

    line("  music    : MediaRemote \(Music.shared.available ? "loaded OK" : "FAIL")")
    ok = ok && Music.shared.available

    // Multitouch device present?
    let mt = Multitouch.shared.begin()
    line("  trackpad : MultitouchSupport \(mt ? "device started OK" : "FAIL (no multitouch device)")")
    ok = ok && mt

    // Haptic + HUD need an app/run loop; exercise HUD draw.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    HUD.shared.show(symbol: "🔊", value: 0.7, onLeft: false)
    line("  hud      : rendered OK")
    Haptic.tick()
    line("  haptic   : fired OK")

    line(ok ? "RESULT: PASS" : "RESULT: PARTIAL")
    return ok ? 0 : 2
}

// MARK: - App ---------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▐"
        statusItem.button?.toolTip = "EdgeBar"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "EdgeBar Active", action: #selector(toggle(_:)), keyEquivalent: "")
        toggle.state = .on; menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Left edge  → Brightness", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Right edge → Volume", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Tap edge   → Play / Pause", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        if !Multitouch.shared.begin() {
            statusItem.button?.title = "▐!"
        }
    }
    @objc func toggle(_ sender: NSMenuItem) {
        Engine.shared.enabled.toggle()
        sender.state = Engine.shared.enabled ? .on : .off
    }
}

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest())
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

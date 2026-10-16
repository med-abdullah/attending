import AppKit
import IOKit.ps
import ApplicationServices
import SwiftUI

/// A transient indicator shown in the collapsed wings (volume, brightness, charging).
struct HUDState: Equatable {
    enum Kind: Equatable { case volume, brightness, battery, headphones }
    var kind: Kind
    var value: Double
    var symbol: String
    var tint: Color
    var label: String?
}

// MARK: - Battery

/// Battery state from IOKit power-source notifications (no polling).
@MainActor final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Int?
    @Published private(set) var charging = false
    @Published private(set) var onAC = false
    var onChange: ((_ pluggedIn: Bool, _ low: Int?) -> Void)?
    private var source: CFRunLoopSource?
    private var lowWarned: Set<Int> = []

    var symbol: String {
        guard let level else { return "powerplug" }
        if charging || onAC { return "battery.100percent.bolt" }
        switch level { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"; case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }
    var tint: Color {
        guard let level else { return Theme.secondary }
        if charging || onAC { return Theme.done }
        return level <= 20 ? Theme.failed : Theme.secondary
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let loop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read(notify: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
            source = loop
        }
        read(notify: false)
    }
    private func read(notify: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let wasAC = onAC
        onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            level = Int((Double(current) / Double(maximum) * 100).rounded())
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
        }
        guard notify, let level else { return }
        if onAC && !wasAC { lowWarned.removeAll(); onChange?(true, nil) }
        else if !onAC, let threshold = [10, 20].first(where: { level <= $0 && !lowWarned.contains($0) }) {
            lowWarned.insert(threshold); onChange?(false, level)
        }
    }
}

// MARK: - Display brightness

/// Built-in display brightness through DisplayServices, the framework the system HUD
/// uses. Loaded dynamically; if unavailable, brightness keys are left to macOS.
enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }
    static var available: Bool { getter != nil && setter != nil && current != nil }
    static var current: Float? {
        guard let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }
    @discardableResult static func set(_ value: Float) -> Bool {
        guard let setter else { return false }
        return setter(display, min(1, max(0, value))) == 0
    }
}

// MARK: - Volume and brightness keys

/// Intercepts the hardware volume and brightness keys so Attending can show its own
/// slim notch HUD instead of the large system overlay. Requires Accessibility
/// permission; without it the keys keep their normal macOS behavior.
@MainActor final class MediaKeyTap: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onVolume: ((_ delta: Float?) -> Void)?      // nil delta = mute toggle
    var onBrightness: ((_ delta: Float) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustPoll: Task<Void, Never>?

    /// Asks macOS to show the Accessibility prompt, then enables once granted.
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if trusted { start(); return }
        // macOS shows its prompt only once per app; open the exact Settings pane as well.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        // macOS has no notification for this grant; check briefly while the user is in Settings.
        trustPoll?.cancel()
        trustPoll = Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if AXIsProcessTrusted() { trusted = true; start(); return }
            }
        }
    }
    func start() {
        trusted = AXIsProcessTrusted()
        guard trusted, tap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = MediaKeyTap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let refcon, let action = MediaKeyTap.classify(event) else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop.
            MainActor.assumeIsolated { owner.perform(action) }
            return nil
        }, userInfo: refcon) else { active = false; return }
        let loop = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port; source = loop; active = true
        MediaKeyTap.port = port
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; active = false
    }

    enum Action: Sendable { case volume(Float), mute, brightness(Float), swallow }
    nonisolated(unsafe) private static var port: CFMachPort?
    /// False when the output device has no software volume (HDMI, some USB DACs);
    /// volume keys then pass through to macOS instead of being swallowed.
    nonisolated(unsafe) static var volumeAdjustable = true
    /// True while the island is out of sight (full screen, an editor in front, the
    /// teleprompter): the keys go to macOS so its own volume and brightness display shows.
    nonisolated(unsafe) static var passThrough = false

    /// Decides whether a system-defined key event is one Attending handles. Key-up
    /// events for handled keys are swallowed too, so macOS never sees half a press.
    nonisolated private static func classify(_ event: CGEvent) -> Action? {
        guard !passThrough, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        // Option+Shift gives quarter steps, matching macOS.
        let step: Float = ns.modifierFlags.contains([.option, .shift]) ? 1 / 64 : 1 / 16
        if [0, 1, 7].contains(code) && !volumeAdjustable { return nil }
        switch code {
        case 0, 1: return down ? .volume(code == 0 ? step : -step) : .swallow   // NX_KEYTYPE_SOUND_UP / DOWN
        case 7: return down ? .mute : .swallow                                    // NX_KEYTYPE_MUTE
        case 2, 3:                                                                 // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
            guard DisplayBrightness.available else { return nil }
            return down ? .brightness(code == 2 ? step : -step) : .swallow
        default: return nil
        }
    }
    private func perform(_ action: Action) {
        switch action {
        case .volume(let delta): onVolume?(delta)
        case .mute: onVolume?(nil)
        case .brightness(let delta): onBrightness?(delta)
        case .swallow: break
        }
    }
}

// MARK: - Headphone battery

/// Battery levels for connected Bluetooth headphones from `system_profiler` (public,
/// no Bluetooth permission needed). AirPods report left, right and case; most other
/// headphones report one level.
enum HeadphoneBattery {
    struct Levels: Equatable { var left: Int?; var right: Int?; var caseLevel: Int?; var main: Int? }
    static func lookup(named name: String) async -> Levels? {
        // Levels can take a few seconds to appear after connecting.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let levels = await read(named: name), levels.left != nil || levels.right != nil || levels.main != nil { return levels }
        }
        return nil
    }
    private static func read(named name: String) async -> Levels? {
        let data: Data? = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile()) }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, info) in entry {
                    guard let info = info as? [String: Any], deviceName == name || deviceName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(deviceName) else { continue }
                    func percent(_ key: String) -> Int? { (info[key] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    return Levels(left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                                  caseLevel: percent("device_batteryLevelCase"), main: percent("device_batteryLevelMain"))
                }
            }
        }
        return nil
    }
    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("fit pro") { return available("beats.fitpro") }
        if lower.contains("beats") { return available("beats.headphones") }
        return "headphones"
    }
    /// Falls back to a generic symbol on systems without the specific one.
    private static func available(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "headphones"
    }
}

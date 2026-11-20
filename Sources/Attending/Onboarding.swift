import AppKit
import SwiftUI
import EventKit
import CoreLocation
import ApplicationServices

/// The first-launch window: a short welcome (the island drops in, the stethoscope draws
/// itself and the heartbeat starts), then a checklist of permissions with live status and a
/// button for each. Shown once per Mac; Settings › Help and the menu bar menu reopen it.
@MainActor final class Onboarding: NSObject, ObservableObject, NSWindowDelegate, CLLocationManagerDelegate {
    enum Step { case welcome, setup }
    enum Status { case allowed, missing, optional }

    @Published var step: Step = .welcome
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var calendar = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var location = CLLocationManager().authorizationStatus
    @Published private(set) var claude = ClaudeHooks.installed
    @Published private(set) var claudeNote: String?
    @Published private(set) var codex = CodexHooks.installed
    @Published private(set) var codexNote: String?

    weak var model: AppModel?
    private var window: NSWindow?
    private var poll: Timer?
    private let locationManager = CLLocationManager()
    private let store = EKEventStore()

    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingDone") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingDone") }
    }

    /// Once per Mac; development runs (any --flag) skip it.
    func showIfNeeded() {
        guard !Self.done, !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) else { return }
        show()
    }

    func show(step: Step = .welcome) {
        self.step = step
        refresh()
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Attending"
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(onboarding: self, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        locationManager.delegate = self
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS sends no notice when Accessibility is granted, so check while the window is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// For checking the layout: draws the open window into a PNG.
    func snapshot(to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    func finish() {
        Self.done = true
        window?.close()
        model?.raise(NotchAlert(title: "You're all set", subtitle: "Hover over the notch anytime. ⌘⇧Space opens Ask AI.", symbol: "stethoscope", color: Theme.done, target: .home), sound: "Glass")
    }
    func windowWillClose(_ notification: Notification) {
        Self.done = true
        poll?.invalidate(); poll = nil
        window = nil
    }

    // MARK: Status

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted && !accessibility, let model {
            // Turn on what was waiting for it.
            model.autoQuit.refreshTrust()
            if model.hudEnabled { model.mediaKeys.start() }
        }
        accessibility = trusted
        calendar = EKEventStore.authorizationStatus(for: .event)
        location = locationManager.authorizationStatus
        claude = ClaudeHooks.installed
        codex = CodexHooks.installed
    }
    var accessibilityStatus: Status { accessibility ? .allowed : .missing }
    var calendarStatus: Status { calendar == .fullAccess || calendar == .authorized ? .allowed : .missing }
    var locationStatus: Status { [.authorized, .authorizedAlways].contains(location) ? .allowed : .missing }
    var claudeStatus: Status { claude ? .allowed : .optional }
    var codexStatus: Status { codex ? .allowed : .optional }

    // MARK: Actions

    func allowAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { Self.openPrivacy("Privacy_Accessibility") }
    }
    func allowCalendar() {
        guard calendar == .notDetermined else { Self.openPrivacy("Privacy_Calendars"); return }
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            refresh()
            if granted { model?.setCalendar(true) }
        }
    }
    func allowLocation() {
        guard location == .notDetermined else { Self.openPrivacy("Privacy_LocationServices"); return }
        locationManager.requestWhenInUseAuthorization()
    }
    func connectClaude() {
        do { claudeNote = try ClaudeHooks.install() } catch { claudeNote = error.localizedDescription }
        refresh()
    }
    func connectCodex() {
        do { codexNote = try CodexHooks.install() } catch { codexNote = error.localizedDescription }
        refresh()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
    static func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var onboarding: Onboarding
    let reduceMotion: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.2), Color(red: 0.02, green: 0.03, blue: 0.06)], startPoint: .top, endPoint: .bottom)
            switch onboarding.step {
            case .welcome:
                WelcomeHero(reduceMotion: reduceMotion) { withAnimation(.easeInOut(duration: 0.35)) { onboarding.step = .setup } }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .setup:
                SetupList(onboarding: onboarding)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .frame(width: 600, height: 720)
    }
}

/// The welcome: the app icon assembling itself. The island drops in, the stethoscope is
/// drawn, the chestpiece lights with a heartbeat ripple, the ECG traces, then the words.
struct WelcomeHero: View {
    let reduceMotion: Bool
    let onContinue: () -> Void
    @State private var island = false
    @State private var drawn: CGFloat = 0
    @State private var chest = false
    @State private var ripple = false
    @State private var trace: CGFloat = 0
    @State private var words = false
    @State private var button = false
    private static let teal = Color(red: 0.3, green: 0.86, blue: 0.82)
    private static let scale: CGFloat = 0.27

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            ZStack {
                Circle().fill(RadialGradient(colors: [Self.teal.opacity(chest ? 0.22 : 0), .clear], center: .center, startRadius: 4, endRadius: 520))
                    .frame(width: 1040, height: 1040).offset(x: 150, y: 190)
                Capsule().fill(Color.black).frame(width: 300, height: 76)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 3))
                    .offset(y: island ? -306 : -520).opacity(island ? 1 : 0)
                IconStethoscope().trim(from: 0, to: drawn)
                    .stroke(LinearGradient(colors: [Color.white, Color(white: 0.72)], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                    .frame(width: 824, height: 824)
                Circle().stroke(Self.teal, lineWidth: 10)
                    .frame(width: 220, height: 220)
                    .scaleEffect(ripple ? 2.4 : 1).opacity(ripple ? 0 : (chest ? 0.7 : 0))
                    .offset(x: 150, y: 190)
                ZStack {
                    Circle().strokeBorder(LinearGradient(colors: [Color.white, Color(white: 0.7)], startPoint: .top, endPoint: .bottom), lineWidth: 26)
                    Circle().fill(RadialGradient(colors: [Self.teal, Color(red: 0.08, green: 0.45, blue: 0.48)], center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 90)).padding(40)
                }
                .frame(width: 220, height: 220)
                .shadow(color: Self.teal.opacity(chest ? 0.6 : 0), radius: 30)
                .scaleEffect(chest ? 1 : 0.3).opacity(chest ? 1 : 0)
                .offset(x: 150, y: 190)
            }
            .frame(width: 1024, height: 1024)
            .scaleEffect(Self.scale)
            .frame(width: 1024 * Self.scale, height: 1024 * Self.scale)

            ECGPath(spike: 1).trim(from: 0, to: trace)
                .stroke(Self.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: Self.teal.opacity(0.7), radius: 3)
                .frame(width: 240, height: 30)
                .opacity(trace > 0 ? 1 : 0)
                .padding(.top, 6)

            VStack(spacing: 8) {
                Text("Welcome to Attending").font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("Your med school companion, right in the notch.").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 22)
            .opacity(words ? 1 : 0).offset(y: words ? 0 : 10).blur(radius: words ? 0 : 6)

            Spacer(minLength: 20)
            OnboardingButton(title: "Get Started", action: onContinue)
                .opacity(button ? 1 : 0).offset(y: button ? 0 : 6)
                .padding(.bottom, 44)
        }
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            island = true; drawn = 1; chest = true; ripple = true; trace = 1; words = true; button = true
            return
        }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await wait(0.25)
        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { island = true }
        await wait(0.35)
        withAnimation(.easeInOut(duration: 1.1)) { drawn = 1 }
        await wait(1.05)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { chest = true }
        await wait(0.15)
        withAnimation(.easeOut(duration: 0.9)) { ripple = true }
        withAnimation(.easeOut(duration: 0.8)) { trace = 1 }
        await wait(0.55)
        withAnimation(.easeOut(duration: 0.6)) { words = true }
        await wait(0.5)
        withAnimation(.easeOut(duration: 0.4)) { button = true }
        // A second, softer heartbeat.
        await wait(0.4)
        ripple = false
        await wait(0.05)
        withAnimation(.easeOut(duration: 1.1)) { ripple = true }
    }
}

struct SetupList: View {
    @ObservedObject var onboarding: Onboarding
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Let's set things up").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("Allow what you'd like to use. Nothing ever leaves your Mac.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 52).padding(.bottom, 26)
            VStack(spacing: 10) {
                PermissionRow(symbol: "accessibility", title: "Accessibility", detail: "Window snapping, quitting apps, volume and brightness, hiding in full screen",
                              status: onboarding.accessibilityStatus, button: "Open Settings", action: onboarding.allowAccessibility)
                PermissionRow(symbol: "calendar", title: "Calendar", detail: "Your next class, countdowns and reminders before each one",
                              status: onboarding.calendarStatus, button: onboarding.calendar == .notDetermined ? "Allow" : "Open Settings", action: onboarding.allowCalendar)
                PermissionRow(symbol: "location", title: "Location", detail: "Weather and prayer times for where you are",
                              status: onboarding.locationStatus, button: onboarding.location == .notDetermined ? "Allow" : "Open Settings", action: onboarding.allowLocation)
                if ClaudeHooks.claudeInstalled || onboarding.claude {
                    PermissionRow(symbol: "terminal", title: "Claude Code", detail: onboarding.claudeNote ?? "Optional · agent alerts, questions and approvals in the notch",
                                  status: onboarding.claudeStatus, button: "Connect", allowed: "Connected", action: onboarding.connectClaude)
                }
                if CodexHooks.codexInstalled || onboarding.codex {
                    PermissionRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Codex", detail: onboarding.codexNote ?? "Optional · answer Codex's approval requests from the notch",
                                  status: onboarding.codexStatus, button: "Connect", allowed: "Connected", action: onboarding.connectCodex)
                }
                if let screenTime = onboarding.model?.screenTime { StudyExtras(screenTime: screenTime) }
            }
            .padding(.horizontal, 40)
            Spacer(minLength: 16)
            Text("You can change these later in System Settings, and reopen this from Settings › Help.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            OnboardingButton(title: "Continue", symbol: "arrow.right", action: onboarding.finish)
                .padding(.top, 14).padding(.bottom, 40)
        }
    }
}

/// Study extras that start off; turning them on here is the only nudge.
struct StudyExtras: View {
    @ObservedObject var screenTime: ScreenTime
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $screenTime.enabled) { extra("Screen Time", "See how much of your day goes to studying, AI and distractions") }
            Toggle(isOn: $screenTime.guardFocus) { extra("Focus guard", "A gentle nudge if YouTube or a game opens during a focus timer") }
        }
        .toggleStyle(.switch).tint(Theme.working)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
    private func extra(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: Onboarding.Status
    let button: String
    var allowed = "Allowed"
    let action: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.working).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            switch status {
            case .allowed:
                Label(allowed, systemImage: "checkmark.circle.fill").labelStyle(TrailingIconLabelStyle()).foregroundStyle(Theme.done)
            case .missing:
                Label("Not yet", systemImage: "xmark.circle.fill").labelStyle(TrailingIconLabelStyle()).foregroundStyle(Theme.failed.opacity(0.9))
                PillButton(title: button, symbol: nil, tint: Theme.working, prominent: true, action: action)
            case .optional:
                PillButton(title: button, symbol: nil, tint: Theme.working, prominent: true, action: action)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.2), value: status == .allowed)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.title; configuration.icon }
    }
}

struct OnboardingButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 28).frame(height: 44)
            .background(Capsule().fill(Color(red: 0.3, green: 0.86, blue: 0.82)))
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
    }
}

import AppKit
import ApplicationServices
import AttendingCore

/// Where your time at the Mac goes: studying, AI, or distractions. Every 30 seconds while
/// you're using the Mac it notes the front app (and, in a browser, the tab's title, read
/// through Accessibility). Only the category totals are kept, on this Mac.
@MainActor final class ScreenTime: ObservableObject {
    enum Category: String, CaseIterable {
        case study, ai, distraction
        var title: String { switch self { case .study: "Studying"; case .ai: "AI"; case .distraction: "Distractions" } }
        var logKey: String { "screen.\(rawValue)" }
    }

    /// Off for new users, who can turn it on during setup; anyone who already had it
    /// (it used to default on) keeps it.
    @Published var enabled = ScreenTime.setting("screenTime") {
        didSet { UserDefaults.standard.set(enabled, forKey: "screenTime"); restart() }
    }
    @Published var guardFocus = ScreenTime.setting("distractionGuard") {
        didSet { UserDefaults.standard.set(guardFocus, forKey: "distractionGuard"); restart() }
    }
    private static func setting(_ key: String) -> Bool {
        if let saved = UserDefaults.standard.object(forKey: key) as? Bool { return saved }
        let existing = Onboarding.done || FileManager.default.fileExists(atPath: AppPaths.directory.appendingPathComponent("state.json").path)
        UserDefaults.standard.set(existing, forKey: key)
        return existing
    }
    /// Seconds per category, logged into the activity log.
    var record: ((Category, Int) -> Void)?
    /// Called when a distraction comes to the front during focus (rate-limited).
    var onDistraction: ((String) -> Void)?
    /// Whether a focus stretch is running, from the focus timer.
    var focusing: () -> Bool = { false }

    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var lastNudge = Date.distantPast
    private static let interval: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Catch a distraction the moment it comes to the front, not up to 30 s later.
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { try? await Task.sleep(for: .milliseconds(800)); self?.checkFocus() } }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
    }
    private func restart() { stop(); if enabled || guardFocus { start() } }

    private func sample() {
        guard Self.userActive, let (category, _) = Self.current() else { checkFocus(); return }
        if enabled, let category { record?(category, Int(Self.interval)) }
        checkFocus()
    }
    private func checkFocus() {
        guard guardFocus, focusing(), Date().timeIntervalSince(lastNudge) > 180,
              let (category, name) = Self.current(), category == .distraction else { return }
        lastNudge = Date()
        onDistraction?(name)
    }

    /// True if there was keyboard or mouse input in the last two minutes.
    private static var userActive: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 120
    }

    // MARK: Sorting

    private static let studyApps: Set<String> = [
        "net.ankiweb.anki", "com.apple.Preview", "com.apple.iBooksX", "com.adobe.Reader", "com.adobe.Acrobat.Pro", "md.obsidian", "org.zotero.zotero",
        "com.microsoft.onenote.mac", "com.gingerlabs.Notability", "com.goodnotesapp.x", "com.apple.Notes", "com.microsoft.Word", "com.apple.iWork.Pages",
    ]
    private static let aiApps: Set<String> = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop"]
    private static let distractingApps: Set<String> = ["com.hnc.Discord", "com.apple.TV", "com.mojang.minecraftlauncher", "com.valvesoftware.steam", "com.apple.MobileSMS", "com.netflix.Netflix"]
    private static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera"]
    private static let studySites = ["uworld", "amboss", "boards and beyond", "sketchy", "pathoma", "truelearn", "osmosis", "lecturio", "bootcamp", "canvas", "blackboard", "brightspace", "lecom", "pubmed", "uptodate", "medscape", "anki", "google docs", "google slides", "google sheets", "quizlet", "kenhub", "teachmeanatomy", "radiopaedia", "statpearls", "first aid", "combank", "comquest"]
    private static let aiSites = ["chatgpt", "claude", "gemini", "perplexity", "openevidence"]
    private static let distractingSites = ["youtube", "instagram", "tiktok", "reddit", "twitter", " / x", "facebook", "netflix", "hulu", "disney+", "twitch", "pinterest", "snapchat", "amazon.com", "espn"]

    /// The front app's category (nil for everything else) and a short name for nudges.
    static func current() -> (Category?, String)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? "That app"
        if browsers.contains(id) {
            let title = (frontWindowTitle(of: app.processIdentifier) ?? "").lowercased()
            if let site = distractingSites.first(where: { title.contains($0) }) { return (.distraction, site == " / x" ? "X" : site.capitalized) }
            if aiSites.contains(where: { title.contains($0) }) { return (.ai, name) }
            if studySites.contains(where: { title.contains($0) }) { return (.study, name) }
            return (nil, name)
        }
        if studyApps.contains(id) { return (.study, name) }
        if aiApps.contains(id) { return (.ai, name) }
        if distractingApps.contains(id) || isGame(app) { return (.distraction, name) }
        return (nil, name)
    }
    private static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else { return false }
        return category.contains("games")
    }
    static func frontWindowTitle(of pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var window: CFTypeRef?, title: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

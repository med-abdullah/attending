import AppKit
import PDFKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import AttendingCore
import Combine

enum Tab: String, CaseIterable { case home, agents, assistant, study, shelf, clipboard, notes, prompter, mirror, settings
    var symbol: String {
        switch self { case .home: "square.grid.2x2"; case .agents: "terminal"; case .assistant: "sparkles"; case .study: "graduationcap"; case .shelf: "tray"; case .clipboard: "doc.on.clipboard"; case .notes: "note.text"; case .prompter: "text.aligncenter"; case .mirror: "camera"; case .settings: "gearshape" }
    }
    var title: String {
        switch self { case .home: "Home"; case .agents: "Agents"; case .assistant: "Ask AI"; case .study: "Study"; case .shelf: "Shelf"; case .clipboard: "Clipboard"; case .notes: "Notes"; case .prompter: "Prompter"; case .mirror: "Mirror"; case .settings: "Settings" }
    }
}

/// A short-lived banner the notch drops down for agent, timer and device events.
struct NotchAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String
    var symbol: String
    var color: Color
    var target: Tab = .agents
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var image: NSImage?
    var fileURL: URL?
    static func == (a: NotchAlert, b: NotchAlert) -> Bool { a.id == b.id }
}

@MainActor final class AppModel: ObservableObject {
    @Published var state = AppState()
    @Published var mode: PanelMode = .idle
    @Published var error: String?
    @Published var selectedTab: Tab = .home
    @Published var alert: NotchAlert?
    @Published var dropTargeted = false
    /// A file drag is hovering the notch: the preview shows drop targets instead.
    @Published var dragActive = false
    /// The pointer is over one of those drop targets.
    var dropZoneTargeted = false
    let airDropSender = AirDropSender()
    @Published var assistantFocus = 0
    @Published var notchHeight: CGFloat = 0
    @Published var notchWidth: CGFloat = 0
    /// Island position inside the panel window (SwiftUI coordinates). Animated by the
    /// window controller so every size change springs instead of jumping.
    @Published var islandFrame: CGRect = .zero
    /// The mode currently drawn; lags `mode` only by the animation transaction.
    @Published var shownMode: PanelMode = .idle
    @Published var hud: HUDState?
    var pointerInside = false
    var pickerOpen = false
    /// Tab icon frames in the panel's SwiftUI coordinates, for hover switching.
    var tabFrames: [Tab: CGRect] = [:]
    /// Set by the development snapshot tool so auto-close doesn't interfere.
    var holdOpen = false
    var lastTypingAt = Date.distantPast
    private var hudTask: Task<Void, Never>?
    private var alertOpenedPanel = false
    private var alertTask: Task<Void, Never>?
    /// The latest alert that arrived while the island was out of the way.
    private var heldAlert: (alert: NotchAlert, sound: String?, at: Date)?
    let media = MediaController()
    let volume = SystemVolume()
    let calendar = CalendarService()
    let timer = FocusTimer()
    let shelf = ShelfStore()
    let assistant = AssistantController()
    let battery = BatteryMonitor()
    let usage = UsageMonitor()
    let clipboard = ClipboardHistory()
    let weather = WeatherService()
    let mirror = MirrorController()
    let mediaKeys = MediaKeyTap()
    let anki = AnkiService()
    let exams = ExamStore()
    let autoQuit = AutoQuit()
    let keepAwake = KeepAwake()
    let activity = ActivityLog()
    let snapper = WindowSnapper()
    let cleanScreen = CleanScreen()
    let stepAside = StepAside()
    let onboarding = Onboarding()
    let whatsNew = WhatsNew()
    let prompter = Prompter()
    let screenTime = ScreenTime()
    let block = QuestionBlock()
    let weakTopics = WeakTopics()
    let lectures = LectureDay()
    let canvas = CanvasService()
    let reminders = RemindersService()
    private var canvasFeedWatch: AnyCancellable?
    /// The event-title override from a capture flag, kept while Clean screen changes titles.
    private var savedTitleOverride: String??
    let sheets = SheetTracker()
    let salah = SalahTracker()
    let updater = Updater()
    let downloads = DownloadStats()
    let drives = VolumeMonitor()
    let outlook = OutlookService()
    let launcher = LauncherStore()
    let meeting = MeetingMonitor()
    let screenshots = ScreenshotWatcher()
    let activities = ActivityCenter()
    private var sessionTask: Task<Void, Never>?
    private var wasWorking = false
    @Published var awake = true
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var providers: [ProviderDescriptor] = []
    @Published var claudeDetected = false
    @Published var codexDetected = false
    @Published var loginStatus = SMAppService.mainApp.status
    @AppStorage("showPet") var showPet = true
    @AppStorage("completionNotifications") var completionNotifications = true
    @AppStorage("hoverDelay") var hoverDelay = 0.25
    @AppStorage("hoverEnabled") var hoverEnabled = true
    @AppStorage("debugLogging") var debugLogging = false
    @AppStorage("agentAlerts") var agentAlerts = true
    @AppStorage("alertSounds") var alertSounds = true
    @AppStorage("mediaControls") var mediaControls = true
    @AppStorage("calendarEnabled") var calendarEnabled = false
    @AppStorage("weatherEnabled") var weatherEnabled = false
    @AppStorage("clipboardEnabled") var clipboardEnabled = true
    @AppStorage("hudEnabled") var hudEnabled = true
    @AppStorage("autoClose") var autoClose = true
    @AppStorage("boardsEnabled") var showExams = true
    /// Tabs in the header after Home, in order (Settings is always last). Agents is off by
    /// default: its alerts and question cards reach you anyway.
    @AppStorage("headerTabs") private var headerTabsRaw = "assistant,study,shelf,mirror"
    static let choosableTabs: [Tab] = [.agents, .assistant, .study, .shelf, .notes, .clipboard, .prompter, .mirror]
    var headerTabs: [Tab] {
        get { headerTabsRaw.split(separator: ",").compactMap { Tab(rawValue: String($0)) }.filter { Self.choosableTabs.contains($0) } }
        set { headerTabsRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }
    /// Where agent questions and approvals open: the Agents tab if it's shown, else Home.
    var agentsHome: Tab { headerTabs.contains(.agents) ? .agents : .home }
    /// Exam week: Home shows only what matters for the exam, the notch keeps to the
    /// countdown, Anki and today's goal, and your Focus shortcut runs.
    @AppStorage("examWeek") var examWeek = false {
        didSet {
            guard examWeek != oldValue else { return }
            ShortcutRunner.run(examWeek ? focusStartShortcut : focusEndShortcut)
            if !applyingExamWeek {
                // Turned off by hand during an exam's last week: leave it off for that exam.
                if !examWeek, let target = examWeekTarget { examWeekDismissed = target.key }
                examWeekAutoKey = ""
            }
            onModeChange?()
        }
    }
    /// Optional: exam week turns itself on 7 days before an exam (tracker or Boards) and off
    /// after. Off unless chosen, so the notch stays in normal mode by default.
    @AppStorage("autoExamWeek") var autoExamWeek = false { didSet { updateExamWeek() } }
    /// The exam that turned exam week on automatically; empty when it was turned on by hand.
    @AppStorage("examWeekAutoKey") private var examWeekAutoKey = ""
    @AppStorage("examWeekDismissed") private var examWeekDismissed = ""
    private var applyingExamWeek = false
    private var studyWatch: AnyCancellable?
    private var examWeekTimer: Timer?
    private var lectureTask: Task<Void, Never>?
    /// Minutes between water-and-stretch nudges while you're at the Mac; 0 is off.
    @AppStorage("breakEvery") var breakEvery = 0 { didSet { scheduleBreaks() } }
    private var breakTask: Task<Void, Never>?
    @AppStorage("islandAnchor") private var islandAnchorRaw = IslandAnchor.notch.rawValue
    var islandAnchor: IslandAnchor {
        get { IslandAnchor(rawValue: islandAnchorRaw) ?? .notch }
        set { islandAnchorRaw = newValue.rawValue; onModeChange?() }
    }
    /// Put the island on the menu-bar screen (an external display) instead of the notch's.
    @AppStorage("islandOnMainScreen") var islandOnMainScreen = false { didSet { onModeChange?() } }
    /// Minutes before each calendar event (a lecture, say) to drop down a reminder; 0 is off.
    @AppStorage("eventLead") var eventLead = 10 { didSet { scheduleEventReminder() } }
    private var eventReminderTask: Task<Void, Never>?
    private var remindedEvents = Set<String>()
    @Published var confetti = false
    @AppStorage("downloadAlerts") var downloadAlerts = true
    @AppStorage("exportAlerts") var exportAlerts = true
    @AppStorage("activitySounds") var activitySounds = true
    private var finishedBatch: [LiveActivity] = []
    private var finishedTask: Task<Void, Never>?
    @AppStorage("screenshotDrops") var screenshotDrops = true
    @AppStorage("liveActivities") var liveActivities = true
    @AppStorage("previewGlance") var previewGlance = true
    @AppStorage("salahEnabled") var salahEnabled = true
    @AppStorage("salahAlerts") var salahAlerts = true
    /// Height Home's content needs; every tab shares it so switching never resizes.
    @Published var homeHeight: CGFloat = 540
    @AppStorage("focusStartShortcut") var focusStartShortcut = ""
    @AppStorage("focusEndShortcut") var focusEndShortcut = ""
    let store = StateStore(url: AppPaths.directory.appendingPathComponent("state.json"))
    private var watcher: EventWatcher?
    private var saveTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var storageHealthy = true
    @Published var celebrating = false
    @Published var claudeApprovals: [ApprovalRequest] = []
    @Published var codexApprovals: [CodexTransportApproval] = []
    @Published var codexTurns: [String: CodexTurn] = [:]
    @Published var selectedSessionID: String?
    @Published var agentsShowRecent = false
    @Published var draft = ""
    @Published var codexBusy = false
    @Published var responseText: [String: String] = [:]
    private let liveEventsSince = Date()
    private let codex = CodexTransport()
    private let approvalBroker = ApprovalBroker()
    private var adapterTasks: [Task<Void, Never>] = []
    private var codexThreads: [String: CodexOwnedThread] = [:]
    private var codexSessions: CodexSessionWatcher?
    private var titleChecks: [String: Date] = [:]
    var selectedSession: AgentSession? { state.sessions.first { $0.id == selectedSessionID } }
    var canSendToSelected: Bool {
        guard let session = selectedSession else { return false }
        return providers.first(where: { $0.id == session.provider })?.capabilities.contains(.sendMessage) == true && state.managedCodexProjects?[session.externalID] != nil
    }
    var onProjectPicker: ((Bool) -> Void)?
    var onModeChange: (() -> Void)?
    /// Running sessions, plus ones opened in the last 15 minutes that are waiting for a prompt.
    var active: [AgentSession] {
        let recent = Date().addingTimeInterval(-15 * 60)
        return state.sessions.filter { $0.status == .working || $0.status == .attention || ($0.status == .idle && $0.lastActiveAt > recent) }
    }
    /// Everything else from the last week, without test and scratch folders.
    var recent: [AgentSession] {
        let shown = Set(active.map(\.id)), week = Date().addingTimeInterval(-7 * 86400)
        return Array(state.sessions.filter { !shown.contains($0.id) && $0.lastActiveAt > week && !SessionNaming.isScratch($0.projectPath) }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(20))
    }
    var attention: [AgentSession] { state.sessions.filter { $0.status == .attention } }
    var attentionCount: Int {
        var ids = Set(attention.map(\.id))
        for request in claudeApprovals { ids.insert("claudeCode:" + request.sessionID) }
        for request in codexApprovals { ids.insert("codex:" + request.threadID) }
        return ids.count
    }
    var mood: SessionStatus {
        if !attention.isEmpty || !claudeApprovals.isEmpty || !codexApprovals.isEmpty { return .attention }
        if state.sessions.contains(where: { $0.status == .working }) { return .working }
        if celebrating { return .completed }
        if state.sessions.contains(where: { $0.status == .failed && $0.lastActiveAt > Date().addingTimeInterval(-600) }) { return .failed }
        return .idle
    }
    func start() async {
        // Character pets were replaced by refined marks (2026-09-28); older choices migrate once.
        if !UserDefaults.standard.bool(forKey: "petMigratedToStethoscope") {
            UserDefaults.standard.set(PetKind.stethoscope.rawValue, forKey: "pet")
            UserDefaults.standard.set(true, forKey: "petMigratedToStethoscope")
        }
        if mediaControls { media.start() }
        volume.start()
        if calendarEnabled { calendar.start(requestIfNeeded: true) }
        if weatherEnabled { weather.start() }
        if salahEnabled { salah.start() }
        mirror.onPhoto = { [weak self] url in self?.shelf.add([url]) }
        mirror.onRunning = { [weak self] running in self?.meeting.ownCameraActive = running }
        updater.onAvailable = { [weak self] release in
            self?.raise(NotchAlert(title: "Attending \(release.version) is available", subtitle: "You have \(self?.updater.current ?? "")", symbol: "arrow.down.circle.fill", color: Theme.working, target: .settings,
                                   actionTitle: "Update", action: { [weak self] in self?.updater.install(); self?.alert = nil }), essential: false)
        }
        updater.start()
        downloads.onMilestone = { [weak self] count in
            self?.raise(NotchAlert(title: "Attending hit \(count.formatted()) downloads", subtitle: "People are installing what you built.", symbol: "arrow.down.circle.fill", color: Theme.done, target: .settings), sound: "Hero", essential: false)
        }
        downloads.start()
        airDropSender.onSent = { [weak self] urls in
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            self?.raise(NotchAlert(title: "Sent with AirDrop", subtitle: what, symbol: "checkmark.circle.fill", color: Theme.done, target: .shelf), sound: "Glass")
        }
        airDropSender.onFailed = { [weak self] message in
            self?.raise(NotchAlert(title: "AirDrop didn't send", subtitle: message, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf), sound: "Basso")
        }
        salah.onPrayerTime = { [weak self] prayer, time in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "Time for \(prayer.title)", subtitle: "\(time.formatted(date: .omitted, time: .shortened))\(salah.place.map { " in \($0)" } ?? "")", symbol: "moon.stars.fill", color: Theme.done, target: .home,
                             actionTitle: "Prayed", action: { [weak self] in self?.salah.toggle(prayer); self?.alert = nil }), sound: "Glass")
        }
        salah.onEndingSoon = { [weak self] prayer, end in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "\(prayer.title) ends in 15 minutes", subtitle: "Until \(end.formatted(date: .omitted, time: .shortened))", symbol: "hourglass", color: Theme.attention, target: .home,
                             actionTitle: "Prayed", action: { [weak self] in self?.salah.toggle(prayer); self?.alert = nil }), sound: "Tink")
        }
        salah.onJummah = { [weak self] khutbah in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "Jummah at \(khutbah.formatted(date: .omitted, time: .shortened))", subtitle: "Jummah Mubarak. Time to head to the masjid.", symbol: "building.columns.fill", color: Theme.done, target: .home), sound: "Glass")
        }
        salah.onKahf = { [weak self] in
            guard let self, salahAlerts else { return }
            raise(NotchAlert(title: "Jummah Mubarak", subtitle: "A reminder to read Surah Al-Kahf today", symbol: "book.closed.fill", color: Theme.done, target: .home), sound: "Glass")
        }
        exams.onMilestone = { [weak self] exam, days in
            guard let self, showExams, exams.visible(exam) else { return }
            raise(NotchAlert(title: days == 1 ? "\(exam.shortName) is tomorrow" : "\(days) days to \(exam.shortName)", subtitle: days <= 7 ? "You've put in the work. Keep it steady." : "\(BoardsMath.studyDays(from: Date(), to: exam.date, daysOff: exam.daysOff)) study days left", symbol: "graduationcap.fill", color: exams.urgency(exam), target: .study), sound: "Glass")
        }
        exams.onChecklist = { [weak self] exam in
            guard let self, showExams else { return }
            raise(NotchAlert(title: "\(exam.shortName) tomorrow", subtitle: "Check your exam-day list: ID, permit, snacks, layers", symbol: "checklist", color: Theme.attention, target: .study, actionTitle: "Checklist", action: { [weak self] in self?.open(.study) }), sound: "Glass")
        }
        exams.onBedtime = { [weak self] exam, days in
            guard let self, showExams else { return }
            let bedtime = Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(exams.bedtimeMinutes * 60))
            raise(NotchAlert(title: days == 1 ? "\(exam.shortName) tomorrow" : "\(exam.shortName) in 2 days", subtitle: "Wind down by \(bedtime.formatted(date: .omitted, time: .shortened)). Sleep is part of the plan.", symbol: "moon.zzz.fill", color: Theme.working, target: .study), sound: "Glass")
        }
        exams.onExamMorning = { [weak self] exam in
            guard let self, showExams else { return }
            raise(NotchAlert(title: "Good luck today", subtitle: "\(exam.name) at \(exam.date.formatted(date: .omitted, time: .shortened)). You've got this.", symbol: "heart.fill", color: Theme.done, target: .study), sound: "Glass")
        }
        exams.onFinished = { [weak self] exam in
            guard let self, showExams else { return }
            raise(NotchAlert(title: "You did it", subtitle: exam.expectedScores.map { "\(exam.shortName) is done. Scores around \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "\(exam.name) is done. Go rest.", symbol: "party.popper.fill", color: Theme.done, target: .study), sound: "Hero")
            confetti = true
            Task { try? await Task.sleep(for: .seconds(4)); self.confetti = false }
        }
        exams.schedule()
        block.onChange = { [weak self] in self?.objectWillChange.send(); self?.onModeChange?() }
        block.onEnd = { [weak self] result in
            guard let self else { return }
            raise(NotchAlert(title: result.timeUp ? "Time. Block finished" : "Block finished", subtitle: "\(result.answered) of \(result.total) in \(QuestionBlock.clock(result.elapsed)) · \(QuestionBlock.clock(result.perQuestion)) per question",
                             symbol: "checkmark.seal.fill", color: Theme.done, target: .study, actionTitle: "Log misses", action: { [weak self] in self?.open(.study) }), sound: "Glass")
        }
        // Exam week follows the trackers and Boards as they load and change.
        studyWatch = sheets.objectWillChange.merge(with: exams.objectWillChange).debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateExamWeek() }
        let examWeekTimer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateExamWeek() } }
        RunLoop.main.add(examWeekTimer, forMode: .common)
        self.examWeekTimer = examWeekTimer
        updateExamWeek()
        scheduleLectureSummary()
        canvas.onNewAnnouncement = { [weak self] item in
            self?.raise(NotchAlert(title: item.title, subtitle: "\(item.course) · Canvas announcement", symbol: "megaphone.fill", color: Theme.working, target: .study,
                                   actionTitle: "Open", action: { if let url = item.url { NSWorkspace.shared.open(url) } }), sound: "Tink")
        }
        // The Canvas calendar joins Calendars once, when first found; removing it there keeps it removed.
        canvasFeedWatch = canvas.$calendarFeed.compactMap { $0 }.removeDuplicates().sink { [weak self] feed in
            guard let self, UserDefaults.standard.string(forKey: "canvasFeedAdded") != feed else { return }
            UserDefaults.standard.set(feed, forKey: "canvasFeedAdded")
            guard !calendar.feeds.contains(where: { $0.url == feed }) else { return }
            Task { _ = await self.calendar.addFeed(feed, name: "Canvas") }
        }
        canvas.start()
        reminders.start()
        autoQuit.start()
        snapper.start()
        screenTime.record = { [weak self] category, seconds in self?.activity.add(category.logKey, seconds) }
        screenTime.focusing = { [weak self] in self.map { $0.timer.isRunning && !$0.timer.isBreak } ?? false }
        screenTime.onDistraction = { [weak self] name in
            guard let self else { return }
            let minutes = max(1, Int((timer.total - timer.remaining()) / 60))
            raise(NotchAlert(title: "You're \(minutes) min into focus", subtitle: "\(name) can wait. Back to it?", symbol: "brain.head.profile", color: Theme.attention, target: .home), sound: "Tink")
        }
        if screenTime.enabled || screenTime.guardFocus { screenTime.start() }
        cleanScreen.onChange = { [weak self] on in
            guard let self else { return }
            if on { savedTitleOverride = calendar.titleOverride; calendar.titleOverride = "Busy" }
            else { calendar.titleOverride = savedTitleOverride ?? nil; savedTitleOverride = nil }
            media.hiddenForCapture = on
            calendar.refresh()
            objectWillChange.send()
        }
        timer.onFocusMinutes = { [weak self] minutes in if minutes >= 1 { self?.activity.add("focus", Int(minutes.rounded())) } }
        sheets.onPagesToday = { [weak self] pages in self?.activity.record("pages", pages) }
        exams.onQuestions = { [weak self] count in self?.activity.add("questions", count) }
        activity.onRecap = { [weak self] in
            guard let self else { return }
            let week = self.week
            guard !week.isEmpty else { return }
            let parts = [week.focusMinutes > 0 ? "\(WeekCard.hours(week.focusMinutes)) focused" : nil, week.pages > 0 ? "\(week.pages) pages" : nil,
                         week.reviews > 0 ? "\(week.reviews) reviews" : nil].compactMap { $0 }
            raise(NotchAlert(title: "Your week", subtitle: parts.joined(separator: " · "), symbol: "chart.bar.fill", color: Theme.done, target: .study,
                             actionTitle: "Share", action: { [weak self] in self?.shareWeek() }), sound: "Glass", essential: false)
        }
        activity.schedule()
        scheduleBreaks()
        if clipboardEnabled { clipboard.start() }
        usage.start()
        assistant.onClaudeLoaded = { [weak self] in self?.usage.refreshFromClaude() }
        // An answer finished while you weren't looking at it: a check drops down.
        assistant.onAnswered = { [weak self] provider in
            guard let self, !(mode == .expanded && selectedTab == .assistant && assistant.provider == provider) else { return }
            var alert = NotchAlert(title: "\(provider.title) answered", subtitle: "Your answer is ready", symbol: "checkmark.circle.fill", color: Theme.done, target: .assistant)
            alert.actionTitle = "Show"
            alert.action = { [weak self] in self?.assistant.provider = provider; self?.open(.assistant) }
            raise(alert, sound: "Glass", agent: true)
        }
        usage.onThreshold = { [weak self] percent, resets in
            let when = resets.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            self?.raise(NotchAlert(title: "Claude usage at \(percent)%", subtitle: "5-hour limit\(when)", symbol: "gauge.with.dots.needle.67percent", color: percent >= 95 ? Theme.failed : Theme.attention, target: .home), sound: "Tink", essential: false)
        }
        battery.onChange = { [weak self] pluggedIn, low in
            guard let self, let level = battery.level else { return }
            if pluggedIn { showHUD(HUDState(kind: .battery, value: Double(level) / 100, symbol: "bolt.fill", tint: Theme.done, label: "\(level)%")) }
            else if let low { showHUD(HUDState(kind: .battery, value: Double(low) / 100, symbol: "battery.25percent", tint: Theme.failed, label: "\(low)% left")) }
        }
        battery.start()
        calendar.onChange = { [weak self] in self?.scheduleEventReminder() }
        volume.onBluetoothOutput = { [weak self] name in
            Task { @MainActor in
                guard let levels = await HeadphoneBattery.lookup(named: name) else { return }
                var parts: [String] = []
                if let left = levels.left { parts.append("L \(left)%") }
                if let right = levels.right { parts.append("R \(right)%") }
                if let caseLevel = levels.caseLevel { parts.append("Case \(caseLevel)%") }
                if parts.isEmpty, let main = levels.main { parts.append("\(main)%") }
                let lowest = [levels.left, levels.right, levels.main].compactMap { $0 }.min() ?? 100
                self?.showHUD(HUDState(kind: .headphones, value: Double(lowest) / 100, symbol: HeadphoneBattery.symbol(for: name),
                                       tint: lowest <= 20 ? Theme.failed : Theme.primary, label: parts.joined(separator: "  ")), seconds: 4)
            }
        }
        mediaKeys.onVolume = { [weak self] delta in
            guard let self else { return }
            if let delta { volume.set(volume.level + delta) } else { volume.toggleMute() }
            showHUD(HUDState(kind: .volume, value: volume.muted ? 0 : Double(volume.level), symbol: volume.muted || volume.level == 0 ? "speaker.slash.fill" : volume.level < 0.34 ? "speaker.wave.1.fill" : volume.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill", tint: Theme.primary))
        }
        mediaKeys.onBrightness = { [weak self] delta in
            guard let self, let current = DisplayBrightness.current else { return }
            let next = min(1, max(0, current + delta))
            DisplayBrightness.set(next)
            showHUD(HUDState(kind: .brightness, value: Double(next), symbol: next < 0.4 ? "sun.min.fill" : "sun.max.fill", tint: Theme.amber))
        }
        if hudEnabled { mediaKeys.start() }
        anki.start()
        outlook.start()
        meeting.start()
        drives.onMount = { [weak self] volume in
            guard let self else { return }
            raise(NotchAlert(title: "\(volume.name) connected", subtitle: volume.available.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free" } ?? "External drive", symbol: "externaldrive.fill", color: Theme.working, target: .home, actionTitle: "Eject", action: { [weak self] in self?.drives.eject(volume) }), sound: "Tink")
        }
        sheets.onGoalMet = { [weak self] summary, goal in
            let days = summary.daysLeft ?? 0
            self?.raise(NotchAlert(title: "Today's reading is done", subtitle: "\(goal.done) pages for \(summary.shortName) · \(days == 1 ? "1 day" : "\(days) days") to go", symbol: "book.closed.fill", color: Theme.done, target: .study), sound: "Glass")
        }
        drives.onEjectResult = { [weak self] name, error in
            if let error { self?.raise(NotchAlert(title: "\(name) couldn't eject", subtitle: error, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .home), sound: "Basso") }
            else { self?.showHUD(HUDState(kind: .battery, value: 1, symbol: "eject.fill", tint: Theme.done, label: "Safe to unplug")) }
        }
        drives.start()
        drives.onChange = { [weak self] in if self?.liveActivities == true { self?.activities.restartExportWatch() } }
        screenshots.onCapture = { [weak self] url in self?.screenshotTaken(url) }
        if screenshotDrops { screenshots.start() }
        activities.onFinished = { [weak self] activity in self?.activityFinished(activity) }
        if liveActivities { activities.start() }
        timer.onPhaseChange = { [weak self] session in
            let focus = session.phase == .focus
            self?.raise(NotchAlert(title: focus ? "Back to focus" : "\(session.phase.title) time", subtitle: focus ? "Cycle \(session.cycle) of \(session.cycles)" : "\(Int(session.phase == .longBreak ? session.longBreakMinutes : session.breakMinutes)) minutes. Stand up and stretch.", symbol: focus ? "brain.head.profile" : "cup.and.saucer.fill", color: focus ? Theme.done : Theme.working, target: .study), sound: focus ? "Hero" : "Glass")
        }
        timer.onSessionComplete = { [weak self] session in
            guard let self else { return }
            sessionTask?.cancel()
            let minutes = Int(Date().timeIntervalSince(session.startedAt) / 60)
            let reviews = session.reviewGoal != nil ? "\(session.reviewsDone) reviews in " : ""
            raise(NotchAlert(title: "Session complete", subtitle: "\(reviews)\(minutes) min. Nice work.", symbol: "checkmark.seal.fill", color: Theme.done, target: .study), sound: "Glass")
            anki.refresh()
        }
        timer.onFinish = { [weak self] in
            guard let self else { return }
            raise(NotchAlert(title: "\(timer.label) complete", subtitle: "Time for a break", symbol: "timer", color: Theme.done, target: .home), sound: "Glass")
        }
        do { state = try await store.load(); state.markDisconnected(); renameFolderTitles() }
        catch { storageHealthy = false; self.error = "Saved state could not be read. It has been preserved. Clear history in Settings to start fresh." }
        claudeDetected = FileManager.default.isExecutableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path) || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude")
        codexDetected = FileManager.default.isExecutableFile(atPath: codex.executableURL.path)
        providers = [
            .init(id: .claudeCode, capabilities: [.observe, .openProject], detail: "Documented hooks · monitoring requires hook installation"),
            codex.descriptor,
            .init(id: .chatGPT, capabilities: [], detail: "No consumer session-control API; links only in a future adapter.")
        ]
        await startAdapters()
        do {
            watcher = try EventWatcher(directory: AppPaths.events) { [weak self] events in
                Task { @MainActor in self?.receive(events) }
            }
        } catch { self.error = "Cannot monitor agent events: \(error.localizedDescription)" }
        let watcher = CodexSessionWatcher(since: liveEventsSince,
            onEvents: { [weak self] events in Task { @MainActor in self?.receive(events) } },
            onTitle: { [weak self] id, title in Task { @MainActor in self?.setTitle(title, for: ProviderID.codex.rawValue + ":" + id) } })
        watcher.start()
        codexSessions = watcher
        for session in state.sessions.prefix(30) where session.provider == .claudeCode { lookUpClaudeTitle(session) }
    }
    /// Sessions saved before titles existed were named after their folder.
    private func renameFolderTitles() {
        for i in state.sessions.indices where state.sessions[i].title == URL(fileURLWithPath: state.sessions[i].projectPath).lastPathComponent {
            state.sessions[i].title = SessionNaming.folderTitle(state.sessions[i].projectPath)
        }
    }
    func setTitle(_ title: String, for id: String) {
        guard let i = state.sessions.firstIndex(where: { $0.id == id }), state.sessions[i].title != title else { return }
        state.sessions[i].title = title
        persist()
    }
    /// Claude Code keeps a session's name in its transcript; only the title records are read.
    private func lookUpClaudeTitle(_ session: AgentSession) {
        if let checked = titleChecks[session.id], Date().timeIntervalSince(checked) < 30 { return }
        titleChecks[session.id] = Date()
        let id = session.externalID, key = session.id
        Task.detached(priority: .utility) {
            guard let title = Self.claudeTitle(sessionID: id) else { return }
            await MainActor.run { self.setTitle(title, for: key) }
        }
    }
    nonisolated static func claudeTitle(sessionID: String) -> String? {
        guard !sessionID.contains("/"), !sessionID.hasPrefix(".") else { return nil }
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let transcript = folder.appendingPathComponent(sessionID + ".jsonl")
            guard let handle = try? FileHandle(forReadingFrom: transcript) else { continue }
            defer { try? handle.close() }
            // Claude Code rewrites the title record often, so the end of the file has the latest.
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
            guard let tail = try? handle.readToEnd() else { return nil }
            return ClaudeSessionTitle.parse(String(decoding: tail, as: UTF8.self))
        }
        return nil
    }
    func startAdapters() async {
        do {
            try await approvalBroker.start()
            adapterTasks.append(Task { [weak self] in
                guard let self else { return }
                for await requests in approvalBroker.snapshots {
                    let known = Set(claudeApprovals.map(\.id))
                    claudeApprovals = requests
                    if let fresh = requests.first(where: { !known.contains($0.id) }) {
                        let session = state.sessions.first { $0.id == fresh.provider.rawValue + ":" + fresh.sessionID }?.title ?? SessionNaming.folderTitle(fresh.projectPath)
                        let (title, symbol) = switch fresh.toolName {
                        case "AskUserQuestion": ("Claude has a question", "questionmark.bubble.fill")
                        case "ExitPlanMode": ("Claude has a plan to approve", "list.bullet.clipboard.fill")
                        default: ("\(fresh.provider.title) needs approval", "hand.raised.fill")
                        }
                        let subtitle = fresh.toolName == "AskUserQuestion" || fresh.toolName == "ExitPlanMode" ? session : "\(fresh.toolName) · \(session)"
                        var alert = NotchAlert(title: title, subtitle: subtitle, symbol: symbol, color: Theme.attention)
                        alert.actionTitle = fresh.toolName == "AskUserQuestion" ? "Answer" : "Review"
                        alert.action = { [weak self] in guard let self else { return }; selectedSessionID = nil; open(agentsHome) }
                        raise(alert, sound: "Ping", agent: true)
                    }
                }
            })
        } catch { self.error = "Approval relay unavailable: \(error.localizedDescription)" }
        adapterTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in codex.events() { receive([event]) }
        })
        adapterTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in codex.transportEvents() {
                switch event {
                case .text(let threadID, _, let delta):
                    responseText[threadID] = String(((responseText[threadID] ?? "") + delta).suffix(16_000))
                case .summary(let threadID, _, let text): responseText[threadID] = String(text.suffix(16_000))
                case .turn(let threadID, let turnID, let active):
                    if active { codexTurns[threadID] = CodexTurn(id: turnID, threadID: threadID) }
                    else { codexTurns.removeValue(forKey: threadID) }
                case .approval(let request):
                    codexApprovals.append(request)
                    raise(NotchAlert(title: "Codex needs approval", subtitle: request.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Permission request", symbol: "hand.raised.fill", color: Theme.attention), sound: "Ping", agent: true)
                case .approvalResolved(let id): codexApprovals.removeAll { $0.id == id }
                case .diagnostic(let text): error = text
                }
            }
        })
    }
    func newCodexProject() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Use Project"
        onProjectPicker?(true)
        NSApp.activate()
        picker.begin { [weak self] result in
            self?.onProjectPicker?(false)
            guard result == .OK, let url = picker.url else { return }
            Task { @MainActor in await self?.createCodexProject(path: url.path) }
        }
    }
    func createCodexProject(path: String) async {
        codexBusy = true; defer { codexBusy = false }
        do {
            let thread = try await codex.start(projectPath: path)
            codexThreads[thread.id] = thread
            if state.managedCodexProjects == nil { state.managedCodexProjects = [:] }
            state.managedCodexProjects?[thread.id] = path
            selectedSessionID = ProviderID.codex.rawValue + ":" + thread.id
            receive([.init(provider: .codex, sessionID: thread.id, projectPath: path, kind: .started)])
            selectedTab = .agents
        } catch { self.error = "Codex connection: \(error.localizedDescription)" }
    }
    func sendDraft() {
        guard let session = selectedSession, canSendToSelected, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !codexBusy else { return }
        let text = draft
        codexBusy = true
        Task {
            defer { codexBusy = false }
            do {
                let thread: CodexOwnedThread
                if let loaded = codexThreads[session.externalID] { thread = loaded }
                else {
                    thread = try await codex.resume(CodexOwnedThread(id: session.externalID, projectPath: session.projectPath))
                    codexThreads[thread.id] = thread
                }
                if let turn = codexTurns[thread.id] { _ = try await codex.steer(in: thread, turn: turn, prompt: text) }
                else {
                    responseText[thread.id] = ""
                    let turn = try await codex.startTurn(in: thread, prompt: text)
                    codexTurns[thread.id] = turn
                }
                if draft == text { draft = "" }
            } catch { self.error = "Instruction was not sent: \(error.localizedDescription)" }
        }
    }
    func stopSelectedTurn() {
        guard let session = selectedSession, let thread = codexThreads[session.externalID], let turn = codexTurns[session.externalID] else { return }
        Task { do { try await codex.interrupt(in: thread, turn: turn) } catch { self.error = error.localizedDescription } }
    }
    func respondClaude(_ request: ApprovalRequest, decision: ApprovalDecision, answers: [String: String]? = nil) {
        Task {
            let accepted = await approvalBroker.respond(to: request.id, decision: decision, answers: answers)
            claudeApprovals.removeAll { $0.id == request.id }
            if accepted { receive([.init(provider: request.provider, sessionID: request.sessionID, projectPath: request.projectPath, kind: .working)]) }
            if !accepted { error = "This permission request expired or disconnected. Respond in Claude Code." }
        }
    }
    func respondCodex(_ request: CodexTransportApproval, decision: CodexApprovalDecision) {
        Task {
            do { try await codex.respond(to: request, decision: decision); codexApprovals.removeAll { $0.id == request.id } }
            catch { self.error = "Permission response: \(error.localizedDescription)" }
        }
    }
    func receive(_ events: [AgentEvent]) {
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            if event.provider == .codex && event.kind == .ended {
                codexThreads.removeValue(forKey: event.sessionID)
                codexTurns.removeValue(forKey: event.sessionID)
            }
            let old = state
            state.apply(event, liveEventsSince: liveEventsSince)
            if event.provider == .claudeCode, event.timestamp >= liveEventsSince, let session = state.sessions.first(where: { $0.id == "claudeCode:" + event.sessionID }) {
                lookUpClaudeTitle(session)
            }
            if state != old && event.timestamp >= liveEventsSince && event.kind == .completed && completionNotifications {
                celebrating = true
                completionTask?.cancel()
                completionTask = Task { try? await Task.sleep(for: .seconds(4)); guard !Task.isCancelled else { return }; celebrating = false }
            }
            if state != old && event.timestamp >= liveEventsSince, let session = state.sessions.first(where: { $0.id == event.provider.rawValue + ":" + event.sessionID }) {
                switch event.kind {
                case .completed: raise(NotchAlert(title: "\(event.provider.title) finished", subtitle: session.title, symbol: "checkmark.circle.fill", color: Theme.done), sound: "Glass", agent: true, essential: false)
                case .attention where event.provider == .codex:
                    // Codex's questions can only be answered in Codex itself, so the alert opens it.
                    var alert = NotchAlert(title: "Codex has a question", subtitle: session.title, symbol: "questionmark.bubble.fill", color: Theme.attention)
                    alert.actionTitle = "Open"
                    alert.action = { [weak self] in self?.alert = nil; self?.setMode(.idle); CodexSessionWatcher.openApp() }
                    raise(alert, sound: "Ping", agent: true)
                case .attention: raise(NotchAlert(title: "\(event.provider.title) needs you", subtitle: session.title, symbol: "exclamationmark.circle.fill", color: Theme.attention), sound: "Ping", agent: true)
                case .failed: raise(NotchAlert(title: "\(event.provider.title) hit an error", subtitle: session.title, symbol: "xmark.octagon.fill", color: Theme.failed), sound: "Basso", agent: true)
                default: break
                }
            }
        }
        updateWorkingAutomation()
        persist()
    }
    /// Runs the user's Focus shortcuts as agents start and stop working.
    private func updateWorkingAutomation() {
        let working = state.sessions.contains { $0.status == .working }
        keepAwake.agentsWorking = working
        guard working != wasWorking else { return }
        wasWorking = working
        // During exam week Focus stays on, so agents finishing doesn't turn it off.
        if working || !examWeek { ShortcutRunner.run(working ? focusStartShortcut : focusEndShortcut) }
    }
    func persist() {
        guard storageHealthy else { return }
        let snapshot = state
        // One ordered task chain prevents an older snapshot overwriting a newer one.
        let prior = saveTask
        saveTask = Task {
            await prior?.value
            do { try await store.save(snapshot) } catch { self.error = "Could not save Attending state: \(error.localizedDescription)" }
        }
    }
    func shutdown() async {
        cleanScreen.set(false)
        media.stop()
        activities.stop()
        mediaKeys.stop()
        mirror.stop()
        for task in adapterTasks { task.cancel() }
        await approvalBroker.stop()
        await codex.shutdown()
        codexSessions?.stop()
        await saveTask?.value
    }
    func clearHistory() {
        let pendingIDs = Set(claudeApprovals.map { "claudeCode:" + $0.sessionID } + codexApprovals.map { "codex:" + $0.threadID })
        state.sessions.removeAll { ![.working, .attention, .idle].contains($0.status) && !pendingIDs.contains($0.id) }
        let kept = Set(state.sessions.filter { $0.provider == .codex }.map(\.externalID))
        state.managedCodexProjects = state.managedCodexProjects?.filter { kept.contains($0.key) }
        responseText = responseText.filter { kept.contains($0.key) }
        codexThreads = codexThreads.filter { kept.contains($0.key) }
        if selectedSession == nil { selectedSessionID = nil; draft = "" }
        storageHealthy = true; persist()
    }
    func setMode(_ value: PanelMode) {
        if value != .preview { alertOpenedPanel = false }
        mode = value; onModeChange?()
    }
    func open(_ tab: Tab) { selectedTab = tab; alert = nil; setMode(.expanded) }

    // MARK: Drag and drop

    /// A file drag reached the notch. Collapsed or peeking, the island drops a compact
    /// panel of targets (AirDrop, Shelf, Drive) right under the pointer; expanded, the
    /// drop goes wherever it's aimed.
    func dragChanged(targeted: Bool) {
        if targeted {
            dragExitTask?.cancel()
            if mode != .expanded && !dragActive { dragActive = true; alert = nil; setMode(.preview) }
        } else if dragActive {
            // Moving between targets briefly leaves them all; only close if the drag really left.
            dragExitTask?.cancel()
            dragExitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, dragActive, !dropTargeted, !dropZoneTargeted else { return }
                dragActive = false
                if !pointerInside { setMode(.idle) }
            }
        }
    }
    private var dragExitTask: Task<Void, Never>?
    func dropOnShelf(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        shelf.add(urls)
        finishDrop()
        raise(NotchAlert(title: "On your Shelf", subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", symbol: "tray.and.arrow.down.fill", color: Theme.working, target: .shelf))
    }
    /// The island tucks away so the AirDrop window has the screen.
    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        finishDrop()
        setMode(.idle)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            airDropSender.send(urls)
        }
    }
    func saveToDrive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        finishDrop()
        raise(NotchAlert(title: "Google Drive", subtitle: GoogleDrive.save(urls), symbol: "externaldrive.badge.icloud", color: Theme.working, target: .shelf))
    }
    private func finishDrop() { dragExitTask?.cancel(); dragActive = false; dropZoneTargeted = false }
    func openAssistant() { open(.assistant); assistantFocus += 1 }

    /// Drops a banner out of the notch for a few seconds, then tucks it away
    /// unless the pointer is resting on it.
    func raise(_ next: NotchAlert, sound: String? = nil, agent: Bool = false, essential: Bool = true) {
        // The Settings toggle covers agent events; timers, screenshots and drives always show.
        // Exam week holds back the ones that can wait.
        guard awake, agentAlerts || !agent, essential || !examWeek else { return }
        // Out of the way (full screen, an editor in front, the teleprompter): hold the
        // latest one for when the island comes back, without a sound.
        if islandAside { heldAlert = (next, sound, Date()); return }
        alert = next
        if alertSounds, let sound { NSSound(named: sound)?.play() }
        if mode == .idle { alertOpenedPanel = true; setMode(.preview) }
        alertTask?.cancel()
        alertTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            alert = nil
            if mode == .preview && alertOpenedPanel && !pointerInside { setMode(.idle) }
        }
    }
    /// True while the island steps aside and isn't open.
    var islandAside: Bool { (stepAside.hidden || prompter.running) && mode == .idle }
    /// Shows an alert that waited, if it's recent.
    func releaseHeldAlert() {
        guard let held = heldAlert else { return }
        heldAlert = nil
        // Shown quietly: its moment has passed, and a ding on switching apps is jarring.
        if Date().timeIntervalSince(held.at) < 30 * 60 { raise(held.alert) }
    }
    func setMediaControls(_ enabled: Bool) {
        mediaControls = enabled
        if enabled { media.start() } else { media.stop() }
    }
    /// Starts a Pomodoro session and, with a review goal, tracks Anki progress live.
    func startStudySession(focus: Double, breakMinutes: Double, goal: Int?, openAnki: Bool) {
        sessionTask?.cancel()
        // The baseline comes from a fresh count on the first poll, never the cached stats.
        timer.startSession(focus: focus, breakMinutes: breakMinutes, longBreak: max(15, breakMinutes * 3), reviewGoal: goal, reviewBaseline: nil)
        if openAnki { anki.openAnki() }
        guard goal != nil else { return }
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, timer.session != nil else { return }
                if let today = await anki.reviewsToday() {
                    if timer.session?.reviewBaseline == nil { timer.startSessionBaseline(today) }
                    timer.updateReviews(today: today)
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
    /// Downloads and exports that finish within a few seconds of each other share one alert,
    /// which is silent while a video editor is in front (you're watching the render there).
    private func activityFinished(_ activity: LiveActivity) {
        guard activity.kind == .export ? exportAlerts : downloadAlerts else { return }
        finishedBatch.append(activity)
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            let batch = finishedBatch
            finishedBatch = []
            guard let last = batch.last else { return }
            var alert: NotchAlert
            if batch.count == 1 {
                let export = last.kind == .export
                alert = NotchAlert(title: export ? "\(last.appName.map { "\($0) render" } ?? "Export") finished" : "Download finished",
                                   subtitle: "\(last.name) · \(last.sizeText)", symbol: export ? "film.fill" : "arrow.down.circle.fill", color: Theme.done, target: .home)
                alert.image = ActivityCenter.icon(for: last)
                alert.fileURL = last.url
            } else {
                let exports = batch.filter { $0.kind == .export }.count
                let noun = exports == batch.count ? "exports" : exports == 0 ? "downloads" : "files"
                alert = NotchAlert(title: "\(batch.count) \(noun) finished", subtitle: batch.map(\.name).joined(separator: ", "),
                                   symbol: exports > 0 ? "film.fill" : "arrow.down.circle.fill", color: Theme.done, target: .home)
            }
            alert.actionTitle = "Show"
            alert.action = { [weak self] in self?.activities.reveal(last) }
            raise(alert, sound: activitySounds && !Self.editorInFront ? "Glass" : nil)
        }
    }
    /// A video or audio editor is the front app.
    static var editorInFront: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite", "com.apple.FinalCut", "com.lemon.lvoverseas", "com.apple.iMovieApp",
                "com.apple.Compressor", "com.apple.logic10", "com.apple.motionapp"].contains(id) || id.hasPrefix("com.adobe.PremierePro") || id.hasPrefix("com.adobe.AfterEffects")
    }
    private func screenshotTaken(_ url: URL) {
        shelf.add([url])
        let image = NSImage(contentsOf: url)
        let recording = url.lastPathComponent.hasPrefix("Screen Recording")
        var alert = NotchAlert(title: recording ? "Screen recording saved" : "Screenshot saved", subtitle: "On your Shelf · drag it anywhere", symbol: "camera.viewfinder", color: Theme.working, target: .shelf)
        alert.image = image
        alert.fileURL = url
        if let image {
            alert.actionTitle = "Copy"
            alert.action = {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        raise(alert)
    }
    func setLiveActivities(_ enabled: Bool) {
        liveActivities = enabled
        if enabled { activities.start() } else { activities.stop() }
    }
    func setScreenshotDrops(_ enabled: Bool) {
        screenshotDrops = enabled
        if enabled { screenshots.start() } else { screenshots.stop() }
    }
    func setWeather(_ enabled: Bool) {
        weatherEnabled = enabled
        if enabled { weather.start() } else { weather.stop() }
    }
    func setSalah(_ enabled: Bool) {
        salahEnabled = enabled
        if enabled { salah.start() } else { salah.stop() }
    }
    func setClipboard(_ enabled: Bool) {
        clipboardEnabled = enabled
        if enabled { clipboard.start() } else { clipboard.stop(); clipboard.clear() }
    }
    func setHUD(_ enabled: Bool) {
        hudEnabled = enabled
        if enabled { mediaKeys.trusted ? mediaKeys.start() : mediaKeys.requestPermission() } else { mediaKeys.stop() }
    }
    /// Briefly widens the collapsed wings to show a level (volume, brightness, battery).
    func showHUD(_ state: HUDState, seconds: Double = 1.6) {
        guard awake else { return }
        hud = state
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hud = nil
        }
    }
    /// Pastes a clipboard item into the app the user was in.
    func paste(_ item: ClipItem) {
        clipboard.copy(item)
        setMode(.idle)
        guard AXIsProcessTrusted() else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // V
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        }
    }
    func setCalendar(_ enabled: Bool) {
        calendarEnabled = enabled
        if enabled { calendar.start(requestIfNeeded: true) } else { calendar.stop() }
    }

    // MARK: Layout

    var showsMedia: Bool { mediaControls && media.track != nil }
    /// Exam week keeps the hover preview to the countdown, Anki and today's goal.
    var previewSessions: [AgentSession] { examWeek ? [] : Array(active.prefix(showsPreviewMedia ? 1 : 2)) }
    var showsPreviewMedia: Bool { showsMedia && !examWeek }
    var showsPreviewActivities: Bool { liveActivities && !examWeek }
    /// What the hover preview's glance shows: small tiles (next event, exam, Anki,
    /// Claude usage) and the next unread chapter from the exam tracker.
    var glanceTiles: Int {
        guard previewGlance else { return 0 }
        var count = 0
        if !examWeek && calendarEnabled && calendar.next != nil { count += 1 }
        if sheets.primary != nil || (showExams && exams.pinned.map(exams.visible) == true) { count += 1 }
        if anki.stats != nil { count += 1 }
        if !examWeek && usage.fiveHour != nil { count += 1 }
        return count
    }
    var glanceReading: (tracker: SheetTracker.Tracker, item: SheetTracker.Item)? {
        guard previewGlance, let primary = sheets.primaryTracker, let item = primary.summary.pending.first else { return nil }
        return (primary.tracker, item)
    }
    /// Sleeps until `eventLead` minutes before the next calendar event, then drops down
    /// "Cardio lecture in 10 min · Room 1" with Join for online meetings.
    func scheduleEventReminder() {
        eventReminderTask?.cancel()
        guard calendarEnabled, eventLead > 0 else { return }
        let lead = TimeInterval(eventLead * 60), now = Date()
        let key = { (event: UpcomingEvent) in "\(event.title)|\(event.start.timeIntervalSince1970)" }
        guard let event = calendar.events(from: now, to: now.addingTimeInterval(36 * 3600)).first(where: { $0.start > now && !remindedEvents.contains(key($0)) }) else { return }
        eventReminderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, event.start.timeIntervalSinceNow - lead)))
            guard !Task.isCancelled, let self else { return }
            remindedEvents.insert(key(event))
            let minutes = max(1, Int((event.start.timeIntervalSinceNow / 60).rounded()))
            var alert = NotchAlert(title: "\(event.title) in \(minutes) min", subtitle: [event.start.formatted(date: .omitted, time: .shortened), event.location].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                                   symbol: "calendar", color: Theme.working, target: .home)
            if let url = event.joinURL { alert.actionTitle = "Join"; alert.action = { NSWorkspace.shared.open(url) } }
            raise(alert, sound: "Tink")
            scheduleEventReminder()
        }
    }
    /// Every `breakEvery` minutes between 8 AM and 10 PM, if you've used the Mac in the last
    /// five minutes and aren't already on a Pomodoro break: a nudge to drink water and stretch.
    func scheduleBreaks() {
        breakTask?.cancel()
        guard breakEvery > 0 else { return }
        breakTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(60, (self?.breakEvery ?? 60) * 60)))
                guard !Task.isCancelled, let self else { return }
                let hour = Calendar.current.component(.hour, from: Date())
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                guard (8..<22).contains(hour), idle < 300, !timer.isBreak else { continue }
                raise(NotchAlert(title: "Water and a stretch", subtitle: "Stand up, drink some water, rest your eyes for a minute.", symbol: "drop.fill", color: Theme.working, target: .home), sound: "Tink")
            }
        }
    }
    /// The exam pinned to the closed notch, when that's turned on.
    var wingExam: BoardExam? {
        guard showExams, exams.pinToNotch, let exam = exams.pinned, exams.visible(exam) else { return nil }
        return exam
    }
    /// The countdown beside the notch: the exam-week exam, else a pinned Boards exam.
    var wingCountdown: (text: String, color: Color, help: String)? {
        if examWeek, let target = examWeekTarget {
            let days = BoardsMath.calendarDays(from: Date(), to: target.date)
            return (days == 0 ? "Today" : "\(days)d", days <= 2 ? Theme.failed : Theme.attention, "\(target.name): \(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")")
        }
        guard let exam = wingExam else { return nil }
        let urgency = exams.urgency(exam)
        return (exams.compact(exam), urgency == Theme.primary ? Theme.secondary : urgency, "\(exam.name): \(exams.compact(exam))")
    }

    // MARK: Exam week

    /// The soonest exam within the next 7 days: the current tracker's exam or a Boards exam.
    var examWeekTarget: (key: String, name: String, date: Date)? {
        let now = Date(), today = Calendar.current.startOfDay(for: now)
        var options: [(key: String, name: String, date: Date)] = []
        if let (_, summary) = sheets.primaryTracker, let date = summary.examDate, date >= today {
            options.append(("tracker:\(summary.title)|\(WeakTopics.dayKey(date))", summary.shortName, date))
        }
        if showExams { options += exams.upcoming.filter { !$0.logged }.map { ("exam:\($0.id.uuidString)", $0.shortName, $0.date) } }
        return options.filter { BoardsMath.calendarDays(from: now, to: $0.date) <= 7 }.min { $0.date < $1.date }
    }
    func updateExamWeek() {
        let target = autoExamWeek ? examWeekTarget : nil
        func apply(_ on: Bool) { applyingExamWeek = true; examWeek = on; applyingExamWeek = false }
        if let target {
            guard !examWeek, examWeekDismissed != target.key else { return }
            apply(true)
            examWeekAutoKey = target.key
            let days = BoardsMath.calendarDays(from: Date(), to: target.date)
            raise(NotchAlert(title: "Exam week is on", subtitle: "\(target.name) \(days == 0 ? "is today" : days == 1 ? "is tomorrow" : "in \(days) days"). The notch stays quiet until it's over.", symbol: "moon.fill", color: Theme.attention, target: .home,
                             actionTitle: "Turn off", action: { [weak self] in self?.examWeek = false; self?.alert = nil }), sound: "Glass")
        } else if examWeek, !examWeekAutoKey.isEmpty {
            apply(false)
            examWeekAutoKey = ""
        }
    }

    // MARK: Question blocks and weak spots

    /// Logs a finished block: misses by subject and, if asked, the questions to the bank.
    func saveBlock(_ result: QuestionBlock.Result, misses: [String: Int], logToBank: Bool) {
        weakTopics.log(misses)
        if logToBank, let exam = exams.pinned, exam.bankTotal != nil { exams.logQuestions(result.answered, for: exam) }
        else if result.answered > 0 { activity.add("questions", result.answered) }
        block.result = nil
    }
    /// Opens Ask AI on a quiz about the given subjects, in Gemini when it's turned on.
    func quiz(on subjects: [String]) {
        guard !subjects.isEmpty else { return }
        if assistant.enabled.contains(.gemini) { assistant.provider = .gemini }
        assistant.prompt = WeakTopics.quizPrompt(subjects)
        open(.assistant)
        assistant.askHere()
    }

    // MARK: Lecture day

    /// At 8 PM, if there are classes tomorrow: "Tomorrow: 3 classes, 2 pre-reads".
    func scheduleLectureSummary() {
        lectureTask?.cancel()
        lectureTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date(), calendar = Calendar.current
                var at = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
                if at <= now { at = calendar.date(byAdding: .day, value: 1, to: at) ?? now.addingTimeInterval(86400) }
                try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow + 1))
                guard !Task.isCancelled, let self else { return }
                self.announceTomorrow()
            }
        }
    }
    func announceTomorrow() {
        // Only in the evening: a Mac waking at 2 AM shouldn't announce the wrong "tomorrow".
        guard lectures.enabled, lectures.nightSummary, calendarEnabled, (18..<24).contains(Calendar.current.component(.hour, from: Date())),
              let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return }
        let classes = lectures.classes(on: tomorrow, from: calendar)
        guard let first = classes.first else { return }
        let preReads = classes.filter { $0.preRead != nil && !lectures.isDone($0) }.count + (glanceReading != nil ? 1 : 0)
        let noun = classes.count == 1 ? "class" : "classes"
        raise(NotchAlert(title: "Tomorrow: \(classes.count) \(noun)" + (preReads > 0 ? ", \(preReads) pre-read\(preReads == 1 ? "" : "s")" : ""),
                         subtitle: "First at \(first.start.formatted(date: .omitted, time: .shortened)) · \(first.title)", symbol: "books.vertical.fill", color: Theme.working, target: .home,
                         actionTitle: "Show", action: { [weak self] in self?.open(.home) }), sound: "Tink")
    }
    /// Converts a Shelf file (to JPG, a smaller PDF or a smaller video) and shelves the result.
    func convert(_ url: URL, to kind: FileConverter.Kind) {
        raise(NotchAlert(title: "Converting…", subtitle: url.lastPathComponent, symbol: kind.symbol, color: Theme.working, target: .shelf))
        Task {
            do {
                let output = try await FileConverter.convert(url, to: kind)
                shelf.add([output])
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                raise(NotchAlert(title: "Ready: \(output.lastPathComponent)", subtitle: "\(size) · on your Shelf, next to the original", symbol: "checkmark.circle.fill", color: Theme.done, target: .shelf, fileURL: output), sound: "Glass")
            } catch {
                raise(NotchAlert(title: "Couldn't convert", subtitle: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf))
            }
        }
    }
    /// Copies the text in a Shelf image to the clipboard.
    func copyText(from url: URL) {
        Task {
            do {
                let text = try await FileConverter.recognizeText(in: url)
                guard !text.isEmpty else { raise(NotchAlert(title: "No text found", subtitle: url.lastPathComponent, symbol: "text.viewfinder", color: Theme.attention, target: .shelf)); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let words = text.split(whereSeparator: \.isWhitespace).count
                raise(NotchAlert(title: "Copied \(words) word\(words == 1 ? "" : "s")", subtitle: text.replacingOccurrences(of: "\n", with: " "), symbol: "text.viewfinder", color: Theme.done, target: .shelf), sound: "Tink")
            } catch {
                raise(NotchAlert(title: "Couldn't read the text", subtitle: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf))
            }
        }
    }
    /// Makes one PDF from the photos and screenshots on the Shelf, in Shelf order.
    func shelfImagesToPDF() {
        let images = shelf.items.map(\.url).filter(FileConverter.isImage)
        do {
            let output = try FileConverter.imagesToPDF(images)
            shelf.add([output])
            raise(NotchAlert(title: "Made a PDF from \(images.count) image\(images.count == 1 ? "" : "s")", subtitle: "\(output.lastPathComponent) · on your Shelf", symbol: "doc.richtext.fill", color: Theme.done, target: .shelf, fileURL: output), sound: "Glass")
        } catch {
            raise(NotchAlert(title: "Couldn't make the PDF", subtitle: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf))
        }
    }
    /// Sends a PDF to Zotero.
    func addToZotero(_ url: URL) {
        raise(NotchAlert(title: "Adding to Zotero…", subtitle: url.lastPathComponent, symbol: "books.vertical.fill", color: Theme.working, target: .shelf))
        Task {
            do {
                try await ZoteroImporter.add(url)
                raise(NotchAlert(title: "Added to Zotero", subtitle: "Zotero is looking up the paper's details", symbol: "books.vertical.fill", color: Theme.done, target: .shelf), sound: "Glass")
            } catch {
                raise(NotchAlert(title: "Couldn't add to Zotero", subtitle: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf))
            }
        }
    }
    /// Merges the PDFs on the Shelf, in Shelf order, and shelves the result.
    func mergeShelfPDFs() {
        let pdfs = shelf.items.map(\.url).filter(FileConverter.isPDF)
        do {
            let output = try FileConverter.merge(pdfs)
            shelf.add([output])
            let pages = PDFDocument(url: output)?.pageCount ?? 0
            raise(NotchAlert(title: "Merged \(pdfs.count) PDFs", subtitle: "\(output.lastPathComponent) · \(pages) pages · on your Shelf", symbol: "doc.on.doc.fill", color: Theme.done, target: .shelf, fileURL: output), sound: "Glass")
        } catch {
            raise(NotchAlert(title: "Couldn't merge", subtitle: error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: Theme.attention, target: .shelf))
        }
    }
    /// Saves a countdown card image, puts it on the Shelf and the clipboard.
    func shareExam(_ exam: BoardExam) {
        let (value, label) = exams.countdown(exam)
        guard let file = BoardsShareCard.render(exam, value: value, label: label) else { error = "Couldn't make the countdown card."; return }
        shelf.add([file])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file as NSURL])
        if let image = NSImage(contentsOf: file) { NSPasteboard.general.writeObjects([image]) }
        raise(NotchAlert(title: "Countdown card ready", subtitle: "On your Shelf and clipboard · Pictures › Attending", symbol: "photo.fill", color: Theme.done, target: .shelf, image: NSImage(contentsOf: file), fileURL: file), sound: "Glass")
    }
    /// Width of each wing beside the notch. Both wings match so the island stays centered.
    var idleWing: CGFloat {
        if let hud { return hud.kind == .headphones ? 132 : 96 }
        if let meeting = calendar.imminent { return max(34, 20 + 66 + (meeting.joinURL != nil ? 26 : 0) + (active.isEmpty ? 0 : 18)) }
        var items: [CGFloat] = []
        if showsMedia && media.track?.playing == true { items.append(12) }
        if timer.isActive { items.append(36) }
        if !active.isEmpty { items.append(12) }
        if meeting.micInUse { items.append(14) }
        if meeting.cameraInUse { items.append(14) }
        if liveActivities && !activities.running.isEmpty { items.append(14) }
        if block.running { items.append(34) }
        if let countdown = wingCountdown { items.append(CGFloat(countdown.text.count) * 6.5 + 4) }
        let content = items.reduce(0, +) + CGFloat(max(0, items.count - 1)) * 6
        return max(34, content + 20)
    }
    /// Total panel size including the band hidden behind the hardware notch.
    var panelSize: CGSize {
        let band = notchHeight > 0 ? notchHeight : 34
        switch mode {
        case .idle: return CGSize(width: 2 * idleWing + notchWidth, height: band)
        case .preview:
            var height: CGFloat = 20
            if dragActive { return CGSize(width: max(480, notchWidth + 250), height: band + 118) }
            if alert != nil { height += 58 }
            else {
                if showsPreviewActivities { height += CGFloat(min(activities.visible.count, 2)) * 50 }
                if showsPreviewMedia { height += 82 }
                let glance = (glanceTiles > 0 ? 54 : 0) + (glanceReading != nil ? 38 : 0)
                let sessions = previewSessions.count
                height += sessions == 0 && !showsPreviewMedia && glance == 0 && !block.running ? 44 : CGFloat(sessions) * 46
                height += CGFloat(glance)
                if timer.isActive { height += 40 }
                if block.running { height += 40 }
            }
            // Each side of the notch fits about 130 pt: the prayer chip and chevron on the right.
            return CGSize(width: max(glanceTiles >= 4 ? 480 : 440, notchWidth + 320), height: band + height)
        case .expanded:
            // One height for every tab, sized to Home's content: switching tabs never
            // resizes the window, so nothing behind the island can flash through.
            // Other tabs scroll within it.
            return CGSize(width: max(680, notchWidth + 440), height: band + 24 + min(540, max(400, homeHeight)))
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Login registration: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
}

// Dedicated queue plus kernel directory notifications: no idle polling or main-thread I/O.
final class EventWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "attending.events", qos: .utility)
    private let source: DispatchSourceFileSystemObject
    private let directory: URL
    private let callback: @Sendable ([AgentEvent]) -> Void
    init(directory: URL, callback: @escaping @Sendable ([AgentEvent]) -> Void) throws {
        self.directory = directory; self.callback = callback
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        queue.async { [weak self] in self?.drain() }
    }
    deinit { source.cancel() }
    private func drain() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
        var events: [AgentEvent] = []
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 16_384 else { continue }
            if let data = try? Data(contentsOf: file), let event = try? JSONDecoder().decode(AgentEvent.self, from: data), event.validate() { events.append(event) }
            try? FileManager.default.removeItem(at: file)
        }
        if !events.isEmpty { callback(events) }
    }
}

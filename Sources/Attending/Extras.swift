import AppKit
import AttendingCore
import EventKit
import UniformTypeIdentifiers

// MARK: - Calendar

struct UpcomingEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var calendarColor: NSColor?
    var joinURL: URL?
    var location: String?
    var notes: String? = nil
    var calendarTitle: String? = nil
}

/// A calendar read from its private iCal (.ics) address, such as Google Calendar's
/// "Secret address in iCal format" or Outlook's published calendar link.
struct CalendarFeed: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var name: String
    var updated: Date?
    var problem: String?
}

/// Upcoming events from the Mac's calendar accounts (iCloud, and Google or Outlook
/// accounts added in Internet Accounts) plus any calendar links. EventKit access is
/// requested only when the user turns the feature on; it refreshes on EventKit change
/// notifications, and links are re-read every 15 minutes.
@MainActor final class CalendarService: ObservableObject {
    @Published private(set) var next: UpcomingEvent?
    /// Replaces event titles, for screenshots and videos that shouldn't show the real ones.
    var titleOverride: String?
    /// The next event from 5 minutes before it starts until 5 minutes after (or its end).
    @Published private(set) var imminent: UpcomingEvent?
    var onImminent: ((UpcomingEvent) -> Void)?
    /// Called when an upcoming event changes, for lecture reminders.
    var onChange: (() -> Void)?
    private var imminentTask: Task<Void, Never>?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    /// Event calendars by name, for picking which one holds classes.
    var calendarNames: [String] {
        var names = authorized ? store.calendars(for: .event).map(\.title) : []
        names += feeds.map(\.name)
        return Array(Set(names)).sorted()
    }
    /// Calendar accounts on this Mac that have event calendars ("iCloud", "Google" and so on).
    @Published private(set) var accounts: [String] = []
    @Published private(set) var feeds: [CalendarFeed] = []
    private var parsed: [UUID: ICSCalendar] = [:]
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var feedTimer: Timer?
    private var running = false
    // Calendar links carry a private token, so they live in a file only this user can read.
    private let feedsURL = AppPaths.directory.appendingPathComponent("calendars.json")

    func start(requestIfNeeded: Bool) {
        running = true
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
        loadFeeds()
        if authorized { begin() }
        else if requestIfNeeded && status == .notDetermined { requestAccess() }
        if !feeds.isEmpty { fetchFeeds() }
        feedTimer?.invalidate()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.fetchFeeds() } }
    }
    func stop() { running = false; feedTimer?.invalidate(); feedTimer = nil; next = nil; imminent = nil }
    func requestAccess() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            authorized = granted; denied = !granted
            if granted { begin() }
        }
    }
    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    /// Google and Microsoft sign in through macOS, so Attending never handles the password.
    func openInternetAccounts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }
    private func begin() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.store.refreshSourcesIfNecessary(); self?.refresh() }
            }
        }
        refresh()
    }

    /// Events (not all-day, not cancelled) overlapping the window, from every source.
    func events(from: Date, to: Date) -> [UpcomingEvent] {
        var events: [UpcomingEvent] = []
        if authorized {
            events += store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
                .filter { !$0.isAllDay && $0.status != .canceled }
                .map { UpcomingEvent(title: titleOverride ?? $0.title ?? "Event", start: $0.startDate, end: $0.endDate, calendarColor: $0.calendar.color,
                                     joinURL: Self.joinLink(in: [$0.url?.absoluteString, $0.location, $0.notes]), location: $0.location,
                                     notes: $0.notes, calendarTitle: $0.calendar.title) }
        }
        for (id, calendar) in parsed {
            let name = feeds.first { $0.id == id }?.name
            events += calendar.occurrences(from: from, to: to).filter { !$0.event.allDay }.map {
                UpcomingEvent(title: titleOverride ?? $0.event.title, start: $0.start, end: $0.end, calendarColor: nil,
                              joinURL: Self.joinLink(in: [$0.event.url, $0.event.location, $0.event.notes]), location: $0.event.location,
                              notes: $0.event.notes, calendarTitle: name)
            }
        }
        // The same event can come from an account and a link; keep one.
        var seen = Set<String>()
        return events.sorted { $0.start < $1.start }.filter { seen.insert("\($0.title)|\($0.start.timeIntervalSince1970)").inserted }
    }

    func refresh() {
        guard running, authorized || !parsed.isEmpty else { next = nil; scheduleCountdown(); return }
        let now = Date()
        if authorized {
            accounts = Array(Set(store.calendars(for: .event).map { $0.source.title })).sorted()
        }
        next = events(from: now, to: now.addingTimeInterval(36 * 3600)).first { $0.end > now }
        scheduleCountdown()
        onChange?()
        // Re-evaluate when the current event ends instead of polling.
        refreshTask?.cancel()
        if let end = next?.end {
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: Calendar links

    /// Adds a calendar link (https or webcal) after checking that it reads as a calendar.
    func addFeed(_ text: String, name: String? = nil) async -> String? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.lowercased().hasPrefix("webcal://") { link = "https://" + link.dropFirst("webcal://".count) }
        guard let url = URL(string: link), url.scheme?.lowercased() == "https" else { return "Paste the calendar's iCal link. It starts with https:// or webcal://." }
        guard !feeds.contains(where: { $0.url == link }) else { return "That calendar is already added." }
        switch await Self.download(url) {
        case .failure(let message): return message
        case .success(let calendar):
            let feed = CalendarFeed(url: link, name: name ?? calendar.name ?? url.host ?? "Calendar", updated: Date())
            feeds.append(feed); parsed[feed.id] = calendar
            saveFeeds(); refresh()
            return nil
        }
    }
    func removeFeed(_ feed: CalendarFeed) {
        feeds.removeAll { $0.id == feed.id }; parsed[feed.id] = nil
        saveFeeds(); refresh()
    }
    func fetchFeeds() {
        for feed in feeds {
            guard let url = URL(string: feed.url) else { continue }
            Task {
                let result = await Self.download(url)
                guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
                switch result {
                case .success(let calendar): parsed[feed.id] = calendar; feeds[index].updated = Date(); feeds[index].problem = nil
                case .failure(let message): feeds[index].problem = message
                }
                saveFeeds(); refresh()
            }
        }
    }
    private enum Download { case success(ICSCalendar), failure(String) }
    private static func download(_ url: URL) async -> Download {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Attending", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .failure("Couldn't reach the calendar. Check your connection.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failure(status == 404 || status == 401 || status == 403 ? "The link was rejected. It may have been reset; copy it again." : "The calendar returned an error (\(status)).") }
        guard data.count < 20_000_000, let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else { return .failure("That link isn't an iCal calendar. Use the iCal (.ics) address.") }
        return .success(ICSCalendar.parse(text))
    }
    private func loadFeeds() {
        guard feeds.isEmpty, let data = try? Data(contentsOf: feedsURL), let saved = try? JSONDecoder().decode([CalendarFeed].self, from: data) else { return }
        feeds = saved
    }
    private func saveFeeds() {
        try? FileManager.default.createDirectory(at: AppPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        try? data.write(to: feedsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: feedsURL.path)
    }

    /// Shows the countdown window with two timers (show, hide) rather than polling.
    private func scheduleCountdown() {
        imminentTask?.cancel()
        guard let event = next else { imminent = nil; return }
        let showAt = event.start.addingTimeInterval(-300)
        let hideAt = min(event.end, event.start.addingTimeInterval(300))
        let now = Date()
        if now >= showAt && now < hideAt { if imminent != event { imminent = event } } else { imminent = nil }
        imminentTask = Task { [weak self] in
            if showAt > Date() {
                try? await Task.sleep(for: .seconds(showAt.timeIntervalSinceNow))
                guard !Task.isCancelled, let self else { return }
                self.imminent = event
                self.onImminent?(event)
            }
            try? await Task.sleep(for: .seconds(max(0, hideAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.imminent = nil
        }
    }
    private static func joinLink(in fields: [String?]) -> URL? {
        let text = fields.compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(zoom\.us/j|zoom\.us/my|meet\.google\.com|teams\.microsoft\.com/l/meetup-join|teams\.live\.com|webex\.com)[^\s<>"]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

// MARK: - Focus timer and study sessions

@MainActor final class FocusTimer: ObservableObject {
    enum Phase: String { case focus, shortBreak, longBreak
        var title: String { switch self { case .focus: "Focus"; case .shortBreak: "Break"; case .longBreak: "Long break" } }
    }
    /// A Pomodoro study session: focus/break cycles, optionally ending at an Anki review goal.
    struct Session: Equatable {
        var focusMinutes: Double
        var breakMinutes: Double
        var longBreakMinutes: Double
        var cycles = 4
        var cycle = 1
        var phase: Phase = .focus
        var reviewGoal: Int?
        var reviewBaseline: Int?
        var reviewsDone = 0
        var startedAt = Date()
        var goalProgress: Double? { reviewGoal.map { min(1, Double(reviewsDone) / Double(max(1, $0))) } }
    }
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var session: Session?
    @Published var label = "Focus"
    var onFinish: (() -> Void)?
    var onPhaseChange: ((Session) -> Void)?
    var onSessionComplete: ((Session) -> Void)?
    /// Minutes of focus when a focus stretch ends (finished, skipped or stopped).
    var onFocusMinutes: ((Double) -> Void)?
    private var focusStarted: Date?
    private var finishTask: Task<Void, Never>?

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isBreak: Bool { session.map { $0.phase != .focus } ?? false }
    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? total
    }
    func progress(at date: Date = Date()) -> Double { total > 0 ? 1 - remaining(at: date) / total : 0 }

    func start(minutes: Double, label: String = "Focus") {
        session = nil
        begin(minutes: minutes, label: label)
    }
    func startSession(focus: Double, breakMinutes: Double, longBreak: Double, reviewGoal: Int?, reviewBaseline: Int?) {
        session = Session(focusMinutes: focus, breakMinutes: breakMinutes, longBreakMinutes: longBreak, reviewGoal: reviewGoal, reviewBaseline: reviewBaseline)
        begin(minutes: focus, label: "Focus 1 of 4")
    }
    /// Reports Anki's reviews-today count; completes the session at the goal.
    func updateReviews(today: Int) {
        guard var current = session, let baseline = current.reviewBaseline else { return }
        current.reviewsDone = max(0, today - baseline)
        session = current
        if let goal = current.reviewGoal, current.reviewsDone >= goal { complete() }
    }
    /// Sets the review baseline when Anki's count wasn't known at session start.
    func startSessionBaseline(_ today: Int) { session?.reviewBaseline = today }
    func skipPhase() { if session != nil { advance() } else { cancel() } }
    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil; finishTask?.cancel()
    }
    func resume() {
        guard let pausedRemaining else { return }
        self.pausedRemaining = nil
        schedule(endDate: Date().addingTimeInterval(pausedRemaining))
    }
    func add(minutes: Double) {
        total += minutes * 60
        if let endDate { schedule(endDate: endDate.addingTimeInterval(minutes * 60)) }
        else if let pausedRemaining { self.pausedRemaining = pausedRemaining + minutes * 60 }
    }
    func cancel() { endFocus(); endDate = nil; pausedRemaining = nil; session = nil; finishTask?.cancel() }

    private func endFocus() {
        if let start = focusStarted { onFocusMinutes?(Date().timeIntervalSince(start) / 60) }
        focusStarted = nil
    }
    private func begin(minutes: Double, label: String) {
        endFocus()
        if session == nil || session?.phase == .focus { focusStarted = Date() }
        total = minutes * 60; self.label = label; pausedRemaining = nil
        schedule(endDate: Date().addingTimeInterval(total))
    }
    private func complete() {
        guard let finished = session else { return }
        endFocus()
        endDate = nil; pausedRemaining = nil; session = nil; finishTask?.cancel()
        onSessionComplete?(finished)
    }
    private func advance() {
        guard var current = session else { return }
        switch current.phase {
        case .focus:
            current.phase = current.cycle >= current.cycles ? .longBreak : .shortBreak
        case .shortBreak:
            current.phase = .focus; current.cycle += 1
        case .longBreak:
            // A full set of cycles ends the session unless a review goal is still open.
            if current.reviewGoal == nil || current.reviewsDone >= current.reviewGoal! { session = current; complete(); return }
            current.phase = .focus; current.cycle = 1
        }
        session = current
        let minutes = current.phase == .focus ? current.focusMinutes : current.phase == .shortBreak ? current.breakMinutes : current.longBreakMinutes
        begin(minutes: minutes, label: current.phase == .focus ? "Focus \(current.cycle) of \(current.cycles)" : current.phase.title)
        onPhaseChange?(current)
    }
    private func schedule(endDate: Date) {
        self.endDate = endDate
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endDate.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if session != nil { advance(); return }
            endFocus()
            self.endDate = nil; self.pausedRemaining = nil
            self.onFinish?()
        }
    }
    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - File shelf

struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Temporary parking spot for files. Stores references (paths), never copies, so
/// the shelf never duplicates or moves anything on disk.
/// Sends files with AirDrop and reports back once they're sent. The AirDrop window is
/// a system window, so it needs Attending to be the active app to take focus.
@MainActor final class AirDropSender: NSObject, NSSharingServiceDelegate {
    /// The system's own AirDrop icon.
    static var icon: NSImage? { NSSharingService(named: .sendViaAirDrop)?.image }
    var onSent: (([URL]) -> Void)?
    var onFailed: ((String) -> Void)?
    private var service: NSSharingService?

    func canSend(_ urls: [URL]) -> Bool { NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: urls) ?? false }
    func send(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            onFailed?("AirDrop isn't available. Check that Wi-Fi and Bluetooth are on.")
            return
        }
        service.delegate = self
        self.service = service
        NSApp.activate()
        service.perform(withItems: urls)
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let urls = items.compactMap { $0 as? URL }
        MainActor.assumeIsolated { onSent?(urls); service = nil }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            if !cancelled { onFailed?(message) }
            service = nil
        }
    }
}

@MainActor final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    private let key = "shelfItems"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(where: { $0.path == url.path }) {
            items.insert(ShelfItem(path: url.path), at: 0)
        }
        if items.count > 40 { items.removeLast(items.count - 40) }
        save()
    }
    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id }; save() }
    func clear() { items.removeAll(); save() }
    func pruneMissing() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if kept != items { items = kept; save() }
    }
    func icon(for item: ShelfItem) -> NSImage { NSWorkspace.shared.icon(forFile: item.path) }
    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key) }

    /// Extracts file URLs from a SwiftUI drop.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(collected.urls) } }
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

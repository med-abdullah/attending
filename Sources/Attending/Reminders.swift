import AppKit
import EventKit
import SwiftUI

/// Apple Reminders through EventKit: what's due today (and overdue), what's coming up,
/// a check to complete one and a field to add one. Asked for only when turned on;
/// refreshes when Reminders changes. Nothing leaves the Mac.
@MainActor final class RemindersService: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var due: Date?
        var hasTime: Bool
        var list: String
        var color: NSColor?
        var flagged: Bool
        var overdue: Bool { due.map { hasTime ? $0 < Date() : Calendar.current.startOfDay(for: $0) < Calendar.current.startOfDay(for: Date()) } ?? false }
        var today: Bool { due.map { Calendar.current.isDateInToday($0) } ?? false }
    }

    @Published var enabled = UserDefaults.standard.bool(forKey: "remindersEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "remindersEnabled"); enabled ? start() : stop() }
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @Published private(set) var denied = [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder))
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var demo = false

    /// Due today or earlier, soonest first.
    var dueNow: [Item] { items.filter { $0.overdue || $0.today } }
    /// Dated after today, then undated flagged ones.
    var upcoming: [Item] { items.filter { !($0.overdue || $0.today) && ($0.due != nil || $0.flagged) } }

    func start() {
        guard enabled, !demo else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            Task {
                let granted = (try? await store.requestFullAccessToReminders()) ?? false
                authorized = granted; denied = !granted
                refresh()
            }
        } else {
            authorized = status == .fullAccess; denied = !authorized
            refresh()
        }
    }
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if !demo { items = [] }
    }

    func refresh() {
        guard enabled, authorized, !demo else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let items = (reminders ?? []).map { reminder -> Item in
                let components = reminder.dueDateComponents
                return Item(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", due: components?.date ?? components.flatMap { Calendar.current.date(from: $0) },
                            hasTime: components?.hour != nil, list: reminder.calendar?.title ?? "", color: reminder.calendar?.color, flagged: reminder.priority == 1)
            }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.flagged && !b.flagged
                }
            }
            Task { @MainActor in self?.items = items }
        }
    }

    /// Checks a reminder off in Reminders itself.
    func complete(_ item: Item) {
        items.removeAll { $0.id == item.id }
        guard !demo, let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
    }
    /// Adds a reminder to the default list, due today if asked.
    func add(_ title: String, today: Bool) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, authorized, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        if today { reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date()) }
        try? store.save(reminder, commit: true)
        refresh()
    }
    func openReminders() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
    func showDemo(_ sample: [Item]) { demo = true; items = sample }
}

/// Home: today's reminders (overdue in orange), the next few coming up, and a quick add.
struct RemindersCard: View {
    @ObservedObject var reminders: RemindersService
    /// Video captures leave out the add field (offscreen rendering can't draw text fields).
    var showsAdd = true
    @State private var draft = ""
    @State private var done: Set<String> = []
    var body: some View {
        if reminders.enabled {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        SectionLabel(text: "Reminders")
                        if !reminders.dueNow.isEmpty { Text("\(reminders.dueNow.count) today").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                        Spacer()
                        Button("Open") { reminders.openReminders() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                    if reminders.denied {
                        Text("Reminders access is off. Allow Attending in System Settings › Privacy & Security › Reminders.").font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        let shown = Array((reminders.dueNow + reminders.upcoming).prefix(5))
                        if shown.isEmpty { Text("Nothing due. Nice.").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary) }
                        ForEach(shown) { item in row(item) }
                        if showsAdd { TextField("Add a reminder for today", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                            .onSubmit { reminders.add(draft, today: true); draft = "" } }
                    }
                }
            }
        }
    }
    private func row(_ item: RemindersService.Item) -> some View {
        let checked = done.contains(item.id)
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { _ = done.insert(item.id) }
            Task { try? await Task.sleep(for: .milliseconds(600)); reminders.complete(item); done.remove(item.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                    .foregroundStyle(checked ? Theme.done : item.color.map(Color.init(nsColor:)) ?? Theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(checked ? Theme.tertiary : Theme.primary).strikethrough(checked).lineLimit(1)
                Spacer(minLength: 4)
                if item.flagged { Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Theme.attention) }
                if let due = item.due { Text(Self.when(due, hasTime: item.hasTime)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(item.overdue ? Theme.attention : Theme.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(checked ? "Done" : "Mark as done in Reminders")
    }
    static func when(_ date: Date, hasTime: Bool) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return hasTime ? date.formatted(date: .omitted, time: .shortened) : "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

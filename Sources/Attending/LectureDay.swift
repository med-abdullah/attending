import SwiftUI
import AttendingCore

/// Classes from the calendar: today's (checked off as each one ends) or, once they're
/// over, tomorrow's with any pre-reads found in the event notes. The night before, the
/// notch sums up tomorrow: "3 lectures, 2 pre-reads".
@MainActor final class LectureDay: ObservableObject {
    struct Class: Identifiable, Equatable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var location: String?
        /// The line in the event's notes that asks for reading or prep, if any.
        var preRead: String?
    }

    @Published var enabled = UserDefaults.standard.object(forKey: "lectureDay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "lectureDay") }
    }
    @Published var nightSummary = UserDefaults.standard.object(forKey: "lectureSummary") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nightSummary, forKey: "lectureSummary") }
    }
    /// The calendar that holds classes; empty means any calendar, by title.
    @Published var calendarName = UserDefaults.standard.string(forKey: "lectureCalendar") ?? "" {
        didSet { UserDefaults.standard.set(calendarName, forKey: "lectureCalendar") }
    }
    @Published private(set) var donePreReads = Set(UserDefaults.standard.stringArray(forKey: "preReadsDone") ?? [])

    static let keywords = ["lecture", "class", "lab", "pbl", "tbl", "cbl", "didactic", "seminar", "small group", "workshop", "osce", "omm", "opp", "anatomy",
                           "physiology", "pathology", "pharmacology", "microbiology", "biochem", "histology", "immunology", "clinical skills", "doctoring", "review session"]

    /// Each keyword at the start of a word ("Labs" yes, "Collab" no).
    private static let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")"

    func isClass(_ event: UpcomingEvent) -> Bool {
        if !calendarName.isEmpty { return event.calendarTitle == calendarName }
        return event.title.range(of: Self.keywordPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func classes(on day: Date, from calendar: CalendarService) -> [Class] {
        if let demo { return demo.filter { Calendar.current.isDate($0.start, inSameDayAs: day) } }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return calendar.events(from: start, to: end).filter { $0.start >= start && isClass($0) }.map {
            Class(id: "\($0.title)|\(Int($0.start.timeIntervalSince1970))", title: $0.title, start: $0.start, end: $0.end,
                  location: $0.location, preRead: Self.preRead(in: $0.notes))
        }
    }

    /// Which day to show: today until its last class ends, then tomorrow.
    func shownDay(from calendar: CalendarService, now: Date = Date()) -> (day: Date, classes: [Class])? {
        guard enabled else { return nil }
        let today = classes(on: now, from: calendar)
        if let last = today.last, last.end > now { return (now, today) }
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return nil }
        let next = classes(on: tomorrow, from: calendar)
        return next.isEmpty ? nil : (tomorrow, next)
    }

    /// For screenshots: sample classes that replace the calendar's.
    private var demo: [Class]?
    func showDemo(_ classes: [Class]) { demo = classes; objectWillChange.send() }

    func isDone(_ item: Class) -> Bool { donePreReads.contains(item.id) }
    func togglePreRead(_ item: Class) {
        if donePreReads.contains(item.id) { donePreReads.remove(item.id) } else { donePreReads.insert(item.id) }
        // Keys end in the class's start time; drop ones more than two weeks old.
        let cutoff = Int(Date().timeIntervalSince1970) - 14 * 86400
        donePreReads = donePreReads.filter { Int($0.split(separator: "|").last ?? "") ?? 0 > cutoff }
        UserDefaults.standard.set(Array(donePreReads), forKey: "preReadsDone")
    }

    /// The first line of the notes that asks for reading, watching or prep before class.
    nonisolated static func preRead(in notes: String?) -> String? {
        guard let notes, !notes.isEmpty else { return nil }
        let pattern = #"(?i)\b(pre-?reads?|pre-?class|pre-?work|prep(are)?|before class|reading|read (ch|chapter|pages?|pp)|assigned|assignment|watch|module|due)\b"#
        for line in notes.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.range(of: pattern, options: .regularExpression) != nil else { continue }
            // Links alone say nothing; keep the words.
            let words = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !words.isEmpty else { continue }
            return words.count > 90 ? String(words.prefix(88)) + "…" : words
        }
        return nil
    }
}

/// Today's or tomorrow's classes inside the Today card.
struct ClassesSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var lectures: LectureDay
    @ObservedObject var calendar: CalendarService
    @ObservedObject var sheets: SheetTracker
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let (day, classes) = lectures.shownDay(from: calendar, now: context.date) {
                let today = Calendar.current.isDate(day, inSameDayAs: context.date)
                let reading = model.glanceReading
                let preReads = classes.filter { $0.preRead != nil && !lectures.isDone($0) }.count + (reading != nil ? 1 : 0)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        SectionLabel(text: today ? "Today" : "Tomorrow")
                        Text(header(classes, today: today, now: context.date, preReads: preReads)).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    ForEach(classes.prefix(4)) { item in
                        let over = item.end <= context.date
                        HStack(spacing: 7) {
                            Image(systemName: over ? "checkmark.circle.fill" : item.start <= context.date ? "circle.lefthalf.filled" : "circle")
                                .font(.system(size: 11)).foregroundStyle(over ? Theme.done : item.start <= context.date ? Theme.working : Theme.tertiary)
                            Text(item.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                                .frame(width: 52, alignment: .leading)
                            Text(item.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(over ? Theme.tertiary : Theme.primary).strikethrough(over).lineLimit(1)
                        }
                        if let note = item.preRead, !over { preReadRow(note, done: lectures.isDone(item)) { lectures.togglePreRead(item) } }
                    }
                    if classes.count > 4 { Text("+\(classes.count - 4) more").font(.system(size: 10)).foregroundStyle(Theme.tertiary).padding(.leading, 18) }
                    if let reading { preReadRow("Reading: \(reading.item.label)", done: false) { sheets.toggle(reading.tracker, reading.item) } }
                }
            }
        }
    }
    private func header(_ classes: [LectureDay.Class], today: Bool, now: Date, preReads: Int) -> String {
        let noun = classes.count == 1 ? "class" : "classes"
        if today { return "\(classes.filter { $0.end <= now }.count) of \(classes.count) \(noun) done" }
        return "\(classes.count) \(noun)" + (preReads > 0 ? " · \(preReads) pre-read\(preReads == 1 ? "" : "s")" : "")
    }
    private func preReadRow(_ text: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 10)).foregroundStyle(done ? Theme.done : Theme.attention)
                Text(text).font(.system(size: 10.5)).foregroundStyle(done ? Theme.tertiary : Theme.secondary).strikethrough(done).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(done ? "Mark as not done" : "Mark as done")
    }
}

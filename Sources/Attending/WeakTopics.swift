import SwiftUI

/// Questions missed, by subject: tagged after a question block (or any time) and kept
/// for 90 days on this Mac. The Study tab shows the week's three weakest subjects, and
/// Ask AI can quiz you on them.
@MainActor final class WeakTopics: ObservableObject {
    struct Miss: Codable, Equatable {
        var day: String
        var subject: String
        var count: Int
    }
    static let subjects = ["Cardio", "Pulm", "Renal", "GI", "Endo", "Repro", "MSK", "Neuro", "Psych", "Heme/Onc", "Immuno", "Micro",
                           "Pharm", "Biochem", "Genetics", "Derm", "Anatomy", "Biostats", "Ethics", "OMM"]

    @Published private(set) var misses: [Miss] = {
        guard let data = UserDefaults.standard.data(forKey: "weakTopics"), let saved = try? JSONDecoder().decode([Miss].self, from: data) else { return [] }
        return saved
    }()
    private var demo = false

    func log(_ counts: [String: Int], on date: Date = Date()) {
        let day = Self.dayKey(date)
        for (subject, count) in counts where count > 0 {
            if let index = misses.firstIndex(where: { $0.day == day && $0.subject == subject }) { misses[index].count += count }
            else { misses.append(Miss(day: day, subject: subject, count: count)) }
        }
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -90, to: date) ?? date)
        misses.removeAll { $0.day < cutoff }
        save()
    }

    /// The most-missed subjects over the last `days` days, most missed first.
    func weakest(days: Int = 7, limit: Int = 3, now: Date = Date()) -> [(subject: String, count: Int)] {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        var totals: [String: Int] = [:]
        for miss in misses where miss.day >= cutoff { totals[miss.subject, default: 0] += miss.count }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }
    func missedThisWeek(now: Date = Date()) -> Int { weakest(days: 7, limit: .max, now: now).reduce(0) { $0 + $1.count } }

    static func quizPrompt(_ subjects: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: subjects)
        return "I'm a medical student studying for boards. Quiz me on \(list), my weakest subjects this week. Give me 5 board-style multiple-choice questions (clinical vignettes, A–E), one at a time. Wait for my answer, then tell me if I'm right and explain why each option is right or wrong, with the high-yield takeaway."
    }

    func showDemo(_ sample: [String: Int]) { demo = true; misses = []; log(sample) }
    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(misses) else { return }
        UserDefaults.standard.set(data, forKey: "weakTopics")
    }
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Tap a subject once per question missed; right-click to take one back.
struct MissTagger: View {
    @Binding var counts: [String: Int]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 5)], spacing: 5) {
            ForEach(WeakTopics.subjects, id: \.self) { subject in
                let count = counts[subject] ?? 0
                Button { counts[subject] = count + 1 } label: {
                    HStack(spacing: 4) {
                        Text(subject).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        if count > 0 { Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit() }
                    }
                    .foregroundStyle(count > 0 ? Color.black : Theme.secondary)
                    .padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 24)
                    .background(Capsule().fill(count > 0 ? Theme.attention : Theme.card))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(count > 0 ? "\(count) missed · right-click to take one back" : "Missed one in \(subject)")
                .contextMenu {
                    Button("Take one back") { counts[subject] = max(0, count - 1) }.disabled(count == 0)
                    Button("Clear") { counts[subject] = nil }.disabled(count == 0)
                }
            }
        }
    }
}

/// Study tab: the week's weakest subjects, tagging misses and a quiz from Ask AI.
struct WeakTopicsCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var topics: WeakTopics
    @State private var tagging = false
    @State private var counts: [String: Int] = [:]
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel(text: "Weak spots")
                    Text("this week").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    if !tagging { PillButton(title: "Log misses", symbol: "plus") { counts = [:]; tagging = true } }
                }
                if tagging {
                    Text("Tap a subject for each question you missed.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    MissTagger(counts: $counts)
                    HStack {
                        PillButton(title: "Cancel", symbol: nil) { tagging = false }
                        Spacer()
                        PillButton(title: "Save", symbol: "checkmark", tint: Theme.done, prominent: true) { topics.log(counts); tagging = false }
                            .disabled(counts.values.reduce(0, +) == 0)
                    }
                } else {
                    let weakest = topics.weakest()
                    if weakest.isEmpty {
                        Text("After a question block, tap the subjects you missed. Your three weakest this week show here, and Ask AI can quiz you on them.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        let top = max(1, weakest.first?.count ?? 1)
                        ForEach(weakest, id: \.subject) { item in
                            HStack(spacing: 8) {
                                Text(item.subject).font(.system(size: 12, weight: .semibold)).frame(width: 70, alignment: .leading).lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.raised)
                                        Capsule().fill(Theme.attention).frame(width: max(4, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                                    }
                                }.frame(height: 5)
                                Text("\(item.count) missed").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
                            }
                        }
                        HStack {
                            Text("\(topics.missedThisWeek()) missed in 7 days").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            Spacer()
                            PillButton(title: "Quiz me", symbol: "sparkles", tint: Theme.working, prominent: true) { model.quiz(on: weakest.map(\.subject)) }
                        }
                    }
                }
            }
        }
    }
}

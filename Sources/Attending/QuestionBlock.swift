import AppKit
import SwiftUI
import ApplicationServices
import Carbon

/// A timed question-bank block: N questions in M minutes. The notch shows which question
/// you're on and whether you're ahead of or behind the pace. The question advances from
/// the page itself when Attending can read "Item 12 of 40" (UWorld, AMBOSS and others,
/// through Accessibility), with ⌃⌘→ / ⌃⌘← or the buttons as the fallback.
@MainActor final class QuestionBlock: ObservableObject {
    struct Run: Equatable {
        var total: Int
        var seconds: TimeInterval
        var started = Date()
        /// The question you're on, from 1.
        var current = 1
        var pausedAt: Date?
        var pausedFor: TimeInterval = 0
        /// The page's own question number has been read at least once.
        var reading = false
        var perQuestion: TimeInterval { seconds / Double(max(1, total)) }
    }
    struct Result: Equatable {
        var total: Int
        var answered: Int
        var elapsed: TimeInterval
        var timeUp: Bool
        var perQuestion: TimeInterval { elapsed / Double(max(1, answered)) }
    }

    @Published private(set) var run: Run?
    /// The last block, until its misses are logged or it's dismissed.
    @Published var result: Result?
    @Published var questions = UserDefaults.standard.object(forKey: "blockQuestions") as? Int ?? 40 {
        didSet { UserDefaults.standard.set(questions, forKey: "blockQuestions") }
    }
    @Published var minutes = UserDefaults.standard.object(forKey: "blockMinutes") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(minutes, forKey: "blockMinutes") }
    }
    var onEnd: ((Result) -> Void)?
    var onChange: (() -> Void)?
    private var endTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var shortcuts: [GlobalShortcut] = []

    var running: Bool { run != nil }

    func start() {
        run = Run(total: max(1, questions), seconds: TimeInterval(max(1, minutes) * 60))
        result = nil
        scheduleEnd()
        startReading()
        shortcuts = [
            try? GlobalShortcut(keyCode: kVK_RightArrow, modifiers: controlKey | cmdKey) { [weak self] in self?.next() },
            try? GlobalShortcut(keyCode: kVK_LeftArrow, modifiers: controlKey | cmdKey) { [weak self] in self?.previous() },
        ].compactMap { $0 }
        onChange?()
    }
    func next() { guard var run, run.current < run.total else { return }; run.current += 1; self.run = run }
    func previous() { guard var run, run.current > 1 else { return }; run.current -= 1; self.run = run }
    func togglePause() {
        guard var run else { return }
        if let pausedAt = run.pausedAt { run.pausedFor += Date().timeIntervalSince(pausedAt); run.pausedAt = nil }
        else { run.pausedAt = Date() }
        self.run = run
        scheduleEnd()
    }
    /// Ends the block. Ending early counts the questions before the current one; on the
    /// last question (or when time runs out there) the last one counts too.
    func end(timeUp: Bool = false) {
        guard let run else { return }
        endTask?.cancel(); readTask?.cancel()
        shortcuts.forEach { $0.invalidate() }; shortcuts = []
        let answered = run.current >= run.total ? run.total : max(0, run.current - 1)
        let finished = Result(total: run.total, answered: answered, elapsed: min(run.seconds, elapsed(of: run)), timeUp: timeUp)
        self.run = nil
        result = finished
        onEnd?(finished)
        onChange?()
    }
    func cancel() {
        endTask?.cancel(); readTask?.cancel()
        shortcuts.forEach { $0.invalidate() }; shortcuts = []
        run = nil
        onChange?()
    }

    // MARK: Pace

    func elapsed(of run: Run, at date: Date = Date()) -> TimeInterval {
        max(0, (run.pausedAt ?? date).timeIntervalSince(run.started) - run.pausedFor)
    }
    func remaining(at date: Date = Date()) -> TimeInterval { run.map { max(0, $0.seconds - elapsed(of: $0, at: date)) } ?? 0 }
    /// Questions ahead of the pace (negative when behind): where you are against where the
    /// clock says you should be.
    func ahead(at date: Date = Date()) -> Int {
        guard let run else { return 0 }
        let expected = min(run.total, Int(elapsed(of: run, at: date) / run.perQuestion) + 1)
        return run.current - expected
    }
    static func paceText(_ ahead: Int) -> String { ahead == 0 ? "on pace" : ahead > 0 ? "\(ahead) ahead" : "\(-ahead) behind" }
    static func paceColor(_ ahead: Int) -> Color { ahead >= 0 ? Theme.done : ahead >= -2 ? Theme.attention : Theme.failed }
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func scheduleEnd() {
        endTask?.cancel()
        guard let run, run.pausedAt == nil else { return }
        let left = run.seconds - elapsed(of: run)
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, left)))
            guard !Task.isCancelled else { return }
            self?.end(timeUp: true)
        }
    }

    /// Every two seconds, looks for the question number on the front window.
    private func startReading() {
        readTask?.cancel()
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let run, run.pausedAt == nil, AXIsProcessTrusted() else { continue }
                let total = run.total
                guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let pid = app.processIdentifier, bundleID = app.bundleIdentifier
                let found = await Task.detached(priority: .utility) { QuestionReader.read(total: total, pid: pid, bundleID: bundleID) }.value
                guard let found, var current = self.run, found != current.current || !current.reading else { continue }
                current.current = found
                current.reading = true
                self.run = current
            }
        }
    }

    func showDemo(current: Int, total: Int, minutesIn: Double, minutes: Double) {
        run = Run(total: total, seconds: minutes * 60, started: Date().addingTimeInterval(-minutesIn * 60), current: current, reading: true)
    }
}

/// Reads "Item 12 of 40" / "Question 12 of 40" from the front window, first from its
/// title, then from the page's text through Accessibility. Only question-bank pages are
/// searched, and only the number is kept.
enum QuestionReader {
    static let banks = ["uworld", "amboss", "truelearn", "nbme", "combank", "comquest", "kaplan", "usmle-rx", "usmlerx", "bootcamp", "boards and beyond", "pastest", "lecturio", "osmosis", "qbank", "question bank", "test", "exam", "quiz", "block"]
    private static let pattern = try! NSRegularExpression(pattern: #"\b(?:item|question|q)\s*#?\s*(\d{1,3})\s*(?:of|/)\s*(\d{1,3})\b"#, options: [.caseInsensitive])
    private static let chromium: Set<String> = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]

    static func read(total: Int, pid: pid_t, bundleID: String?) -> Int? {
        let element = AXUIElementCreateApplication(pid)
        guard let window = copy(element, kAXFocusedWindowAttribute) else { return nil }
        let title = (copy(window, kAXTitleAttribute) as? String) ?? ""
        if let number = match(title, total: total) { return number }
        guard banks.contains(where: title.lowercased().contains) else { return nil }
        // Chromium browsers expose page text to Accessibility only when asked.
        if let bundleID, chromium.contains(bundleID) { AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        var queue: [(AXUIElement, Int)] = [(window as! AXUIElement, 0)], visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = copy(node, attribute) as? String, text.count < 80, let number = match(text, total: total) { return number }
            }
            guard depth < 40, let children = copy(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }
    /// The question number, when the text names the block's own total.
    static func match(_ text: String, total: Int) -> Int? {
        for result in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let a = Range(result.range(at: 1), in: text), let b = Range(result.range(at: 2), in: text),
                  let number = Int(text[a]), let of = Int(text[b]), of == total, (1...total).contains(number) else { continue }
            return number
        }
        return nil
    }
    private static func copy(_ element: AnyObject, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

// MARK: - Views

/// Study tab: set up a block, follow it, then log what you missed.
struct BlockCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var block: QuestionBlock
    @State private var counts: [String: Int] = [:]
    @State private var logToBank = true
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionLabel(text: "Question block")
                    Spacer()
                    if let run = block.run, run.reading { Text("Following the page").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                }
                if block.run != nil { running }
                else if let result = block.result { finished(result) }
                else { setup }
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach([(40, 60), (20, 30), (10, 15)], id: \.0) { preset in
                    let on = block.questions == preset.0 && block.minutes == preset.1
                    Button { block.questions = preset.0; block.minutes = preset.1 } label: {
                        Text("\(preset.0) in \(preset.1)m").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).frame(height: 24)
                            .foregroundStyle(on ? Color.black : Theme.primary)
                            .background(Capsule().fill(on ? Theme.done : Theme.card))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                Stepper("\(block.questions) questions", value: $block.questions, in: 1...120).font(.system(size: 11)).fixedSize()
                Stepper("\(block.minutes) min", value: $block.minutes, in: 1...300, step: 5).font(.system(size: 11)).fixedSize()
            }
            HStack {
                Text("\(QuestionBlock.clock(Double(block.minutes * 60) / Double(max(1, block.questions)))) per question").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Spacer()
                PillButton(title: "Start block", symbol: "play.fill", tint: Theme.done, prominent: true) { block.start() }
            }
            Text("The notch keeps your pace. It follows UWorld, AMBOSS and similar pages when it can read the question number; otherwise ⌃⌘→ moves to the next question.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let run = block.run {
                let ahead = block.ahead(at: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Q\(run.current)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of \(run.total)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(QuestionBlock.paceText(ahead)).font(.system(size: 12, weight: .semibold)).foregroundStyle(QuestionBlock.paceColor(ahead))
                        Text("· \(QuestionBlock.clock(block.remaining(at: context.date))) left").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    BlockPaceBar(block: block, run: run, date: context.date).frame(height: 6)
                    HStack(spacing: 6) {
                        PillButton(title: "Back", symbol: "chevron.left") { block.previous() }.disabled(run.current <= 1)
                        PillButton(title: "Next", symbol: "chevron.right", tint: Theme.done, prominent: true) { block.next() }.disabled(run.current >= run.total)
                        Spacer()
                        PillButton(title: run.pausedAt == nil ? "Pause" : "Resume", symbol: run.pausedAt == nil ? "pause.fill" : "play.fill") { block.togglePause() }
                        PillButton(title: "End", symbol: nil) { block.end() }
                    }
                }
            }
        }
    }

    @ViewBuilder private func finished(_ result: QuestionBlock.Result) -> some View {
        let bank = model.exams.pinned.flatMap { $0.bankTotal != nil ? $0 : nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(result.answered) of \(result.total)").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("in \(QuestionBlock.clock(result.elapsed)) · \(QuestionBlock.clock(result.perQuestion)) per question").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            Text("What did you miss? Tap a subject for each one.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            MissTagger(counts: $counts)
            HStack {
                if let bank, result.answered > 0 {
                    Toggle("Add \(result.answered) to \(bank.bankName.isEmpty ? "your bank" : bank.bankName)", isOn: $logToBank).toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
                }
                Spacer()
                PillButton(title: "Dismiss", symbol: nil) { counts = [:]; block.result = nil }
                PillButton(title: "Save", symbol: "checkmark", tint: Theme.done, prominent: true) {
                    model.saveBlock(result, misses: counts, logToBank: logToBank && bank != nil)
                    counts = [:]
                }
            }
        }
    }
}

/// Time used (track) against questions done (fill), with a tick where the pace is now.
struct BlockPaceBar: View {
    @ObservedObject var block: QuestionBlock
    let run: QuestionBlock.Run
    let date: Date
    var body: some View {
        GeometryReader { geo in
            let time = min(1, block.elapsed(of: run, at: date) / run.seconds)
            let done = Double(run.current - 1) / Double(run.total)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(QuestionBlock.paceColor(block.ahead(at: date))).frame(width: max(4, geo.size.width * done))
                Rectangle().fill(Theme.primary.opacity(0.8)).frame(width: 2).offset(x: geo.size.width * time - 1)
            }
        }
    }
}

/// One line in the hover preview: question, pace, time left and next/back.
struct BlockStrip: View {
    @ObservedObject var block: QuestionBlock
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let run = block.run {
                let ahead = block.ahead(at: context.date)
                HStack(spacing: 10) {
                    Image(systemName: "list.number").foregroundStyle(QuestionBlock.paceColor(ahead))
                    Text("Q\(run.current) of \(run.total)").font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                    Text(QuestionBlock.paceText(ahead)).font(.system(size: 11, weight: .semibold)).foregroundStyle(QuestionBlock.paceColor(ahead)).fixedSize()
                    BlockPaceBar(block: block, run: run, date: context.date).frame(height: 4)
                    Text(QuestionBlock.clock(block.remaining(at: context.date))).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
                    IconButton(symbol: "chevron.left", help: "Previous question (⌃⌘←)", size: 24) { block.previous() }
                    IconButton(symbol: "chevron.right", help: "Next question (⌃⌘→)", size: 24) { block.next() }
                }
                .frame(height: 32)
            }
        }
    }
}

/// "12/40" beside the notch, colored by pace.
struct BlockWing: View {
    @ObservedObject var block: QuestionBlock
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let run = block.run {
                Text("\(run.current)/\(run.total)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(run.pausedAt != nil ? Theme.secondary : QuestionBlock.paceColor(block.ahead(at: context.date)))
                    .lineLimit(1).fixedSize()
                    .help("Question \(run.current) of \(run.total) · \(QuestionBlock.paceText(block.ahead(at: context.date)))")
            }
        }
    }
}

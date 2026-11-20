import SwiftUI
import AttendingCore
import AppKit
import UniformTypeIdentifiers

// MARK: - Home quick strip

/// Pinned apps on the left; mail, drives and the next exam on the right.
struct QuickStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launcher: LauncherStore
    @ObservedObject var drives: VolumeMonitor
    @ObservedObject var outlook: OutlookService
    @ObservedObject var exams: ExamStore
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(launcher.items) { item in
                LaunchIcon(launcher: launcher, item: item)
            }
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.tertiary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(dropTargeted ? Theme.working : Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .help("Drag an app, folder or file here to pin it")
            Spacer(minLength: 6)
            if let summary = model.sheets.primary, let days = summary.daysLeft {
                Chip(symbol: "graduationcap.fill", text: "\(summary.shortName) · \(days)d · \(Int((summary.fractionDone * 100).rounded()))% done", tint: days <= 7 ? Theme.attention : Theme.secondary) { model.selectedTab = .study }
                    .help("\(summary.pagesDone) of \(summary.pagesTotal) pages read")
            } else if model.showExams, let exam = exams.pinned, exams.visible(exam) {
                Chip(symbol: "graduationcap.fill", text: "\(exam.shortName) · \(exams.compact(exam))", tint: exams.urgency(exam) == Theme.primary ? Theme.secondary : exams.urgency(exam)) { model.selectedTab = .study }
            }
            if outlook.installed {
                Chip(symbol: "envelope.fill", text: outlook.unread.map { $0 > 0 ? "\($0)" : "Mail" } ?? "Mail", tint: (outlook.unread ?? 0) > 0 ? Theme.working : Theme.secondary) { outlook.open() }
                    .contextMenu { Button("New Email") { outlook.compose() }; Button("Open Outlook") { outlook.open() } }
            }
            ForEach(drives.volumes) { volume in
                HStack(spacing: 4) {
                    Chip(symbol: "externaldrive.fill", text: volume.name, tint: Theme.secondary) { drives.reveal(volume) }
                    Button { drives.eject(volume) } label: {
                        Image(systemName: drives.ejecting.contains(volume.id) ? "hourglass" : "eject.fill")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.primary)
                            .frame(width: 24, height: 24).background(Circle().fill(Theme.raised))
                    }.buttonStyle(.plain).help("Eject \(volume.name)")
                }
            }
        }
        .frame(height: 30)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            ShelfStore.load(providers) { urls in launcher.add(urls) }
            return true
        }
    }
}

struct LaunchIcon: View {
    @ObservedObject var launcher: LauncherStore
    let item: LaunchItem
    @State private var hovering = false
    var body: some View {
        Button { launcher.launch(item) } label: {
            Image(nsImage: launcher.icon(for: item)).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.name)
        .contextMenu {
            Button("Move Left") { launcher.move(item, by: -1) }
            Button("Move Right") { launcher.move(item, by: 1) }
            Divider()
            Button("Unpin \(item.name)") { launcher.remove(item) }
        }
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.secondary
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(hovering ? Theme.raised : Theme.card))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct ShelfSwitcher: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach([Tab.shelf, .clipboard, .notes], id: \.self) { tab in
                Button { model.selectedTab = tab } label: {
                    Text(tab == .shelf ? "Files" : tab.title).font(.system(size: 11, weight: .semibold)).fixedSize()
                        .padding(.horizontal, 10).frame(height: 22)
                        .foregroundStyle(model.selectedTab == tab ? Theme.primary : Theme.tertiary)
                        .background(Capsule().fill(model.selectedTab == tab ? Theme.raised : .clear))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Mic status in the wings: during a Zoom call it shows mute state and toggles it;
/// otherwise a small orange mic means some app is listening.
struct MicIndicator: View {
    @ObservedObject var meeting: MeetingMonitor
    var body: some View {
        if let zoom = meeting.zoom {
            Button { meeting.toggleZoomMute() } label: {
                Image(systemName: zoom == .muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(zoom == .muted ? Theme.failed : Theme.done)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(zoom == .muted ? "Unmute in Zoom" : "Mute in Zoom")
        } else if meeting.micInUse {
            Image(systemName: "mic.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.attention)
                .help("An app is using the microphone")
        }
        if meeting.cameraInUse {
            Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.done)
                .help("An app is using the camera")
        }
    }
}

// MARK: - Study tab

struct StudyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var anki: AnkiService
    @ObservedObject var exams: ExamStore
    @ObservedObject var sheets: SheetTracker
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                LookupBar()
                if model.showExams && !exams.upcoming.isEmpty { BoardsCard(exams: exams, onShare: model.shareExam, turnOnExamWeek: { model.examWeek = true }) }
                TrackersCard(sheets: sheets)
                CanvasCard(canvas: model.canvas)
                HStack(alignment: .top, spacing: 10) {
                    BlockCard(model: model, block: model.block).frame(maxWidth: .infinity)
                    WeakTopicsCard(model: model, topics: model.weakTopics).frame(width: 290)
                }
                HStack(alignment: .top, spacing: 10) {
                    AnkiCard(anki: anki).frame(maxWidth: .infinity)
                    StudySessionCard(model: model, timer: model.timer, anki: anki).frame(width: 250)
                }
                if model.showExams && exams.upcoming.isEmpty { BoardsCard(exams: exams, onShare: model.shareExam, turnOnExamWeek: { model.examWeek = true }) }
                if model.showExams { ScoresCard(exams: exams) }
                WeekCard(model: model, activity: model.activity)
            }
        }.scrollIndicators(.never)
        .onAppear { anki.refresh(); sheets.scanDrive(); if sheets.trackers.contains(where: { sheets.states[$0.id] == nil }) { sheets.refreshAll() } }
    }
}

/// Pomodoro study session with an optional Anki review goal.
struct StudySessionCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: FocusTimer
    @ObservedObject var anki: AnkiService
    @AppStorage("sessionFocus") private var focus = 25.0
    @AppStorage("sessionGoal") private var goal = 200
    @AppStorage("sessionUseGoal") private var useGoal = true
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: "Study session")
                if let session = timer.session {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().stroke(Theme.raised, lineWidth: 3)
                                Circle().trim(from: 0, to: timer.progress(at: context.date)).stroke(timer.isBreak ? Theme.working : Theme.done, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                            }.frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(FocusTimer.format(timer.remaining(at: context.date))).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(timer.label).font(.system(size: 10)).foregroundStyle(timer.isBreak ? Theme.working : Theme.tertiary)
                            }
                            Spacer()
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(1...session.cycles, id: \.self) { index in
                            Circle().fill(index < session.cycle || (index == session.cycle && session.phase != .focus) ? Theme.done : index == session.cycle ? Theme.done.opacity(0.4) : Theme.raised).frame(width: 7, height: 7)
                        }
                    }
                    if let goal = session.reviewGoal, let progress = session.goalProgress {
                        VStack(alignment: .leading, spacing: 3) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.raised)
                                    Capsule().fill(Theme.working).frame(width: max(4, geo.size.width * progress))
                                }
                            }.frame(height: 5)
                            Text("\(session.reviewsDone) of \(goal) reviews").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    HStack(spacing: 6) {
                        PillButton(title: timer.isRunning ? "Pause" : "Resume", symbol: timer.isRunning ? "pause.fill" : "play.fill") { timer.isRunning ? timer.pause() : timer.resume() }
                        PillButton(title: "Skip", symbol: "forward.end.fill") { timer.skipPhase() }
                        PillButton(title: "End", symbol: nil) { timer.cancel() }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach([25.0, 50.0], id: \.self) { minutes in
                            Button { focus = minutes } label: {
                                Text("\(Int(minutes))/\(Int(minutes / 5))").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .foregroundStyle(focus == minutes ? Color.black : Theme.primary)
                                    .background(Capsule().fill(focus == minutes ? Theme.done : Theme.card))
                            }.buttonStyle(.plain)
                        }
                        Text("min").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                    Toggle(isOn: $useGoal) {
                        Stepper(value: $goal, in: 25...1000, step: 25) {
                            Text("Until \(goal) reviews").font(.system(size: 11))
                        }
                    }.toggleStyle(.checkbox).controlSize(.small)
                    PillButton(title: "Start session", symbol: "play.fill", tint: Theme.done, prominent: true) {
                        model.startStudySession(focus: focus, breakMinutes: focus / 5, goal: useGoal ? goal : nil, openAnki: useGoal && anki.installed)
                    }
                    Text(useGoal ? "Opens Anki and ends when you hit your goal." : "4 focus rounds with breaks between.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

struct AnkiCard: View {
    @ObservedObject var anki: AnkiService
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Anki")
                    if let profile = anki.profile { Text(profile).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    Spacer()
                    if anki.installed { PillButton(title: "Study now", symbol: "play.fill", tint: Theme.done, prominent: true) { anki.openAnki() } }
                }
                if let stats = anki.stats {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        metric("\(stats.dueReviews)", "due", Theme.working)
                        metric("\(stats.learning)", "learning", Theme.attention)
                        if let new = anki.newCards { metric("\(new)", "new", Theme.secondary) }
                        metric("\(stats.reviewedToday)", "done today", Theme.done)
                        metric("\(stats.minutesToday)m", "today", Theme.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        WeekBars(values: stats.week)
                        VStack(alignment: .leading, spacing: 2) {
                            Label("\(stats.streak)-day streak", systemImage: "flame.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(stats.streak > 0 ? Theme.attention : Theme.tertiary)
                            Text("\(stats.dueTomorrow) due tomorrow").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let card = stats.cardOfDay { CardOfDay(front: card.front, back: card.back) }
                    if !anki.decks.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(anki.decks.prefix(4)) { deck in
                                Button { anki.review(deck) } label: {
                                    HStack(spacing: 8) {
                                        Text(deck.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        if deck.new > 0 { Text("\(deck.new)").foregroundStyle(Theme.working) }
                                        if deck.learning > 0 { Text("\(deck.learning)").foregroundStyle(Theme.attention) }
                                        if deck.review > 0 { Text("\(deck.review)").foregroundStyle(Theme.done) }
                                        Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Theme.tertiary)
                                    }
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Review \(deck.name)")
                            }
                        }
                    }
                } else {
                    Text(anki.installed ? "Open Anki once so Attending can find your collection." : "Install Anki to see your reviews here.")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
    private func metric(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }
}

struct WeekBars: View {
    let values: [Int]
    var body: some View {
        let top = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(index == values.count - 1 ? Theme.done : Theme.done.opacity(0.45))
                        .frame(width: 10, height: max(2, 34 * CGFloat(value) / CGFloat(top)))
                    Text(Self.day(index, of: values.count)).font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .help("\(value) reviews")
            }
        }
    }
    static func day(_ index: Int, of count: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: index - (count - 1), to: Date()) ?? Date()
        return String(date.formatted(.dateTime.weekday(.narrow)))
    }
}


struct TrackersCard: View {
    @ObservedObject var sheets: SheetTracker
    @State private var adding = false
    @State private var link = ""
    @State private var bridgeURL = ""
    @State private var message: String?
    @State private var copied = false
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SectionLabel(text: sheets.trackers.count > 1 ? "PBL tracker" : "PBL trackers")
                    if sheets.trackers.count > 1 && !adding {
                        ForEach(sheets.trackers) { tracker in
                            let selected = tracker.id == shown?.id
                            Button { withAnimation(.easeOut(duration: 0.15)) { sheets.pickedID = tracker.id.uuidString } } label: {
                                Text(name(tracker)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                                    .padding(.horizontal, 9).frame(height: 20)
                                    .background(Capsule().fill(selected ? Theme.raised : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    if sheets.connected {
                        if !sheets.trackers.isEmpty { IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 20) { sheets.refreshAll() } }
                        IconButton(symbol: adding ? "xmark" : "plus", help: adding ? "Cancel" : "Add tracker", size: 20) { adding.toggle() }
                    }
                }
                if !sheets.connected { setup } else {
                    if adding || sheets.trackers.isEmpty { addTracker }
                    if let shown { TrackerRow(sheets: sheets, tracker: shown).id(shown.id) }
                }
            }
        }
    }

    /// The same tracker the hover glance and Home follow (your pick, also while it loads).
    private var shown: SheetTracker.Tracker? {
        if let picked = sheets.picked {
            guard case .loaded(let summary) = sheets.states[picked.id] else { return picked }
            if !sheets.pickLapsed(summary) { return picked }
        }
        return sheets.primaryTracker?.tracker ?? sheets.picked ?? sheets.trackers.first
    }
    private func name(_ tracker: SheetTracker.Tracker) -> String {
        if case .loaded(let summary) = sheets.states[tracker.id], !summary.shortName.isEmpty { return summary.shortName }
        return tracker.label.isEmpty ? "Tracker" : tracker.label
    }
    private func showNewest() { if let newest = sheets.trackers.last { sheets.pickedID = newest.id.uuidString } }

    /// One-time Apps Script setup: copy, deploy as a web app, paste the URL back.
    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your Google Sheets once, then read and tick off your trackers right from the notch.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            step(1, "Copy the connector script and open Apps Script.") {
                PillButton(title: copied ? "Copied" : "Copy script", symbol: copied ? "checkmark" : "doc.on.doc", tint: Theme.done, prominent: true) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sheets.setupScript(), forType: .string)
                    copied = true
                    NSWorkspace.shared.open(URL(string: "https://script.google.com/create")!)
                }
            }
            step(2, "Select all, paste, then Deploy › New deployment › Web app. Set Execute as: Me and Who has access: Anyone. Authorize with your Google account (choose Advanced › Go to project, since it's your own script).") { EmptyView() }
            step(3, "Paste the Web app URL.") {
                TextField("https://script.google.com/macros/s/…/exec", text: $bridgeURL).textFieldStyle(.roundedBorder).font(.system(size: 11))
                PillButton(title: "Connect", symbol: nil, tint: Theme.done, prominent: true) { message = sheets.connect(url: bridgeURL) }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention) }
        }
    }
    private func step<Content: View>(_ number: Int, _ text: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black).frame(width: 16, height: 16).background(Circle().fill(Theme.secondary))
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            trailing()
        }
    }
    private var addTracker: some View {
        VStack(alignment: .leading, spacing: 6) {
            let suggestions = sheets.driveSuggestions
            if !suggestions.isEmpty {
                Text("From your Google Drive").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                ForEach(suggestions.prefix(5)) { sheet in
                    HStack {
                        Image(systemName: "tablecells").foregroundStyle(Theme.done)
                        Text(sheet.name).font(.system(size: 12)).lineLimit(1)
                        Text(sheet.modified, format: .relative(presentation: .named)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        Spacer()
                        PillButton(title: "Add", symbol: "plus") { if sheets.add(link: sheet.link, label: sheet.name) { showNewest() }; adding = false }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Or paste a Google Sheets link (open the tab you want first)", text: $link).textFieldStyle(.roundedBorder).font(.system(size: 11))
                PillButton(title: "Add", symbol: "plus") { if sheets.add(link: link, label: "") { link = ""; adding = false; showNewest() } }
            }
        }
    }
}

struct TrackerRow: View {
    @ObservedObject var sheets: SheetTracker
    let tracker: SheetTracker.Tracker
    @State private var showDone = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if sheets.refreshing.contains(tracker.id), case .loaded = sheets.states[tracker.id] {
                    ProgressView().controlSize(.small).scaleEffect(0.5).help("Refreshing from Google Sheets")
                }
                Spacer()
                Button("Open sheet") { sheets.open(tracker) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            switch sheets.states[tracker.id] ?? .idle {
            case .idle, .loading:
                HStack(spacing: 6) { ProgressView().controlSize(.small).scaleEffect(0.6); Text("Reading tracker…").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            case .needsBridge:
                Text("Connect Google Sheets above to read this tracker.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            case .failed(let message):
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention)
            case .loaded(let summary):
                if summary.items.isEmpty {
                    Text("No readings with a Status checkbox were found in this tab.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                } else {
                    if let problem = summary.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.attention).lineLimit(2)
                    }
                    stats(summary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule().fill(Theme.done).frame(width: max(4, geo.size.width * summary.fractionDone))
                        }
                    }.frame(height: 6)
                    readings(summary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .contextMenu { Button("Refresh") { sheets.refresh(tracker) }; Button("Remove tracker") { sheets.remove(tracker) } }
    }

    private func stats(_ summary: SheetTracker.Summary) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if let days = summary.daysLeft {
                stat(days == 0 ? "Today" : "\(days)", days == 1 ? "day to exam" : days == 0 ? "exam day" : "days to exam", days <= 7 ? Theme.attention : Theme.primary)
            }
            stat("\(Int((summary.fractionDone * 100).rounded()))%", "completed", Theme.done)
            if summary.pagesTotal > 0 { stat("\(summary.pagesDone)/\(summary.pagesTotal)", "pages read", Theme.secondary) }
            stat("\(summary.chaptersDone)/\(summary.items.count)", "chapters done", Theme.secondary)
            Spacer(minLength: 0)
            if let goal = sheets.goal(for: tracker, summary), let exam = summary.examDate {
                VStack(alignment: .trailing, spacing: 3) {
                    DailyGoalBadge(goal: goal)
                    Text("\(goal.target) pages a day finishes by \(exam.formatted(.dateTime.month(.abbreviated).day()))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }

    @ViewBuilder private func readings(_ summary: SheetTracker.Summary) -> some View {
        let shown = showDone ? summary.items : summary.pending
        let sections = shown.reduce(into: [String?]()) { list, item in if !list.contains(item.section) { list.append(item.section) } }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let section { Text(section.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.tertiary).padding(.top, 4) }
                ForEach(shown.filter { $0.section == section }) { item in
                    ReadingRow(item: item) { sheets.toggle(tracker, item) }
                }
            }
            if summary.pending.isEmpty && !showDone {
                Label("All readings done", systemImage: "checkmark.seal.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.done)
            }
            Button(showDone ? "Hide completed" : "Show completed (\(summary.chaptersDone))") { withAnimation(.easeOut(duration: 0.2)) { showDone.toggle() } }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.top, 2)
        }
    }
    private var title: String {
        if case .loaded(let summary) = sheets.states[tracker.id], !summary.title.isEmpty { return summary.title }
        return tracker.label
    }
}

/// A chapter with its Status checkbox; clicking anywhere on the row checks it off in the sheet.
struct ReadingRow: View {
    let item: SheetTracker.Item
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(item.done ? Theme.done : Theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(item.label).font(.system(size: 11.5)).foregroundStyle(item.done ? Theme.tertiary : Theme.primary).strikethrough(item.done).lineLimit(1)
                Spacer(minLength: 6)
                if !item.book.isEmpty { Text(item.book).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                if item.pages > 0 { Text("\(item.pages)p").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 30, alignment: .trailing) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.done ? "Mark as not read in the sheet" : "Mark as read in the sheet")
    }
}

// MARK: - Home study cards

/// "12 / 33 pages today" with a small ring; a check once the day's goal is reached.
struct DailyGoalBadge: View {
    let goal: SheetTracker.DailyGoal
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.raised, lineWidth: 2.5)
                Circle().trim(from: 0, to: goal.fraction).stroke(Theme.done, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                if goal.met { Image(systemName: "checkmark").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(Theme.done) }
            }
            .frame(width: 13, height: 13)
            .animation(.easeOut(duration: 0.4), value: goal.done)
            Text(goal.met ? "Today's \(goal.target) pages done" : "\(goal.done) / \(goal.target) pages today")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(goal.met ? Theme.done : Theme.primary)
        }
        .help("Pages left this morning, spread evenly over the days until the exam")
    }
}

/// Home's slice of the current exam tracker: progress and the next few chapters,
/// checkable in place. Hidden until a tracker with an exam date has loaded.
struct StudyTodayCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sheets: SheetTracker
    var body: some View {
        if let (tracker, summary) = sheets.primaryTracker {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SectionLabel(text: summary.daysLeft.map { "\(summary.shortName) · \($0 == 0 ? "exam day" : $0 == 1 ? "1 day" : "\($0) days")" } ?? summary.shortName)
                        Spacer()
                        Button("Tracker") { model.selectedTab = .study }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int((summary.fractionDone * 100).rounded()))%").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.done)
                        Text("done · \(summary.pagesLeft) pages left").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Spacer(minLength: 4)
                        if let goal = sheets.goal(for: tracker, summary) { DailyGoalBadge(goal: goal) }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule().fill(Theme.done).frame(width: max(4, geo.size.width * summary.fractionDone))
                        }
                    }.frame(height: 4)
                    if summary.pending.isEmpty {
                        Label("All readings done", systemImage: "checkmark.seal.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.done)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(summary.pending.prefix(3)) { item in
                                ReadingRow(item: item) { sheets.toggle(tracker, item) }
                            }
                        }
                        .padding(.horizontal, -8)
                    }
                }
            }
        }
    }
}

// MARK: - Salah

/// Today's five prayers: the next one and its time, tap a prayer to mark it prayed.
struct SalahCard: View {
    @ObservedObject var salah: SalahTracker
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: "Salah")
                    // The Islamic day begins at Maghrib.
                    Text(SalahCard.hijri(salah.times[.maghrib].map { salah.now >= $0 } == true ? salah.now.addingTimeInterval(86400) : salah.now)).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        .help(salah.place.map { "Prayer times for \($0)" } ?? "Hijri date (Umm al-Qura)")
                    Spacer()
                    if let qibla = salah.qibla {
                        Text("Qibla \(Int(qibla.rounded()))° \(PrayerTimes.compassPoint(qibla))").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                            .help("Direction of the Kaaba, in degrees from true north")
                    }
                    if salah.streak > 0 {
                        Label("\(salah.streak)", systemImage: "flame.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.attention)
                            .help("\(salah.streak)-day streak of all five prayers")
                    }
                }
                if salah.times.isEmpty {
                    Text(salah.denied ? "Location is off for Attending. Allow it in System Settings › Privacy › Location Services to get prayer times." : "Finding your prayer times…")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in headline(now: salah.demoTime ?? context.date) }
                    HStack(spacing: 4) {
                        ForEach(PrayerTimes.Prayer.obligatory, id: \.self) { prayer in
                            PrayerPill(prayer: prayer, time: salah.times[prayer], prayed: salah.prayed.contains(prayer), current: salah.current == prayer) { salah.toggle(prayer) }
                        }
                    }
                    // Shia timing: Dhuhr and Asr run to sunset, Maghrib and Isha to Islamic midnight.
                    if salah.method.isShia, let sunset = salah.times[.sunset], let midnight = salah.midnight {
                        Text("Sunset \(sunset.formatted(date: .omitted, time: .shortened)) · Midnight \(midnight.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                            .help("Dhuhr and Asr can be prayed until sunset; Maghrib and Isha until Islamic midnight (halfway from sunset to Fajr)")
                    }
                }
            }
        }
    }
    @ViewBuilder private func headline(now: Date) -> some View {
        if salah.jummahReminder, let jummah = salah.jummahToday, now < jummah.addingTimeInterval(45 * 60), salah.next?.prayer == .dhuhr || salah.current == .dhuhr {
            HStack(spacing: 5) {
                Text(now < jummah ? "Jummah \(Self.countdown(to: jummah, now: now))" : "Jummah now").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.done)
                Text("· khutbah \(jummah.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        } else if let current = salah.current, !salah.prayed.contains(current), let end = salah.end(of: current) {
            HStack(spacing: 5) {
                Text("\(current.title) now").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.done)
                Text("· until \(end.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        } else if let next = salah.next {
            HStack(spacing: 5) {
                Text("\(next.prayer.title) \(Self.countdown(to: next.time, now: now))").font(.system(size: 13, weight: .semibold))
                Text("· \(next.time.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
    }
    /// "27 Rabiʻ II 1448" (Umm al-Qura calendar).
    static func hijri(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .islamicUmmAlQura)
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMMM y"
        return formatter.string(from: date)
    }
    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(1, Int(date.timeIntervalSince(now) / 60))
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60)h \(minutes % 60)m"
    }
}

struct PrayerPill: View {
    let prayer: PrayerTimes.Prayer
    let time: Date?
    let prayed: Bool
    let current: Bool
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                Image(systemName: prayed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(prayed ? Theme.done : current ? Theme.primary : Theme.tertiary)
                    .contentTransition(.symbolEffect(.replace))
                Text(prayer.title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(current || prayed ? Theme.primary : Theme.secondary)
                    .lineLimit(1).fixedSize()
                Text(time.map { $0.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) } ?? "–")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(current ? Theme.done.opacity(0.12) : hovering ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(current ? Theme.done.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(prayed ? "Mark \(prayer.title) as not prayed" : "Mark \(prayer.title) as prayed")
    }
}

/// "Asr 4:45" beside the hover preview's title.
struct NextPrayerChip: View {
    @ObservedObject var salah: SalahTracker
    var body: some View {
        if let next = salah.next {
            HStack(spacing: 4) {
                Image(systemName: "moon.stars.fill").font(.system(size: 9))
                Text("\(next.prayer.title) \(next.time.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.secondary).fixedSize()
            .help("Next prayer")
        }
    }
}

/// Anki at a glance on Home: cards due, today's work and the streak.
struct AnkiMiniCard: View {
    @ObservedObject var anki: AnkiService
    var body: some View {
        if let stats = anki.stats {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Anki")
                        Spacer()
                        if stats.streak > 0 {
                            Label("\(stats.streak)", systemImage: "flame.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.attention)
                                .help("\(stats.streak)-day streak")
                        }
                    }
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(stats.dueReviews + stats.learning)").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(stats.dueReviews + stats.learning == 0 ? Theme.done : Theme.working)
                            Text("due · \(stats.reviewedToday) done today").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if anki.installed { PillButton(title: "Study", symbol: "play.fill", tint: Theme.done, prominent: true) { anki.openAnki() } }
                    }
                }
            }
        }
    }
}

// MARK: - Live activities

/// Progress ring in the wings: determinate for downloads, a slow spin for renders.
struct ActivityRing: View {
    @ObservedObject var center: ActivityCenter
    var body: some View {
        if let activity = center.running.first {
            ZStack {
                Circle().stroke(Theme.raised, lineWidth: 2)
                if let fraction = activity.fraction {
                    Circle().trim(from: 0, to: fraction).stroke(Theme.working, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Circle().trim(from: 0, to: 0.3).stroke(Theme.done, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180))
                    }
                }
            }
            .frame(width: 12, height: 12)
            .help(activity.name)
        }
    }
}

struct ActivityList: View {
    @ObservedObject var center: ActivityCenter
    var limit: Int
    var body: some View {
        let items = Array(center.visible.prefix(limit))
        if !items.isEmpty {
            VStack(spacing: 6) { ForEach(items) { ActivityRow(center: center, activity: $0) } }
        }
    }
}

struct ActivityRow: View {
    @ObservedObject var center: ActivityCenter
    let activity: LiveActivity
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ActivityCenter.icon(for: activity)).resizable().frame(width: 30, height: 30)
                .onDrag { NSItemProvider(contentsOf: activity.url) ?? NSItemProvider() }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(detail).font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(activity.state == .done ? Theme.done : Theme.tertiary).lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        if let fraction = activity.state == .done ? 1 : activity.fraction {
                            Capsule().fill(activity.state == .done ? Theme.done : Theme.working).frame(width: max(4, geo.size.width * fraction))
                        } else {
                            // Renders report no percentage; a moving segment shows the file is being written.
                            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                                Capsule().fill(Theme.done).frame(width: geo.size.width * 0.25).offset(x: geo.size.width * 0.75 * t)
                            }
                        }
                    }
                }.frame(height: 4)
            }
            if activity.state != .running {
                IconButton(symbol: "magnifyingglass", help: "Show in Finder", size: 22) { center.reveal(activity) }
                IconButton(symbol: "xmark", help: "Dismiss", size: 22) { center.dismiss(activity) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
    private var detail: String {
        switch activity.state {
        case .done: return "Done · \(activity.sizeText)"
        case .cancelled: return "Stopped"
        case .running:
            let rate = activity.bytesPerSecond > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(activity.bytesPerSecond), countStyle: .file))/s" : ""
            if let fraction = activity.fraction { return "\(Int(fraction * 100))%\(rate)" }
            return "\(activity.appName.map { "\($0) · " } ?? "")\(activity.sizeText)\(rate)"
        }
    }
}

/// One due card a day, flipped with a click.
struct CardOfDay: View {
    let front: String
    let back: String
    @State private var flipped = false
    var body: some View {
        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { flipped.toggle() } } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(flipped ? "ANSWER" : "CARD OF THE DAY").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(flipped ? Theme.done : Theme.tertiary)
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                }
                Text(flipped ? (back.isEmpty ? front : back) : front).font(.system(size: 12)).foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).lineLimit(6)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(flipped ? "Show the front" : "Flip to the answer")
    }
}

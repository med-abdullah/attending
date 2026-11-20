import SwiftUI
import AppKit
import AttendingCore
import ServiceManagement
import UniformTypeIdentifiers

private struct NotchBandKey: EnvironmentKey { static let defaultValue: CGFloat = 34 }
private struct NotchWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var notchBand: CGFloat { get { self[NotchBandKey.self] } set { self[NotchBandKey.self] = newValue } }
    var notchWidth: CGFloat { get { self[NotchWidthKey.self] } set { self[NotchWidthKey.self] = newValue } }
}

/// A row split around the hardware notch: content on either side of the camera housing.
struct NotchRow<Leading: View, Trailing: View>: View {
    @Environment(\.notchBand) private var band
    @Environment(\.notchWidth) private var notchWidth
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { leading }.frame(maxWidth: .infinity, alignment: .leading)
            if notchWidth > 0 { Color.clear.frame(width: notchWidth + 8) }
            HStack(spacing: 6) { trailing }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: band)
    }
}

// MARK: - Collapsed

/// Now-playing bars. With audio capture allowed they follow the music's bass, mids
/// and treble; otherwise they fall back to a gentle looping animation.
struct EqualizerBars: View {
    @ObservedObject var spectrum: AudioSpectrum
    let animate: Bool
    var height: CGFloat = 12
    var barWidth: CGFloat = 2
    var tint: Color = Theme.done
    @State private var phase = false
    var body: some View {
        HStack(alignment: .bottom, spacing: barWidth * 0.75) {
            if spectrum.live {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(tint)
                        .frame(width: barWidth, height: max(barWidth, height * CGFloat(spectrum.levels[index])))
                }
            } else {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(tint)
                        .frame(width: barWidth, height: height * (phase ? [0.75, 0.4, 0.9, 0.5][index] : [0.35, 0.85, 0.5, 0.7][index]))
                        .animation(animate ? .easeInOut(duration: [0.45, 0.35, 0.55, 0.4][index]).repeatForever(autoreverses: true) : .default, value: phase)
                }
            }
        }
        .frame(width: barWidth * 4 + barWidth * 2.25, height: height, alignment: .bottom)
        .onAppear { phase = animate }
        .onChange(of: animate) { _, value in phase = value }
        .accessibilityLabel("Media playing")
    }
}

// MARK: - Hover preview

struct PreviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaController
    @ObservedObject var timer: FocusTimer
    var body: some View {
        if model.dragActive { DropZones(model: model) } else { glance }
    }
    private var glance: some View {
        VStack(spacing: 8) {
            NotchRow {
                NotchMark(mood: model.mood, animate: false, height: 15)
                Text(model.active.isEmpty ? "Attending" : "\(model.active.count) active")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            } trailing: {
                if model.attentionCount > 0 {
                    Label("\(model.attentionCount)", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.attention).lineLimit(1).fixedSize()
                        .help("\(model.attentionCount) needs you")
                } else if model.salahEnabled {
                    NextPrayerChip(salah: model.salah)
                }
                IconButton(symbol: "chevron.down", help: "Open Attending", size: 22) { model.setMode(.expanded) }
            }
            if let alert = model.alert {
                AlertBanner(alert: alert) { model.open(alert.target) }
            } else {
                if model.showsPreviewActivities { ActivityList(center: model.activities, limit: 2) }
                if model.showsPreviewMedia { MediaCompact(media: media, volume: model.volume) }
                let sessions = model.previewSessions
                if sessions.isEmpty && !model.showsPreviewMedia && model.glanceTiles == 0 && model.glanceReading == nil && !model.block.running {
                    HStack {
                        Text("All quiet").font(.system(size: 13, weight: .medium))
                        Text("· no agents running").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        Spacer()
                    }.frame(height: 36)
                }
                ForEach(sessions) { session in
                    Button { model.selectedSessionID = session.id; model.open(.agents) } label: { SessionRow(session: session, compact: true) }.buttonStyle(.plain)
                }
                if timer.isActive { TimerStrip(timer: timer) }
                if model.block.running { BlockStrip(block: model.block) }
                if model.previewGlance {
                    GlanceView(model: model, calendar: model.calendar, sheets: model.sheets, anki: model.anki, usage: model.usage)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown while a file is dragged over the notch: big targets right under the pointer.
struct DropZones: View {
    @ObservedObject var model: AppModel
    @Environment(\.notchBand) private var band
    var body: some View {
        VStack(spacing: 0) {
            // Below the hardware notch, which would hide the middle target.
            Color.clear.frame(height: band + 4)
            HStack(spacing: 8) {
                DropZone(title: "AirDrop", detail: "Send to a nearby device", tint: Theme.working, model: model) { AirDropIcon(size: 34) } drop: { model.airDrop($0) }
                DropZone(title: "Shelf", detail: "Keep it for later", tint: Theme.done, model: model) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.done)
                } drop: { model.dropOnShelf($0) }
                if GoogleDrive.folder != nil {
                    DropZone(title: "Drive", detail: "Upload to Google Drive", tint: Theme.attention, model: model) {
                        Image(systemName: "externaldrive.badge.icloud").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.attention)
                    } drop: { model.saveToDrive($0) }
                }
            }
            .frame(height: 96)
            Spacer(minLength: 0)
        }
    }
}

private struct DropZone<Icon: View>: View {
    let title: String
    let detail: String
    let tint: Color
    @ObservedObject var model: AppModel
    @ViewBuilder var icon: () -> Icon
    let drop: ([URL]) -> Void
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 5) {
            icon().frame(height: 34)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(targeted ? tint.opacity(0.2) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(targeted ? tint : Theme.stroke, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])))
        .scaleEffect(targeted ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            ShelfStore.load(providers) { urls in drop(urls) }
            return true
        }
        .onChange(of: targeted) { _, value in
            model.dropZoneTargeted = value
            if !value { model.dragChanged(targeted: model.dropTargeted) }
        }
    }
}

/// The hover preview's at-a-glance strip: what's next, how the exam is going, what's
/// due in Anki and how much Claude is left, plus the next chapter to check off.
struct GlanceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var sheets: SheetTracker
    @ObservedObject var anki: AnkiService
    @ObservedObject var usage: UsageMonitor
    var body: some View {
        VStack(spacing: 6) {
            if model.glanceTiles > 0 {
                HStack(spacing: 6) {
                    if !model.examWeek, model.calendarEnabled, let event = calendar.next { eventTile(event) }
                    if let (tracker, summary) = sheets.primaryTracker {
                        let goal = sheets.goal(for: tracker, summary)
                        // No exam date in the sheet: just the tracker's name.
                        let when = summary.daysLeft.map { $0 == 0 ? " · today" : " · \($0)d" } ?? ""
                        GlanceTile(symbol: "graduationcap.fill", label: "\(summary.shortName)\(when)", value: "\(Int((summary.fractionDone * 100).rounded()))%",
                                   detail: goal.map { $0.met ? "✓ today" : "\($0.done)/\($0.target)p" } ?? (summary.pagesLeft > 0 ? nil : "done"), tint: Theme.done, progress: summary.fractionDone,
                                   help: "\(summary.pagesDone) of \(summary.pagesTotal) pages read" + (goal.map { " · \($0.done) of today's \($0.target)" } ?? "")) { model.open(.study) }
                    } else if model.showExams, let exam = model.exams.pinned, model.exams.visible(exam) {
                        let today = model.exams.questionsToday(exam)
                        GlanceTile(symbol: "graduationcap.fill", label: exam.shortName, value: model.exams.compact(exam),
                                   detail: today.target.map { $0 == 0 ? "bank done" : "\(today.done)/\($0) Qs" }, tint: model.exams.urgency(exam),
                                   help: "Until \(exam.name)") { model.open(.study) }
                    }
                    if let stats = anki.stats {
                        GlanceTile(symbol: "rectangle.stack.fill", label: "Anki", value: "\(stats.dueReviews + stats.learning)", detail: stats.reviewedToday > 0 ? "\(stats.reviewedToday) done" : "due",
                                   tint: stats.dueReviews + stats.learning == 0 ? Theme.done : Theme.working, help: "Open Anki to review") { anki.openAnki() }
                    }
                    if !model.examWeek, let five = usage.fiveHour {
                        GlanceTile(symbol: "sparkle", label: "Claude 5h", value: "\(Int(five.used.rounded()))%", detail: five.resetsAt.map { $0.formatted(date: .omitted, time: .shortened) },
                                   tint: five.used < 70 ? Theme.done : five.used < 90 ? Theme.attention : Theme.failed, progress: five.used / 100,
                                   help: five.resetsAt.map { "Resets at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Claude usage") { model.open(.home) }
                    }
                }
                .frame(height: 48)
            }
            if let reading = model.glanceReading {
                NextReadingRow(sheets: sheets, tracker: reading.tracker, item: reading.item)
            }
        }
    }

    private func eventTile(_ event: UpcomingEvent) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let soon = event.start.timeIntervalSince(now) < 10 * 60
            let label: String = {
                if event.start <= now { return "Now" }
                let minutes = Int(event.start.timeIntervalSince(now) / 60)
                if minutes < 60 { return "In \(max(1, minutes)) min" }
                if !Calendar.current.isDate(event.start, inSameDayAs: now) { return "Tomorrow" }
                return event.start.formatted(date: .omitted, time: .shortened)
            }()
            let join = soon ? event.joinURL : nil
            GlanceTile(symbol: join != nil ? "video.fill" : "calendar", label: label, value: event.title, compactValue: true,
                       tint: soon ? Theme.attention : event.calendarColor.map(Color.init(nsColor:)) ?? Theme.primary,
                       help: join != nil ? "Join \(event.title)" : TodayCard.when(event, now: now)) {
                if let join { NSWorkspace.shared.open(join) } else { calendar.openCalendarApp() }
            }
        }
    }
}

struct GlanceTile: View {
    let symbol: String
    let label: String
    let value: String
    var detail: String? = nil
    var compactValue = false
    var tint: Color = Theme.primary
    var progress: Double? = nil
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Theme.tertiary)
                // The detail drops out before the value would truncate.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        valueText
                        if let detail { Text(detail).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize() }
                    }
                    valueText
                }
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raised)
                            Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, progress))))
                        }
                    }.frame(height: 3)
                } else {
                    // Same footprint as the progress bar so every tile's text lines up.
                    Capsule().fill(compactValue ? tint : .clear).frame(width: 14, height: 3)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(hovering ? Theme.raised : Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
    private var valueText: some View {
        Text(value).font(compactValue ? .system(size: 12, weight: .semibold) : .system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit().foregroundStyle(compactValue ? Theme.primary : tint).lineLimit(1)
    }
}

/// The first unread chapter of the current exam tracker; one click checks it off in
/// the sheet, with a moment to undo before the next chapter slides in.
struct NextReadingRow: View {
    @ObservedObject var sheets: SheetTracker
    let tracker: SheetTracker.Tracker
    let item: SheetTracker.Item
    @State private var checked: SheetTracker.Item?
    @State private var hovering = false
    @State private var clearTask: Task<Void, Never>?
    var body: some View {
        let shown = checked ?? item
        let done = checked != nil
        HStack(spacing: 8) {
            Button {
                guard !done else { return }
                sheets.toggle(tracker, item)
                withAnimation(.easeOut(duration: 0.2)) { checked = item }
                clearTask?.cancel()
                clearTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { checked = nil }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13)).foregroundStyle(done ? Theme.done : Theme.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(done ? "READ" : "NEXT").font(.system(size: 8.5, weight: .bold)).tracking(0.8).foregroundStyle(done ? Theme.done : Theme.tertiary)
                    Text(shown.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(done ? Theme.tertiary : Theme.primary).strikethrough(done).lineLimit(1)
                    Spacer(minLength: 6)
                    if !done {
                        if !shown.book.isEmpty { Text(shown.book).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                        if shown.pages > 0 { Text("\(shown.pages)p").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.secondary) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done ? "Checked off in your tracker" : "Mark as read in your tracker")
            if let checked {
                Button("Undo") {
                    clearTask?.cancel()
                    sheets.toggle(tracker, checked)
                    withAnimation(.easeOut(duration: 0.2)) { self.checked = nil }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.working)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.raised : Theme.card))
        .onHover { hovering = $0 }
    }
}

struct AlertBanner: View {
    let alert: NotchAlert
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let image = alert.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 58, height: 40).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
                        .onDrag { alert.fileURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                        .help("Drag the screenshot anywhere")
                } else {
                    Image(systemName: alert.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(alert.color)
                        .shadow(color: alert.color.opacity(0.5), radius: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.system(size: 14, weight: .semibold))
                    Text(alert.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if let title = alert.actionTitle, let perform = alert.action {
                    PillButton(title: title, symbol: nil, tint: alert.color, prominent: true) { perform() }
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 4).frame(height: 50)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Expanded

struct TabIcon: View {
    let tab: Tab
    let selected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.primary : hovering ? Theme.secondary : Theme.tertiary)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(selected ? Theme.raised : hovering ? Theme.card : .clear))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.black)
                            .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(tab == .agents ? Theme.attention : Theme.secondary))
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Report where this tab sits so the window can switch tabs on hover.
        .background(GeometryReader { geo in Color.clear.preference(key: TabFramesKey.self, value: [tab: geo.frame(in: .global)]) })
        .help(tab.title).accessibilityLabel(tab.title)
    }
}

struct TabFramesKey: PreferenceKey {
    static let defaultValue: [Tab: CGRect] = [:]
    static func reduce(value: inout [Tab: CGRect], nextValue: () -> [Tab: CGRect]) { value.merge(nextValue()) { $1 } }
}

// MARK: - Home

struct AgentsSummaryCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Agents")
                    Spacer()
                    Button("See all") { model.selectedTab = .agents }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                let approvals = model.claudeApprovals.count + model.codexApprovals.count
                if approvals > 0 {
                    Button { model.selectedTab = .agents } label: {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                            Text("\(approvals) waiting for you").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.attention)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.attention.opacity(0.14)))
                    }.buttonStyle(.plain)
                }
                if model.active.isEmpty {
                    HStack(spacing: 6) {
                        Text("All quiet").font(.system(size: 13, weight: .semibold))
                        Text("· sessions appear while they run").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                } else {
                    ForEach(Array(model.active.prefix(approvals > 0 ? 3 : 4))) { session in
                        Button { model.selectedSessionID = session.id; model.selectedTab = .agents } label: { SessionRow(session: session, compact: true) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct TimerStrip: View {
    @ObservedObject var timer: FocusTimer
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").foregroundStyle(Theme.done)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(FocusTimer.format(timer.remaining(at: context.date))).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text(timer.label).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            Spacer()
            IconButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", help: timer.isRunning ? "Pause" : "Resume", size: 24) { timer.isRunning ? timer.pause() : timer.resume() }
            IconButton(symbol: "xmark", help: "Stop timer", size: 24) { timer.cancel() }
        }.frame(height: 32)
    }
}

struct TimerCard: View {
    @ObservedObject var timer: FocusTimer
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: timer.isActive ? timer.label : "Focus timer")
                if timer.isActive {
                    HStack(spacing: 12) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ZStack {
                                Circle().stroke(Theme.raised, lineWidth: 3)
                                Circle().trim(from: 0, to: timer.progress(at: context.date)).stroke(Theme.done, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                            }.frame(width: 30, height: 30)
                            Text(FocusTimer.format(timer.remaining(at: context.date))).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        PillButton(title: timer.isRunning ? "Pause" : "Resume", symbol: timer.isRunning ? "pause.fill" : "play.fill") { timer.isRunning ? timer.pause() : timer.resume() }
                        PillButton(title: "+5", symbol: nil) { timer.add(minutes: 5) }
                        PillButton(title: "Stop", symbol: nil) { timer.cancel() }
                    }
                } else {
                    HStack(spacing: 6) {
                        ForEach([5, 15, 25, 50], id: \.self) { minutes in
                            PillButton(title: "\(minutes)m", symbol: nil) { timer.start(minutes: Double(minutes), label: minutes <= 5 ? "Break" : "Focus") }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Media

struct ThinSlider: View {
    var value: Double
    var tint: Color = Theme.primary
    var onChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    @State private var dragValue: Double?
    @State private var hovering = false
    var body: some View {
        GeometryReader { geo in
            let current = min(1, max(0, dragValue ?? value))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(tint.opacity(hovering || dragValue != nil ? 1 : 0.85)).frame(width: max(4, geo.size.width * current))
            }
            .frame(height: hovering || dragValue != nil ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let next = min(1, max(0, gesture.location.x / max(1, geo.size.width)))
                    dragValue = next; onChange?(next)
                }
                .onEnded { _ in
                    if let dragValue { onCommit?(dragValue) }
                    dragValue = nil
                })
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct Artwork: View {
    @ObservedObject var media: MediaController
    var size: CGFloat
    var body: some View {
        Button { media.openSource() } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let artwork = media.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack { Theme.raised; Image(systemName: "music.note").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Theme.tertiary) }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                if let icon = media.sourceIcon {
                    Image(nsImage: icon).resizable().frame(width: size * 0.38, height: size * 0.38).offset(x: size * 0.1, y: size * 0.1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(media.sourceName.map { "Show \($0)" } ?? "")
    }
}

/// Hover preview: pause, skip and volume without opening anything.
struct MediaCompact: View {
    @ObservedObject var media: MediaController
    @ObservedObject var volume: SystemVolume
    var body: some View {
        if let track = media.track {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Artwork(media: media, size: 42)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if track.playing { EqualizerBars(spectrum: media.spectrum, animate: true, height: 10) }
                        }
                        HStack(spacing: 5) {
                            if track.isSpotify { SmartPickBadge(spotify: media.spotify, compact: true) }
                            Text([track.artist, media.sourceName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if track.isSpotify { QuickAddButton(spotify: media.spotify) }
                    IconButton(symbol: "backward.fill", help: "Previous", size: 28, tint: Theme.primary) { media.previous() }
                    IconButton(symbol: track.playing ? "pause.fill" : "play.fill", help: track.playing ? "Pause" : "Play", size: 34, tint: Theme.primary, filled: true) { media.toggle() }
                    IconButton(symbol: "forward.fill", help: "Next", size: 28, tint: Theme.primary) { media.next() }
                }
                VolumeRow(volume: volume)
            }
        }
    }
}

struct VolumeRow: View {
    @ObservedObject var volume: SystemVolume
    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: volume.muted || volume.level == 0 ? "speaker.slash.fill" : volume.level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill",
                       help: volume.muted ? "Unmute" : "Mute", size: 20, tint: Theme.secondary) { volume.toggleMute() }
            ThinSlider(value: volume.muted ? 0 : Double(volume.level), onChange: { volume.set(Float($0)) })
                .disabled(!volume.adjustable)
            Text("\(Int((volume.muted ? 0 : volume.level) * 100))").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 22, alignment: .trailing)
        }
    }
}

struct MediaCard: View {
    @ObservedObject var media: MediaController
    @ObservedObject var volume: SystemVolume
    var body: some View {
        Card(padding: media.track == nil ? 10 : 14) {
            if let track = media.track {
                HStack(alignment: .center, spacing: 14) {
                    Artwork(media: media, size: 76)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    if track.playing { EqualizerBars(spectrum: media.spectrum, animate: true, height: 13, barWidth: 2.5) }
                                }
                                HStack(spacing: 6) {
                                    Text([track.artist, media.sourceName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    if track.isSpotify { SmartPickBadge(spotify: media.spotify, compact: false) }
                                }
                            }
                            Spacer()
                            if track.isSpotify {
                                SpotifyControls(media: media, spotify: media.spotify)
                            }
                            if track.isMusic {
                                if let favorite = media.musicFavorite {
                                    IconButton(symbol: favorite ? "star.fill" : "star", help: favorite ? "Remove from Favorites" : "Favorite", size: 24, tint: favorite ? Theme.failed : Theme.tertiary) { media.toggleMusicFavorite() }
                                }
                                if let shuffle = media.musicShuffle {
                                    IconButton(symbol: "shuffle", help: "Shuffle", size: 24, tint: shuffle ? Theme.done : Theme.tertiary) { media.toggleMusicShuffle() }
                                }
                                PlaylistMenu(media: media)
                            }
                        }
                        if track.duration > 0 {
                            TimelineView(.periodic(from: .now, by: track.playing ? 1 : 3600)) { context in
                                let position = track.position(at: context.date)
                                HStack(spacing: 8) {
                                    Text(timeString(position)).font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 38, alignment: .leading)
                                    ThinSlider(value: position / track.duration, onCommit: { media.seek(to: $0 * track.duration) })
                                    Text(timeString(track.duration)).font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary).frame(width: 38, alignment: .trailing)
                                }
                            }
                        }
                        HStack(spacing: 4) {
                            IconButton(symbol: "gobackward.15", help: "Back 15 seconds", size: 28) { media.skip(-15) }
                            IconButton(symbol: "backward.fill", help: "Previous", size: 30, tint: Theme.primary) { media.previous() }
                            IconButton(symbol: track.playing ? "pause.fill" : "play.fill", help: track.playing ? "Pause" : "Play", size: 36, tint: Theme.primary, filled: true) { media.toggle() }
                            IconButton(symbol: "forward.fill", help: "Next", size: 30, tint: Theme.primary) { media.next() }
                            IconButton(symbol: "goforward.15", help: "Forward 15 seconds", size: 28) { media.skip(15) }
                            Spacer(minLength: 12)
                            VolumeRow(volume: volume).frame(maxWidth: 170)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ZStack { Theme.raised; Image(systemName: "music.note").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary) }
                        .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text("Nothing playing").font(.system(size: 13, weight: .semibold))
                        .help(media.available ? "Play something in Spotify, YouTube or Music to control it here." : "Media controls are unavailable on this Mac.")
                    Spacer()
                    if media.spotifyInstalled { PillButton(title: "Spotify", symbol: "play.fill", tint: Theme.done) { media.openSpotify() } }
                    PillButton(title: "Music", symbol: "music.note", tint: Color(red: 0.98, green: 0.36, blue: 0.43)) { media.openMusic() }
                    PillButton(title: "YouTube", symbol: "play.rectangle.fill") { NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!) }
                }
            }
        }
    }
}

// MARK: - Agents

struct AgentsView: View {
    @ObservedObject var model: AppModel
    private var showRecent: Bool { model.agentsShowRecent }
    var body: some View {
        if let session = model.selectedSession {
            SessionDetail(model: model, session: session)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    tab(model.active.isEmpty ? "Active" : "Active \(model.active.count)", selected: !showRecent) { model.agentsShowRecent = false }
                    tab("Recent", selected: showRecent) { model.agentsShowRecent = true }
                    Spacer()
                    if model.codexDetected {
                        IconButton(symbol: "plus", help: "Start a Codex session in a project folder") { model.newCodexProject() }
                            .disabled(model.codexBusy)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !model.claudeApprovals.isEmpty || !model.codexApprovals.isEmpty { ApprovalInbox(model: model) }
                        let sessions = showRecent ? model.recent : model.active
                        if sessions.isEmpty { empty } else { ForEach(sessions) { SessionCard(model: model, session: $0) } }
                        if showRecent && !sessions.isEmpty {
                            Button("Clear history") { model.clearHistory() }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity).padding(.top, 4)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.scrollIndicators(.never)
            }
        }
    }
    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 26)
                .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                .background(Capsule().fill(selected ? Theme.raised : .clear))
        }.buttonStyle(.plain)
    }
    private var empty: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(showRecent ? "Nothing this week" : "All quiet").font(.system(size: 14, weight: .semibold))
                Text(showRecent ? "Finished sessions from the last 7 days show here." : "Claude Code and Codex sessions show here while they work, including Codex in the ChatGPT app.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SessionCard: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var hovering = false
    var body: some View {
        SessionRow(session: session, compact: false)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.raised : Theme.card))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.draft = ""; model.selectedSessionID = session.id }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let compact: Bool
    @Environment(\.cleanScreen) private var clean
    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: session.provider, status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(clean ? "\(session.provider.title) session" : session.title).font(.system(size: compact ? 13 : 14, weight: .semibold)).lineLimit(1)
                (Text(session.provider.title + " · ") + Text(session.statusLabel).foregroundStyle(session.statusColor))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(session.timeLabel(now: context.date)).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
        }
        .frame(minHeight: compact ? 36 : 38)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension AgentSession {
    var statusLabel: String {
        switch status {
        case .working: "Working"
        case .attention: "Needs you"
        case .completed: "Done"
        case .failed: "Error"
        case .idle: latestActivity == "Stopped" ? "Stopped" : "Ready"
        case .stale: "Inactive"
        }
    }
    var statusColor: Color { status == .idle || status == .stale ? Theme.tertiary : status.color }
    /// How long it's been working, or how long ago it was last active.
    func timeLabel(now: Date) -> String {
        if status == .working { return Self.span(now.timeIntervalSince(startedAt)) }
        let ago = now.timeIntervalSince(lastActiveAt)
        if ago < 60 { return "now" }
        if ago < 3600 { return "\(Int(ago / 60))m ago" }
        if ago < 86400 { return "\(Int(ago / 3600))h ago" }
        if ago < 2 * 86400 { return "Yesterday" }
        return "\(Int(ago / 86400))d ago"
    }
    private static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes == 0 { return "<1m" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct ProviderBadge: View {
    let provider: ProviderID
    let status: SessionStatus
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(provider == .claudeCode ? Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.22) : Color(red: 0.45, green: 0.78, blue: 0.64).opacity(0.2))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: provider == .claudeCode ? "asterisk" : "chevron.left.forwardslash.chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(provider == .claudeCode ? Color(red: 0.95, green: 0.6, blue: 0.47) : Color(red: 0.55, green: 0.88, blue: 0.74)))
            StatusDot(color: status.color, pulsing: status == .working || status == .attention)
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }
}

// MARK: - Shelf

// MARK: - Settings


/// Apple Music playlist picker, filled when Music becomes the Now Playing source.
struct PlaylistMenu: View {
    @ObservedObject var media: MediaController
    var body: some View {
        Menu {
            if media.playlists.isEmpty { Text("No playlists yet") }
            ForEach(media.playlists, id: \.self) { name in Button(name) { media.play(playlist: name) } }
            Divider()
            Button("Open Music") { media.openMusic() }
        } label: {
            Image(systemName: "music.note.list").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Color(red: 0.98, green: 0.36, blue: 0.43))
        .help("Apple Music playlists")
    }
}

// MARK: - Spotify

private let spotifyGreen = Color(red: 0.12, green: 0.84, blue: 0.38)

/// Shown when the playing song was added by Smart Shuffle.
struct SmartPickBadge: View {
    @ObservedObject var spotify: SpotifyService
    var compact: Bool
    var body: some View {
        if spotify.isSmartPick {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").font(.system(size: compact ? 9 : 10, weight: .bold))
                if !compact { Text("Smart Shuffle pick").font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(spotifyGreen)
            .padding(.horizontal, compact ? 0 : 7).frame(height: compact ? 12 : 18)
            .background(Capsule().fill(compact ? .clear : spotifyGreen.opacity(0.14)))
            .help("Smart Shuffle added this song; it isn't in \(spotify.context?.name ?? "this playlist") yet")
        }
    }
}

/// One tap: add a Smart Shuffle pick to the playlist being shuffled.
struct QuickAddButton: View {
    @ObservedObject var spotify: SpotifyService
    var body: some View {
        if spotify.isSmartPick, let context = spotify.context {
            IconButton(symbol: "plus.circle.fill", help: "Add to \(context.name)", size: 26, tint: spotifyGreen) { spotify.addCurrent(to: context) }
        }
    }
}

/// Like, Smart Shuffle state and add-to-playlist for the full media card.
struct SpotifyControls: View {
    @ObservedObject var media: MediaController
    @ObservedObject var spotify: SpotifyService
    var body: some View {
        HStack(spacing: 2) {
            if let notice = spotify.notice {
                Text(notice).font(.system(size: 10, weight: .medium)).foregroundStyle(spotifyGreen).lineLimit(1)
            }
            if spotify.connected {
                if let liked = spotify.liked {
                    IconButton(symbol: liked ? "heart.fill" : "heart", help: liked ? "Remove from Liked Songs" : "Save to Liked Songs", size: 24, tint: liked ? spotifyGreen : Theme.tertiary) { spotify.toggleLike() }
                }
                Menu {
                    if let context = spotify.context { Button("Add to \(context.name)") { spotify.addCurrent(to: context) }; Divider() }
                    ForEach(spotify.playlists) { playlist in Button(playlist.name) { spotify.addCurrent(to: playlist) } }
                    if spotify.playlists.isEmpty { Text("Loading playlists…") }
                } label: {
                    Image(systemName: "text.badge.plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Theme.secondary).help("Add to playlist")
                .onAppear { if spotify.playlists.isEmpty { Task { await spotify.loadPlaylists() } } }
            }
            if spotify.connected {
                IconButton(symbol: "list.bullet", help: "Queue", size: 24, tint: spotify.showingQueue ? spotifyGreen : Theme.tertiary, filled: spotify.showingQueue) {
                    withAnimation(.easeOut(duration: 0.18)) { spotify.showingQueue.toggle() }
                }
            }
            if spotify.smartShuffle {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(spotifyGreen)
                    .frame(width: 24, height: 24).help("Smart Shuffle is on")
            } else if let shuffle = media.spotifyShuffle {
                IconButton(symbol: "shuffle", help: "Shuffle", size: 24, tint: shuffle ? Theme.done : Theme.tertiary) { media.toggleSpotifyShuffle() }
            }
        }
    }
}

/// Settings: register a Spotify developer app, then sign in on Spotify's page.
struct SpotifySetup: View {
    @ObservedObject var spotify: SpotifyService
    @State private var clientID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Spotify playlists & Smart Shuffle")
                Spacer()
                if spotify.connected { Text("Connected").foregroundStyle(spotifyGreen); Button("Disconnect") { spotify.disconnect() } }
            }
            if !spotify.connected {
                Text("1. At developer.spotify.com, create an app (Web API) with the Redirect URI below, then copy its Client ID.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                HStack {
                    Text(SpotifyService.redirect).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    PillButton(title: "Copy", symbol: nil) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(SpotifyService.redirect, forType: .string) }
                    PillButton(title: "Open dashboard", symbol: nil) { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) }
                }
                Text("2. Paste the Client ID and sign in on Spotify's page.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                HStack {
                    TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    PillButton(title: spotify.connecting ? "Waiting…" : "Connect", symbol: nil, tint: spotifyGreen, prominent: true) { spotify.connect(clientID: clientID) }
                }
            }
            if let notice = spotify.notice { Text(notice).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
        .onAppear { clientID = spotify.clientID ?? "" }
    }
}

// MARK: - Spotify queue

struct QueueView: View {
    @ObservedObject var spotify: SpotifyService
    @State private var query = ""
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Up next")
                    Spacer()
                    PillButton(title: "Add this song", symbol: "plus") { spotify.addCurrentToUpNext() }
                    IconButton(symbol: "xmark", help: "Close queue", size: 22) { withAnimation(.easeOut(duration: 0.18)) { spotify.showingQueue = false } }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Add a song to Up Next…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                        .onChange(of: query) { _, value in spotify.search(value) }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                if !query.isEmpty && !spotify.searchResults.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(spotify.searchResults) { track in
                            TrackRow(track: track) {
                                IconButton(symbol: "text.line.first.and.arrowtriangle.forward", help: "Play next", size: 22) { spotify.addToUpNext(track, first: true); query = "" }
                                IconButton(symbol: "plus", help: "Add to Up Next", size: 22) { spotify.addToUpNext(track); query = "" }
                            }
                        }
                    }
                }
                List {
                    if let pending = spotify.pending {
                        Section { TrackRow(track: pending, dimmed: spotify.pendingWillBeSkipped) {
                            if spotify.pendingWillBeSkipped { Text("Skipping").font(.system(size: 10)).foregroundStyle(Theme.attention) }
                            else { IconButton(symbol: "xmark", help: "Skip when it comes up", size: 20) { spotify.removePending() } }
                        } } header: { header("Playing next") }
                    }
                    Section {
                        if spotify.upNext.isEmpty {
                            Text("Search above, or pull songs up from below. Drag to reorder.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                        ForEach(spotify.upNext) { track in
                            TrackRow(track: track, draggable: true) {
                                IconButton(symbol: "xmark", help: "Remove", size: 20) { spotify.remove(track) }
                            }
                        }
                        .onMove { spotify.move(from: $0, to: $1) }
                    } header: { header("Your queue") }
                    if !spotify.spotifyQueue.isEmpty {
                        Section {
                            ForEach(spotify.spotifyQueue) { track in
                                TrackRow(track: track, dimmed: true, smartPick: spotify.isSmartPick(track)) {
                                    IconButton(symbol: "arrow.up.to.line", help: "Move into your queue", size: 20) { spotify.addToUpNext(track) }
                                }
                            }
                        } header: { header(spotify.context.map { "Then from \($0.name)" } ?? "Then from Spotify") }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 34)
            }
        }
        .onAppear { Task { await spotify.refreshQueue() } }
    }
    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.tertiary)
    }
}

struct TrackRow<Actions: View>: View {
    let track: SpotifyService.QueueTrack
    var dimmed = false
    var draggable = false
    var smartPick = false
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 8) {
            if draggable { Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
            AsyncImage(url: track.imageURL.flatMap(URL.init(string:))) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Theme.raised }
                .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(track.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if smartPick { Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(spotifyGreen).help("Smart Shuffle pick") }
                }
                Text(track.artist).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            actions
        }
        .opacity(dimmed ? 0.6 : 1)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    }
}

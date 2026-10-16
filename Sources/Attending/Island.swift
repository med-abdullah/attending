import SwiftUI
import AppKit
import AttendingCore
import ServiceManagement
import UniformTypeIdentifiers
import ApplicationServices

/// Root view. Draws one black island at `model.islandFrame`; the window controller
/// springs that frame between the collapsed wings, the hover preview and the full
/// panel, and content cross-fades as the mode changes.
struct ShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaController
    @ObservedObject var timer: FocusTimer

    init(model: AppModel) {
        self.model = model
        media = model.media
        timer = model.timer
    }

    private var hasNotch: Bool { model.notchHeight > 0 }
    private var band: CGFloat { hasNotch ? model.notchHeight : 34 }

    var body: some View {
        let frame = model.islandFrame
        ZStack(alignment: .topLeading) {
            island
                .frame(width: max(0, frame.width), height: max(0, frame.height))
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            // Anywhere outside a target: keep it on the Shelf.
            ShelfStore.load(providers) { urls in
                if model.mode == .expanded { model.shelf.add(urls) } else { model.dropOnShelf(urls) }
            }
            return true
        }
        .onChange(of: model.dropTargeted) { _, targeted in model.dragChanged(targeted: targeted) }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .onExitCommand { model.setMode(.idle) }
    }

    private var island: some View {
        let mode = model.shownMode
        let shape = islandShape(for: mode)
        return ZStack(alignment: .top) {
            shape.fill(Theme.background)
            content(for: mode)
                .id(mode)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.08)), removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
        .clipShape(shape)
        .overlay {
            if model.dropTargeted { shape.stroke(Theme.working.opacity(0.8), lineWidth: 2) }
        }
        .overlay { if model.confetti { ConfettiView().clipShape(shape) } }
    }

    private func islandShape(for mode: PanelMode) -> AnyShape {
        if !hasNotch { return AnyShape(RoundedRectangle(cornerRadius: mode == .idle ? 13 : 22, style: .continuous)) }
        return mode == .idle ? AnyShape(IslandShape(ear: IslandGeometry.ear, radius: 10)) : AnyShape(IslandShape(ear: 10, radius: 24))
    }

    @ViewBuilder private func content(for mode: PanelMode) -> some View {
        switch mode {
        case .idle:
            WingsView(model: model, media: media, timer: timer)
        case .preview:
            panel(size: model.panelSize) { PreviewView(model: model, media: media, timer: timer) }
        case .expanded:
            panel(size: model.panelSize) { ExpandedView(model: model) }
        }
    }

    /// Lays content out at its final size so text never reflows while the island
    /// springs open; the island's clip reveals it.
    private func panel<Content: View>(size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, hasNotch ? 26 : 16)
            .padding(.bottom, 14)
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.notchBand, band)
            .environment(\.cleanScreen, model.cleanScreen.on)
            .environment(\.notchWidth, model.notchWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Collapsed wings

/// The stethoscope mark on the left of the notch, live status on the right. The same wings widen to
/// show volume, brightness and charging levels.
struct WingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaController
    @ObservedObject var timer: FocusTimer

    var body: some View {
        let hasNotch = model.notchHeight > 0
        let ear = hasNotch ? IslandGeometry.ear : 0
        let wing = max(0, (model.islandFrame.width - model.notchWidth) / 2 - ear)
        Button { model.setMode(.expanded) } label: {
            HStack(spacing: 0) {
                leading.frame(width: hasNotch ? wing : nil).frame(maxWidth: hasNotch ? nil : .infinity, alignment: .leading)
                if hasNotch { Color.clear.frame(width: model.notchWidth) }
                trailing.frame(width: hasNotch ? wing : nil).frame(maxWidth: hasNotch ? nil : .infinity, alignment: .trailing)
            }
            .padding(.horizontal, ear + (hasNotch ? 0 : 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Attending")
    }

    @ViewBuilder private var leading: some View {
        if let hud = model.hud {
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hud.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, alignment: .center)
        } else if model.showPet {
            NotchMark(mood: model.mood, animate: model.awake && !model.reduceMotion, height: 18)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Image(systemName: "stethoscope").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let hud = model.hud, hud.kind == .headphones {
            Text(hud.label ?? "").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(hud.tint).lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity)
        } else if let hud = model.hud {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(hud.tint).frame(width: max(3, geo.size.width * hud.value))
                    }
                }
                .frame(height: 5)
                Text(hud.label ?? "\(Int((hud.value * 100).rounded()))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.secondary).fixedSize()
            }
            .padding(.horizontal, 10)
        } else {
            HStack(spacing: 6) {
                if model.showsMedia && media.track?.playing == true {
                    EqualizerBars(spectrum: model.media.spectrum, animate: model.awake && !model.reduceMotion)
                }
                if timer.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(FocusTimer.format(timer.remaining(at: context.date)))
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(!timer.isRunning ? Theme.secondary : timer.isBreak ? Theme.working : Theme.done)
                    }
                }
                if !model.active.isEmpty {
                    Text("\(model.active.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(model.mood == .idle ? Theme.secondary : model.mood.color)
                }
                MicIndicator(meeting: model.meeting)
                if let event = model.calendar.imminent { MeetingChip(event: event) }
                else if let exam = model.wingExam {
                    Text(model.exams.compact(exam)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(model.exams.urgency(exam) == Theme.primary ? Theme.secondary : model.exams.urgency(exam)).lineLimit(1).fixedSize()
                        .help("\(exam.name): \(model.exams.compact(exam))")
                }
                if model.liveActivities { ActivityRing(center: model.activities) }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var battery: BatteryMonitor
    init(model: AppModel) { self.model = model; battery = model.battery }

    var body: some View {
        VStack(spacing: 10) {
            NotchRow {
                ForEach(Array(([Tab.home] + model.headerTabs).prefix(9).enumerated()), id: \.element) { index, tab in
                    TabIcon(tab: tab, selected: model.selectedTab == tab || (tab == .shelf && !model.headerTabs.contains(model.selectedTab) && (model.selectedTab == .clipboard || model.selectedTab == .notes)), badge: badge(for: tab)) { select(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            } trailing: {
                if model.attentionCount > 0 {
                    Label("\(model.attentionCount)", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.attention).fixedSize()
                        .help("\(model.attentionCount) needs you")
                }
                if let level = battery.level {
                    HStack(spacing: 3) {
                        Text("\(level)%").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        Image(systemName: battery.symbol).font(.system(size: 12))
                    }
                    .foregroundStyle(battery.tint).fixedSize()
                    .help(battery.charging ? "Charging" : battery.onAC ? "On power" : "On battery")
                }
                KeepAwakeButton(keepAwake: model.keepAwake)
                TabIcon(tab: .settings, selected: model.selectedTab == .settings, badge: nil) { select(.settings) }
            }
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
                    Text(error).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Dismiss", size: 18) { model.error = nil }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.attention.opacity(0.12)))
            }
            Group {
                switch model.selectedTab {
                case .home: HomeView(model: model, media: model.media, calendar: model.calendar, timer: model.timer)
                case .agents: AgentsView(model: model)
                case .assistant: AssistantView(assistant: model.assistant, focusToken: model.assistantFocus)
                case .study: StudyView(model: model, anki: model.anki, exams: model.exams, sheets: model.sheets)
                case .shelf: ShelfView(model: model, shelf: model.shelf)
                case .clipboard: if model.cleanScreen.on { HiddenForCleanScreen(what: "Clipboard history") } else { ClipboardView(model: model, clipboard: model.clipboard) }
                case .notes: if model.cleanScreen.on { HiddenForCleanScreen(what: "Notes") } else { NotesView(model: model) }
                case .prompter: PrompterView(prompter: model.prompter)
                case .mirror: MirrorView(mirror: model.mirror)
                case .settings: ScrollView { SettingsView(model: model) }.scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.background)
            .id(model.selectedTab)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
        }
        .onPreferenceChange(TabFramesKey.self) { frames in MainActor.assumeIsolated { model.tabFrames = frames } }
    }
    func select(_ tab: Tab) {
        withAnimation(.easeOut(duration: 0.18)) { model.selectedTab = tab }
    }
    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .agents: model.attentionCount > 0 ? model.attentionCount : nil
        case .shelf: model.shelf.items.isEmpty ? nil : model.shelf.items.count
        default: nil
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarService
    @ObservedObject var timer: FocusTimer
    @ObservedObject private var spotify: SpotifyService
    init(model: AppModel, media: MediaController, calendar: CalendarService, timer: FocusTimer) {
        self.model = model; self.media = media; self.calendar = calendar; self.timer = timer; spotify = media.spotify
    }
    var body: some View {
        if spotify.showingQueue && media.track?.isSpotify == true {
            // The queue takes over the lower half of Home; its list scrolls and reorders.
            VStack(spacing: 10) {
                if model.mediaControls { MediaCard(media: media, volume: model.volume) }
                QueueView(spotify: spotify)
            }
            .onAppear { model.homeHeight = 540 }
        } else {
            ScrollView {
                content.background(GeometryReader { geo in Color.clear.preference(key: HomeHeightKey.self, value: geo.size.height) })
            }
            .scrollIndicators(.never)
            .onPreferenceChange(HomeHeightKey.self) { height in
                MainActor.assumeIsolated {
                    let rounded = height.rounded(.up)
                    if rounded > 0, abs(model.homeHeight - rounded) > 1 { model.homeHeight = rounded }
                }
            }
        }
    }
    private var content: some View {
        VStack(spacing: 10) {
            QuickStrip(model: model, launcher: model.launcher, drives: model.drives, outlook: model.outlook, exams: model.exams)
            if model.examWeek { examWeekContent } else { regularContent }
            Spacer(minLength: 0)
        }
    }
    /// Exam week: the countdown and study cards only.
    private var examWeekContent: some View {
        VStack(spacing: 10) {
            BoardsCard(exams: model.exams, onShare: model.shareExam)
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    StudyTodayCard(model: model, sheets: model.sheets)
                    TimerCard(timer: timer)
                }
                VStack(spacing: 10) {
                    if model.salahEnabled { SalahCard(salah: model.salah) }
                    AnkiMiniCard(anki: model.anki)
                }.frame(width: 272)
            }
        }
    }
    private var regularContent: some View {
        VStack(spacing: 10) {
            if !model.headerTabs.contains(.agents) && (!model.claudeApprovals.isEmpty || !model.codexApprovals.isEmpty) { ApprovalInbox(model: model) }
            if model.liveActivities { ActivityList(center: model.activities, limit: 2) }
            if model.mediaControls { MediaCard(media: media, volume: model.volume) }
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    if model.headerTabs.contains(.agents) || !model.active.isEmpty { AgentsSummaryCard(model: model) }
                    StudyTodayCard(model: model, sheets: model.sheets)
                    UsageCard(model: model, usage: model.usage)
                    TimerCard(timer: timer)
                }
                VStack(spacing: 10) {
                    TodayCard(model: model, calendar: calendar, weather: model.weather)
                    if model.salahEnabled { SalahCard(salah: model.salah) }
                    AnkiMiniCard(anki: model.anki)
                }.frame(width: 272)
            }
        }
    }
}

struct HomeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct UsageCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageMonitor
    @State private var installMessage: String?
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Claude usage")
                    Spacer()
                    if let updated = usage.updatedAt {
                        Text("\(usage.sourceName.map { "\($0) · " } ?? "")\(updated.formatted(.relative(presentation: .named)))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }
                }
                if usage.fiveHour == nil && usage.sevenDay == nil {
                    Text(installMessage ?? "Sign in to Claude in Ask AI and your 5-hour and weekly limits show up here, refreshed every 5 minutes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        PillButton(title: "Sign in to Claude", symbol: "person.crop.circle") { model.assistant.provider = .claude; model.openAssistant() }
                        PillButton(title: "Check now", symbol: "arrow.clockwise") { usage.refreshFromClaude() }
                    }
                } else {
                    if let five = usage.fiveHour { meter("5-hour", five) }
                    if let week = usage.sevenDay { meter("This week", week) }
                }
            }
        }
    }
    private func meter(_ title: String, _ window: UsageMonitor.Window) -> some View {
        let tint = window.used < 70 ? Theme.done : window.used < 90 ? Theme.attention : Theme.failed
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(window.used.rounded()))%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                if let reset = window.resetsAt, reset > Date() {
                    Text("· resets \(Self.resetText(reset))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(tint).frame(width: max(4, geo.size.width * window.used / 100))
                }
            }.frame(height: 5)
        }
    }
    static func resetText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}

/// Adds Attending's status line to Claude Code settings (only if none exists), so
/// Claude Code reports plan usage. Keeps a one-time backup of the original file.
enum UsageSetup {
    /// Whether Claude Code's settings already route the status line to Attending.
    static var installed: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = settings["statusLine"] as? [String: Any] else { return false }
        return (line["command"] as? String ?? "").contains("attending-bridge")
    }
    static func install() -> String {
        guard let bridge = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("attending-bridge"),
              FileManager.default.isExecutableFile(atPath: bridge.path) else { return "The bridge is missing from this build." }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Claude settings couldn't be read; nothing was changed." }
            settings = parsed
            let backup = url.appendingPathExtension("attending-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        if let existing = settings["statusLine"] as? [String: Any], !(existing["command"] as? String ?? "").contains("attending-bridge") {
            return "You already have a Claude Code status line, so Attending left it alone."
        }
        let quoted = "'" + bridge.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        settings["statusLine"] = ["type": "command", "command": quoted + " --statusline", "refreshInterval": 60]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "Couldn't write Claude settings." }
        do { try data.write(to: url, options: .atomic) } catch { return "Couldn't write Claude settings." }
        return "Connected. Usage appears the next time Claude Code refreshes (within a minute of activity)."
    }
}

struct TodayCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var weather: WeatherService
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if model.weatherEnabled {
                    if let now = weather.current {
                        let look = WeatherService.describe(now.code, day: now.isDay)
                        HStack(spacing: 8) {
                            Image(systemName: look.symbol).symbolRenderingMode(.multicolor).font(.system(size: 20))
                            Text("\(now.temperature)°").font(.system(size: 20, weight: .semibold, design: .rounded))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(look.text).font(.system(size: 11, weight: .medium))
                                Text("H \(now.high)°  L \(now.low)°\(now.place.map { " · \($0)" } ?? "")").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    } else if weather.denied {
                        Text("Location is off for Attending. Allow it in System Settings › Privacy › Location Services.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small).scaleEffect(0.6); Text("Getting weather…").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                    }
                    Divider().overlay(Theme.stroke)
                }
                SectionLabel(text: "Next up")
                if !model.calendarEnabled {
                    PillButton(title: "Connect Calendar", symbol: "calendar") { model.setCalendar(true) }
                } else if calendar.denied {
                    Text("Calendar access is off. Allow Attending in System Settings › Privacy › Calendars.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                } else if let event = calendar.next {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(event.calendarColor.map(Color.init(nsColor:)) ?? Theme.working).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Self.when(event, now: context.date)).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let join = event.joinURL {
                            PillButton(title: "Join", symbol: "video.fill", tint: Theme.done, prominent: true) { NSWorkspace.shared.open(join) }
                        }
                    }
                } else {
                    Text("Nothing else scheduled").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                if !model.weatherEnabled {
                    Button { model.setWeather(true) } label: { Label("Show weather", systemImage: "cloud.sun").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
    static func when(_ event: UpcomingEvent, now: Date) -> String {
        let range = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        if event.start <= now { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(1, minutes)) min · \(range)" }
        if !Calendar.current.isDate(event.start, inSameDayAs: now) { return "Tomorrow · \(range)" }
        return range
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfStore
    @State private var airDropTargeted = false
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfSwitcher(model: model)
                // The hint gives way to the buttons once there are files.
                if shelf.items.isEmpty { Text("Park files here, then drag them out anywhere.").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                Spacer(minLength: 8)
                if !shelf.items.isEmpty {
                    if shelf.items.contains(where: { FileConverter.isImage($0.url) }) {
                        PillButton(title: "Photos to PDF", symbol: "doc.richtext") { model.shelfImagesToPDF() }
                            .help("Make one PDF from the photos and screenshots on the Shelf, in Shelf order")
                    }
                    if shelf.items.filter({ FileConverter.isPDF($0.url) }).count >= 2 {
                        PillButton(title: "Merge PDFs", symbol: "doc.on.doc") { model.mergeShelfPDFs() }
                            .help("Join the PDFs on the Shelf into one, in Shelf order")
                    }
                    PillButton(title: "AirDrop all", symbol: "square.and.arrow.up") { model.airDrop(shelf.items.map(\.url)) }
                    PillButton(title: "Clear", symbol: nil) { shelf.clear() }
                }
            }
            if shelf.items.isEmpty {
                HStack(spacing: 10) {
                    airDropTile.frame(width: 150)
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.tertiary)
                        Text("Drop files on the notch").font(.system(size: 14, weight: .semibold))
                        Text("Files stay where they are. The shelf only keeps a shortcut.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        airDropTile.frame(width: 92, height: 92)
                        ForEach(shelf.items) { item in ShelfTile(shelf: shelf, item: item, airDrop: { model.airDrop([item.url]) }, saveToDrive: { model.saveToDrive([item.url]) }, convert: { model.convert(item.url, to: $0) }, copyText: { model.copyText(from: item.url) }, addToZotero: { model.addToZotero(item.url) }) }
                    }
                }.scrollIndicators(.never)
            }
        }
        .onAppear { shelf.pruneMissing() }
    }
    private var airDropTile: some View {
        VStack(spacing: 6) {
            AirDropIcon(size: 30)
            Text("AirDrop").font(.system(size: 11, weight: .semibold))
            Text("Drop to send").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(airDropTargeted ? Theme.working.opacity(0.22) : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(airDropTargeted ? Theme.working : .clear, lineWidth: 1.5))
        .scaleEffect(airDropTargeted ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: airDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $airDropTargeted) { providers in
            ShelfStore.load(providers) { urls in model.airDrop(urls) }
            return true
        }
    }
}

/// The system's AirDrop icon, with a fallback symbol.
struct AirDropIcon: View {
    var size: CGFloat
    var body: some View {
        if let icon = AirDropSender.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.up.forward").font(.system(size: size * 0.75, weight: .medium)).foregroundStyle(Theme.working)
        }
    }
}

struct ShelfTile: View {
    @ObservedObject var shelf: ShelfStore
    let item: ShelfItem
    var airDrop: () -> Void
    var saveToDrive: () -> Void
    var convert: (FileConverter.Kind) -> Void = { _ in }
    var copyText: () -> Void = {}
    var addToZotero: () -> Void = {}
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: shelf.icon(for: item)).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 44)
            Text(item.name).font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(Theme.secondary)
        }
        .frame(width: 92, height: 92)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.raised : Theme.card))
        .overlay(alignment: .topTrailing) {
            if hovering { IconButton(symbol: "xmark", help: "Remove from shelf", size: 18, filled: true) { shelf.remove(item) }.padding(4) }
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                HStack(spacing: 2) {
                    if FileConverter.isImage(item.url) { IconButton(symbol: "text.viewfinder", help: "Copy text from image", size: 18, filled: true) { copyText() } }
                    if FileConverter.isPDF(item.url) && ZoteroImporter.installed { IconButton(symbol: "books.vertical", help: "Add to Zotero", size: 18, filled: true) { addToZotero() } }
                    if let kind = FileConverter.options(for: item.url).first { IconButton(symbol: kind.symbol, help: kind.title, size: 18, filled: true) { convert(kind) } }
                }.padding(4)
            }
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { airDrop() }
            Button("Save to Google Drive") { saveToDrive() }
            ForEach(FileConverter.options(for: item.url), id: \.self) { kind in Button(kind.title) { convert(kind) } }
            if FileConverter.isImage(item.url) { Button("Copy Text from Image") { copyText() } }
            if FileConverter.isPDF(item.url) && ZoteroImporter.installed { Button("Add to Zotero") { addToZotero() } }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .help(item.path)
    }
}

// MARK: - Clipboard

struct ClipboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfSwitcher(model: model)
                Text("Click to paste into the app you were using.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                if !clipboard.items.isEmpty { PillButton(title: "Clear", symbol: nil) { clipboard.clear() } }
            }
            if !model.clipboardEnabled {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clipboard history is off").font(.system(size: 14, weight: .semibold))
                        PillButton(title: "Turn on", symbol: "doc.on.clipboard") { model.setClipboard(true) }
                    }
                }
            } else if clipboard.items.isEmpty && clipboard.pinned.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary)
                    Text("Copy something and it shows up here").font(.system(size: 14, weight: .semibold))
                    Text("Kept in memory only, cleared when Attending quits. Passwords from password managers are skipped.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        if !clipboard.pinned.isEmpty {
                            Text("PINNED").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(clipboard.pinned) { item in ClipRow(model: model, clipboard: clipboard, item: item, isPinned: true) }
                            Text("RECENT").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                        ForEach(clipboard.items) { item in ClipRow(model: model, clipboard: clipboard, item: item) }
                    }
                }.scrollIndicators(.never)
                if !AXIsProcessTrusted() {
                    Text("Tip: turn on the volume & brightness HUD in Settings to grant Accessibility, and Attending will paste for you. Until then, clicking copies.")
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

struct ClipRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory
    let item: ClipItem
    var isPinned = false
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.content {
                case .image(let image): Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                case .files(let urls): Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path)).resizable()
                case .text: Image(systemName: "text.alignleft").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.raised)
                }
            }
            .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview).font(.system(size: 12)).lineLimit(2).foregroundStyle(Theme.primary)
                HStack(spacing: 4) {
                    if let app = item.sourceApp { Text(app) ; Text("·") }
                    Text(item.copiedAt, format: .relative(presentation: .named))
                }.font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            if isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.attention).rotationEffect(.degrees(45))
            }
            if hovering {
                if case .text = item.content {
                    IconButton(symbol: isPinned ? "pin.slash" : "pin", help: isPinned ? "Unpin" : "Pin so it never scrolls away", size: 22) { isPinned ? clipboard.unpin(item) : clipboard.pin(item) }
                }
                IconButton(symbol: "doc.on.doc", help: "Copy without pasting", size: 22) { clipboard.copy(item) }
                if !isPinned { IconButton(symbol: "xmark", help: "Remove", size: 22) { clipboard.remove(item) } }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.raised : Theme.card))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.paste(item) }
    }
}

// MARK: - Mirror

// MARK: - Settings

struct UpdatesSection: View {
    @ObservedObject var updater: Updater
    var body: some View {
        HStack {
            Text("Attending \(updater.current)").font(.system(size: 13, weight: .semibold))
            Spacer()
            switch updater.state {
            case .checking: ProgressView().controlSize(.small)
            case .downloading: Label("Downloading…", systemImage: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            case .installing: Label("Installing…", systemImage: "gearshape.2").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            case .available:
                if let release = updater.release {
                    PillButton(title: "Update to \(release.version)", symbol: "arrow.down.circle.fill", tint: Theme.done, prominent: true) { updater.install() }
                }
            default:
                if updater.enabled { PillButton(title: "Check now", symbol: "arrow.clockwise") { Task { await updater.check(userInitiated: true) } } }
            }
        }
        if updater.enabled {
            Toggle("Check for updates automatically", isOn: $updater.automatic)
            switch updater.state {
            case .upToDate: note("You're up to date.")
            case .failed(let message): Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention)
            default: EmptyView()
            }
            if let release = updater.release, updater.state == .available, !release.notes.isEmpty {
                Text(release.notes).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(6)
                Link("Release notes", destination: release.page).font(.system(size: 11))
            }
        } else {
            note("This copy was built locally, so it updates when you rebuild it.")
        }
        if let support = Updater.supportURL {
            Link(destination: support) { Label("Support Attending", systemImage: "cup.and.saucer.fill").font(.system(size: 12, weight: .semibold)) }
        }
    }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var assistant: AssistantController
    @ObservedObject var mediaKeys: MediaKeyTap
    @ObservedObject var usage: UsageMonitor
    @State private var confirmClear = false
    @State private var usageMessage: String?
    @AppStorage("hoverTabs") private var hoverTabs = true
    @AppStorage("liveVisualizer") private var visualizer = true
    @AppStorage("ecgWhenActive") private var ecgWhenActive = true
    @State private var instantScreenshots = !ScreenshotWatcher.thumbnailEnabled
    @AppStorage("pet") private var pet = PetKind.stethoscope.rawValue
    init(model: AppModel) { self.model = model; calendar = model.calendar; assistant = model.assistant; mediaKeys = model.mediaKeys; usage = model.usage }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("General") {
                Toggle("Launch Attending at login", isOn: Binding(get: { model.loginStatus == .enabled }, set: { value in model.setLogin(value) }))
                if model.loginStatus == .requiresApproval {
                    Button("Allow Attending in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Show the notch mark", isOn: $model.showPet)
                Toggle("Turn into a live ECG while agents work", isOn: $ecgWhenActive)
                HStack {
                    Text("Notch mark")
                    Spacer()
                    Picker("Companion", selection: $pet) { ForEach(PetKind.allCases) { Text($0.title).tag($0.rawValue) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
                Toggle("Celebrate finished turns", isOn: $model.completionNotifications)
            }
            group("Updates") { UpdatesSection(updater: model.updater) }
            if model.downloads.enabled { group("Downloads") { DownloadsSection(stats: model.downloads) } }
            group("Tabs") { TabsSettings(model: model) }
            group("Notch") {
                Picker("Position", selection: Binding(get: { model.islandAnchor }, set: { model.islandAnchor = $0 })) {
                    ForEach(IslandAnchor.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 320)
                note("Or drag the island: let go and it glides to the nearest spot.")
                if NSScreen.screens.count > 1 { Toggle("Show on the display with the menu bar", isOn: $model.islandOnMainScreen) }
                StepAsideSettings(stepAside: model.stepAside)
                Toggle("Clean screen (for recording and presenting)", isOn: Binding(get: { model.cleanScreen.on }, set: { model.cleanScreen.set($0) }))
                note("Hides desktop icons, calendar titles, agent session names, what's playing, clipboard and notes. Also in the menu bar menu. Finder restarts to hide the icons.")
                Toggle("Peek on hover", isOn: $model.hoverEnabled)
                Toggle("Close when the pointer leaves or you click away", isOn: $model.autoClose)
                Toggle("Switch tabs by hovering over them", isOn: $hoverTabs)
                HStack { Text("Hover delay"); Slider(value: $model.hoverDelay, in: 0.1...0.8); Text("\(model.hoverDelay, specifier: "%.2f")s").monospacedDigit().foregroundStyle(Theme.tertiary) }
                note("⌘⇧Space opens Ask AI. Escape collapses. Drag files onto the notch to shelve them. Stays open while you're typing.")
            }
            group("Volume & brightness") {
                Toggle("Show volume and brightness in the notch", isOn: Binding(get: { model.hudEnabled && mediaKeys.active }, set: { model.setHUD($0) }))
                if model.hudEnabled && !mediaKeys.trusted {
                    HStack {
                        note("Turn on Attending in Privacy & Security › Accessibility. If it's already listed but off (or on but not working), remove it with −, then add /Applications/Attending.app with +.")
                        Spacer()
                        PillButton(title: "Grant access", symbol: "lock.open") { mediaKeys.requestPermission() }
                    }
                }
                note("Plugging in and low battery (20% and 10%) also show briefly in the notch.")
            }
            group("Alerts") {
                Toggle("Drop down when an agent finishes or needs you", isOn: $model.agentAlerts)
                Toggle("Play a sound", isOn: $model.alertSounds).disabled(!model.agentAlerts)
            }
            group("Media") {
                Toggle("Media controls", isOn: Binding(get: { model.mediaControls }, set: { model.setMediaControls($0) }))
                Toggle("Live audio visualizer", isOn: $visualizer)
                SpotifySetup(spotify: model.media.spotify)
                note("Bars follow the music while something plays. macOS asks once to let Attending listen to system audio; nothing is recorded or saved.")
                note(model.media.available ? "Works with Spotify, YouTube and other browser video, Music and podcasts." : "Now Playing is unavailable on this Mac.")
            }
            group("Home") {
                Toggle("Next calendar event", isOn: Binding(get: { model.calendarEnabled }, set: { model.setCalendar($0) }))
                if calendar.denied { note("Calendar access denied. Enable Attending in System Settings › Privacy & Security › Calendars.") }
                Toggle("Weather", isOn: Binding(get: { model.weatherEnabled }, set: { model.setWeather($0) }))
                note("Weather comes from Open-Meteo using your approximate location (about 1 km). No account.")
                HStack {
                    Text("Claude usage meter")
                    Spacer()
                    if usage.configured { Text("Connected").foregroundStyle(Theme.done) }
                    else { PillButton(title: "Set up", symbol: nil) { usageMessage = UsageSetup.install() } }
                }
                if let usageMessage { note(usageMessage) }
            }
            if model.calendarEnabled {
                group("Calendars") {
                    CalendarsSection(calendar: calendar)
                    Picker("Remind me before classes and events", selection: $model.eventLead) {
                        Text("Off").tag(0); ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }.frame(maxWidth: 380)
                }
            }
            group("Outlook & Google") {
                HStack {
                    Text("Outlook unread count")
                    Spacer()
                    Text(model.outlook.installed ? (AXIsProcessTrusted() ? "Connected" : "Needs Accessibility") : "Outlook not installed").foregroundStyle(Theme.tertiary)
                }
                HStack {
                    Text("Google Drive for desktop")
                    Spacer()
                    if GoogleDrive.folder != nil { Text("Connected").foregroundStyle(Theme.done) }
                    else { PillButton(title: "Get Drive", symbol: nil) { NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!) } }
                }
                note("PBL trackers connect through a small script in your own Google account (Study tab).")
            }
            group("Keep awake") {
                Toggle("Keep the Mac awake while an agent is working", isOn: Binding(get: { model.keepAwake.withAgents }, set: { model.keepAwake.withAgents = $0 }))
                note("The screen can still sleep; long Claude or Codex runs keep going. The coffee cup at the top keeps the screen on too: click to toggle, right-click for 30 minutes to 4 hours.")
            }
            group("Window snapping") { SnappingSettings(snapper: model.snapper) }
            group("Quit apps") { AutoQuitSettings(autoQuit: model.autoQuit) }
            group("Automation") {
                HStack { Text("When an agent starts, run Shortcut"); Spacer(); TextField("e.g. Focus On", text: $model.focusStartShortcut).textFieldStyle(.roundedBorder).frame(width: 150) }
                HStack { Text("When agents finish, run Shortcut"); Spacer(); TextField("e.g. Focus Off", text: $model.focusEndShortcut).textFieldStyle(.roundedBorder).frame(width: 150) }
                note("Make these in the Shortcuts app with a \"Set Focus\" action to turn on Do Not Disturb while agents work.")
            }
            group("Study") {
                note("Tracker exam dates are read from your PBL trackers automatically. Board exams are below.")
                Toggle("Weekly recap on Sunday evening", isOn: Binding(get: { model.activity.sundayRecap }, set: { model.activity.sundayRecap = $0 }))
                Picker("Water and stretch reminder", selection: $model.breakEvery) {
                    Text("Off").tag(0); ForEach([45, 60, 90], id: \.self) { Text("Every \($0) min").tag($0) }
                }.frame(maxWidth: 380)
                note("Only while you're at your Mac, 8 AM to 10 PM, and never during a Pomodoro break.")
                Toggle("Screen time: studying, AI and distractions", isOn: Binding(get: { model.screenTime.enabled }, set: { model.screenTime.enabled = $0 }))
                Toggle("Distraction guard during focus timers", isOn: Binding(get: { model.screenTime.guardFocus }, set: { model.screenTime.guardFocus = $0 }))
                note("Every 30 seconds while you're at your Mac, the front app (or browser tab title) is sorted as studying, AI or a distraction. Only the totals are kept, on this Mac. During a focus timer, opening YouTube, Instagram, games and the like gets a gentle nudge.")
                HStack {
                    Text("Google Sheets connector")
                    Spacer()
                    if model.sheets.connected { Button("Disconnect") { model.sheets.disconnect() } } else { Text("Set up in Study").foregroundStyle(Theme.tertiary) }
                }
            }
            group("Boards") { BoardsSettings(model: model, exams: model.exams) }
            group("Capture") {
                Toggle("Screenshot drops", isOn: Binding(get: { model.screenshotDrops }, set: { model.setScreenshotDrops($0) }))
                note("New screenshots and recordings pop out of the notch and land on your Shelf.")
                Toggle("Instant drops (turn off macOS's floating screenshot thumbnail)", isOn: $instantScreenshots)
                    .onChange(of: instantScreenshots) { _, instant in ScreenshotWatcher.thumbnailEnabled = !instant }
                note("macOS holds each screenshot file while its corner thumbnail is showing (about 5 seconds), which delays the drop. Attending's drop does the same job.")
            }
            group("Salah") {
                Toggle("Prayer times and tracker", isOn: Binding(get: { model.salahEnabled }, set: { model.setSalah($0) }))
                Picker("Calculation", selection: Binding(get: { model.salah.method }, set: { model.salah.method = $0 })) {
                    ForEach(PrayerTimes.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 380)
                Picker("Asr", selection: Binding(get: { model.salah.asr }, set: { model.salah.asr = $0 })) {
                    ForEach(PrayerTimes.Asr.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 380)
                Toggle("Notch alert at each prayer time and 15 minutes before it ends", isOn: $model.salahAlerts)
                Toggle("Jummah reminder on Fridays", isOn: Binding(get: { model.salah.jummahReminder }, set: { model.salah.jummahReminder = $0 }))
                if model.salah.jummahReminder {
                    HStack {
                        DatePicker("Khutbah at", selection: Binding(
                            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(model.salah.jummahMinutes * 60)) },
                            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); model.salah.jummahMinutes = (c.hour ?? 13) * 60 + (c.minute ?? 30) }),
                                   displayedComponents: .hourAndMinute).fixedSize()
                        Picker("Remind me", selection: Binding(get: { model.salah.jummahLead }, set: { model.salah.jummahLead = $0 })) {
                            ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) min before").tag($0) }
                        }.fixedSize()
                    }
                }
                Toggle("Surah Al-Kahf reminder Friday morning", isOn: Binding(get: { model.salah.kahfReminder }, set: { model.salah.kahfReminder = $0 }))
                note("Times are calculated on this Mac for your location\(model.salah.place.map { " (\($0))" } ?? ""). ISNA is common in North America; match your local masjid's timetable. Set the khutbah time to your masjid's.")
            }
            group("Hover preview") {
                Toggle("Glance: next event, exam, Anki, Claude usage and next reading", isOn: $model.previewGlance)
                note("Shown when you hover the notch. Click a tile to jump to it; click the reading to check it off in your tracker.")
            }
            group("Live activities") {
                Toggle("Downloads and video exports", isOn: Binding(get: { model.liveActivities }, set: { model.setLiveActivities($0) }))
                note("Shows download progress and renders (DaVinci Resolve, CapCut, Final Cut) writing to Movies, Desktop, Documents or an external drive, then tells you when they finish.")
            }
            group("Clipboard") {
                Toggle("Clipboard history", isOn: Binding(get: { model.clipboardEnabled }, set: { model.setClipboard($0) }))
                note("Last 30 items, in memory only. Items marked as passwords are never recorded.")
            }
            group("Ask AI") {
                ForEach(AssistantProvider.allCases) { item in
                    Toggle(item.title, isOn: Binding(get: { assistant.enabled.contains(item) }, set: { assistant.setEnabled(item, $0) }))
                        .disabled(assistant.enabled == [item])
                }
                if assistant.enabled.count > 1 {
                    Picker("Default", selection: $assistant.provider) { ForEach(assistant.enabled) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: CGFloat(assistant.enabled.count) * 90)
                }
                Button("Free memory (unload chat windows)") { assistant.unload() }
                note("Turn off any you don't use; they won't load at all. Each runs in its own web page with your own sign-in. Attending never sees your password.")
            }
            group("Agents") {
                HStack {
                    Text("Claude Code")
                    Spacer()
                    if ClaudeHooks.installed { Text("Connected").foregroundStyle(Theme.done) }
                    else if ClaudeHooks.claudeInstalled { PillButton(title: "Connect", symbol: nil) { usageMessage = (try? ClaudeHooks.install()) ?? "Couldn't connect. See Settings › Help." } }
                    else { Text("Not found").foregroundStyle(Theme.tertiary) }
                }
                Text("Codex and ChatGPT: \(CodexSessionWatcher.available ? "sessions detected automatically" : "not found")")
                note("Codex sessions show up on their own, from the ChatGPT and Codex apps, the IDE extension or the CLI. Connecting Claude Code adds Attending's hooks to its settings (yours are kept, with a backup); start a new session afterward.")
            }
            group("Privacy") {
                Button("Open local data folder") { NSWorkspace.shared.open(AppPaths.directory) }
                Button("Clear finished session history…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear finished session history? Active sessions are kept.", isPresented: $confirmClear) { Button("Clear history", role: .destructive) { model.clearHistory() } }
                note("Attending stores session names, folders and status, never transcripts or credentials. No telemetry.")
            }
            group("Help") {
                HStack(spacing: 8) {
                    PillButton(title: "Report a problem", symbol: "exclamationmark.bubble") { Diagnostics.report() }
                    PillButton(title: "Copy diagnostics", symbol: "doc.on.doc") { Diagnostics.copy() }
                    PillButton(title: "Setup guide", symbol: "checklist") { model.onboarding.show(step: .setup) }
                    Spacer()
                }
                note("Opens a GitHub issue with your Attending and macOS versions, Mac model and which permissions are on. Nothing personal; you see it before sending.")
            }
            group("Advanced") {
                Toggle("Debug logging", isOn: $model.debugLogging)
                Button("Quit Attending") { NSApp.terminate(nil) }
            }
        }
        .font(.system(size: 12)).toggleStyle(TrailingSwitchStyle()).controlSize(.small)
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: title)
                content()
            }
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Countdown to the next meeting in the wings, with a one-click Join.
struct MeetingChip: View {
    let event: UpcomingEvent
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(event.calendarColor.map(Color.init(nsColor:)) ?? Theme.working).frame(width: 5, height: 5)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = event.start.timeIntervalSince(context.date)
                Text(seconds > 0 ? FocusTimer.format(seconds) : "Now")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(seconds > 60 ? Theme.primary : Theme.attention)
            }
            if let url = event.joinURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 20, height: 16).background(Capsule().fill(Theme.done))
                }.buttonStyle(.plain).help("Join \(event.title)")
            }
        }
        .help(event.title)
    }
}

/// Connected calendar accounts and calendar links.
struct CalendarsSection: View {
    @ObservedObject var calendar: CalendarService
    @State private var link = ""
    @State private var adding = false
    @State private var message: String?
    @State private var showHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google, Outlook or school account")
                    Text(calendar.accounts.isEmpty ? (calendar.authorized ? "No calendar accounts yet" : "Allow Calendar access first") : "Connected: " + calendar.accounts.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(calendar.accounts.isEmpty ? Theme.tertiary : Theme.done).lineLimit(2)
                }
                Spacer()
                if calendar.authorized { PillButton(title: "Add account", symbol: "plus") { calendar.openInternetAccounts() } }
                else { PillButton(title: "Allow access", symbol: nil) {
                    if calendar.denied { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) } else { calendar.requestAccess() }
                } }
            }
            Text("Sign in with Google or Microsoft in Internet Accounts and turn on Calendars. Their events show here on their own, and Attending never sees your password.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.3)
            Text("Calendar link")
            ForEach(calendar.feeds) { feed in
                HStack(spacing: 8) {
                    Image(systemName: feed.problem == nil ? "calendar" : "exclamationmark.triangle.fill").foregroundStyle(feed.problem == nil ? Theme.secondary : Theme.attention)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feed.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(feed.problem ?? feed.updated.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Not loaded yet")
                            .font(.system(size: 10)).foregroundStyle(feed.problem == nil ? Theme.tertiary : Theme.attention).lineLimit(2)
                    }
                    Spacer()
                    IconButton(symbol: "minus.circle", help: "Remove this calendar", size: 22) { calendar.removeFeed(feed) }
                }
            }
            HStack {
                TextField("Paste a private iCal link (https:// or webcal://)", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                PillButton(title: adding ? "Adding…" : "Add", symbol: nil, prominent: true, action: add).disabled(adding || link.isEmpty)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true) }
            DisclosureGroup("Where to find the link", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Calendar (on the web): Settings › click your calendar › Integrate calendar › Secret address in iCal format.")
                    Text("Outlook (on the web): Settings › Calendar › Shared calendars › Publish a calendar › choose the calendar and Can view all details › copy the ICS link.")
                    Text("School calendars: look for Subscribe, iCal or ICS.")
                    Text("Treat the link like a password: anyone with it can see the calendar.")
                }.font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }.font(.system(size: 11))
        }
    }
    private func add() {
        guard !link.isEmpty, !adding else { return }
        adding = true; message = nil
        Task {
            message = await calendar.addFeed(link)
            if message == nil { link = "" }
            adding = false
        }
    }
}

struct BoardsSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var exams: ExamStore
    var body: some View {
        Toggle("Boards countdown", isOn: $model.showExams)
        if model.showExams {
            Picker("Count in", selection: $exams.unit) { ForEach(BoardsMath.Unit.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 280)
            Picker("Calm mode", selection: $exams.calm) { ForEach(ExamStore.Calm.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(maxWidth: 320)
            HStack {
                Stepper("Amber at \(exams.amberDays) days", value: $exams.amberDays, in: 7...120, step: 1)
                Stepper("Red at \(exams.redDays) days", value: $exams.redDays, in: 1...60, step: 1)
            }
            Toggle("Exam week mode", isOn: $model.examWeek)
            Text("Home shows only the countdown, readings, timer, Anki and Salah, and your Focus shortcut (Automation) runs and stays on.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            Toggle("Show the countdown in the closed notch", isOn: $exams.pinToNotch)
            Toggle("Milestone alerts (100, 60, 30, 14, 7, 3 and 1 days)", isOn: $exams.milestoneAlerts)
            Toggle("Exam-day checklist the evening before", isOn: $exams.checklistReminder)
            HStack {
                Toggle("Bedtime nudge the two nights before", isOn: $exams.bedtimeNudge)
                if exams.bedtimeNudge {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(exams.bedtimeMinutes * 60)) },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); exams.bedtimeMinutes = (c.hour ?? 23) * 60 + (c.minute ?? 0) }),
                               displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                }
            }
            Text("Add exams in the Study tab. Level 1 and Step 1 are pass/fail, so they never ask for a target score. Calm mode shows weeks only, or hides the countdown until 30 days out.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AutoQuitSettings: View {
    @ObservedObject var autoQuit: AutoQuit
    var body: some View {
        Toggle("Quit apps when their last window closes", isOn: $autoQuit.enabled)
        if autoQuit.enabled {
            if !autoQuit.trusted {
                HStack {
                    Text("Needs Accessibility to see windows close.").font(.system(size: 11)).foregroundStyle(Theme.attention)
                    Spacer()
                    PillButton(title: "Grant access", symbol: nil) { autoQuit.requestAccess() }
                }
            }
            HStack {
                Text("Never quit")
                Spacer()
                PillButton(title: "Add app", symbol: "plus") { autoQuit.pickApps() }
            }
            ForEach(autoQuit.excluded, id: \.self) { id in
                HStack(spacing: 8) {
                    if let icon = AutoQuit.icon(for: id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(AutoQuit.name(for: id)).font(.system(size: 12))
                    Spacer()
                    IconButton(symbol: "minus.circle", help: "Allow quitting", size: 20) { autoQuit.include(id) }
                }
            }
        }
        Text("Like Swift Quit: closing an app's last window quits it, the normal way, so unsaved work still asks first. Attending, Finder and menu bar utilities like DockDoor are never quit, and apps with windows on another desktop or minimized stay open.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            .onAppear { autoQuit.refreshTrust() }
    }
}

/// When the island gets out of the way.
struct StepAsideSettings: View {
    @ObservedObject var stepAside: StepAside
    var body: some View {
        Toggle("Hide when something is full screen", isOn: $stepAside.inFullscreen)
        Toggle("Hide while using these apps", isOn: $stepAside.whileUsing)
        if stepAside.whileUsing {
            ForEach(stepAside.installedApps, id: \.self) { id in
                HStack(spacing: 8) {
                    if let icon = AutoQuit.icon(for: id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    Text(AutoQuit.name(for: id)).font(.system(size: 12))
                    Spacer()
                    IconButton(symbol: "minus.circle", help: "Show over this app", size: 20) { stepAside.remove(id) }
                }
            }
            HStack {
                Spacer()
                PillButton(title: "Add app", symbol: "plus") { stepAside.pickApps() }
            }
        }
        Text("For videos, slideshows and editors like DaVinci Resolve that use the top of the screen. Alerts wait until it's back, and the menu bar icon still opens it.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The coffee cup: keeps the Mac (and screen) awake. Click toggles; right-click picks a time.
struct KeepAwakeButton: View {
    @ObservedObject var keepAwake: KeepAwake
    var body: some View {
        IconButton(symbol: keepAwake.manual ? "cup.and.saucer.fill" : "cup.and.saucer", help: help, tint: keepAwake.manual ? Theme.attention : Theme.secondary) { keepAwake.toggle() }
            .contextMenu {
                ForEach([30, 60, 120, 240], id: \.self) { minutes in
                    Button(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")") { keepAwake.set(minutes: minutes) }
                }
                Button("Until I turn it off") { keepAwake.set(minutes: nil) }
                if keepAwake.manual { Button("Turn off") { keepAwake.set(minutes: nil, on: false) } }
            }
    }
    private var help: String {
        guard let until = keepAwake.manualUntil, keepAwake.manual else { return keepAwake.agentsWorking && keepAwake.withAgents ? "Awake while agents work · click to keep the screen on" : "Keep awake" }
        return until == .distantFuture ? "Keeping awake until turned off" : "Keeping awake until \(until.formatted(date: .omitted, time: .shortened))"
    }
}

struct SnappingSettings: View {
    @ObservedObject var snapper: WindowSnapper
    var body: some View {
        Toggle("Snap windows with ⌃⌥ shortcuts", isOn: $snapper.enabled)
        if snapper.enabled {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(WindowSnapper.Region.allCases, id: \.self) { region in
                    HStack(spacing: 6) {
                        Text("⌃⌥\(region.key.label)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(snapper.taken.contains(region) ? Theme.tertiary : Theme.primary).frame(width: 38, alignment: .leading)
                        Text(region.title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            if !snapper.taken.isEmpty {
                Text("Some shortcuts are already used by another app (Rectangle?), so those stay with it.").font(.system(size: 11)).foregroundStyle(Theme.attention)
            }
            if !AXIsProcessTrusted() {
                Text("Moving other apps' windows needs Accessibility: System Settings › Privacy & Security › Accessibility › Attending.").font(.system(size: 11)).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Which tabs show in the header and in what order. Home and Settings always show.
struct TabsSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let shown = model.headerTabs
        let hidden = AppModel.choosableTabs.filter { !shown.contains($0) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, tab in
                row(tab, on: true) {
                    IconButton(symbol: "chevron.up", help: "Move left", size: 20) { move(tab, by: -1) }.disabled(index == 0)
                    IconButton(symbol: "chevron.down", help: "Move right", size: 20) { move(tab, by: 1) }.disabled(index == shown.count - 1)
                }
            }
            ForEach(hidden, id: \.self) { tab in row(tab, on: false) { EmptyView() } }
        }
        Text("Home and Settings always show; ⌘1–9 follow this order. With Agents off, Claude's questions and approvals appear on Home, and agent alerts still drop down.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
    private func row<Buttons: View>(_ tab: Tab, on: Bool, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.symbol).frame(width: 18).foregroundStyle(on ? Theme.primary : Theme.tertiary)
            Text(tab == .mirror ? "Camera" : tab.title).foregroundStyle(on ? Theme.primary : Theme.secondary)
            Spacer()
            buttons()
            Toggle("", isOn: Binding(get: { on }, set: { value in
                var tabs = model.headerTabs
                if value { tabs.append(tab) } else { tabs.removeAll { $0 == tab } }
                model.headerTabs = tabs
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.done)
        }
        .font(.system(size: 12))
    }
    private func move(_ tab: Tab, by offset: Int) {
        var tabs = model.headerTabs
        guard let index = tabs.firstIndex(of: tab), tabs.indices.contains(index + offset) else { return }
        tabs.swapAt(index, index + offset)
        model.headerTabs = tabs
    }
}

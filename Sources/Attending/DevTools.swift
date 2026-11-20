import AppKit
import SwiftUI
import AttendingCore
import WebKit

/// Command-line development aids. Each flag runs a self-check or renders images,
/// prints what it found (never secrets) and quits; normal launches skip all of this.
///
///   --expanded             open the full panel at launch
///   --event-title TEXT     show TEXT instead of real calendar event titles
///   --snapshot DIR         render every panel state to PNG
///   --pet-previews DIR     render each notch mark in every mood
///   --render-icons DIR     write the 1024 px app icon
///   --update-test          check for an update and install it without asking
///   --mirror-test, --activity-test, --spectrum-test, --claude-test,
///   --spotify-test, --tracker-test, --smoke-test   print diagnostics for 10–30 s
///   --permissions   print whether Accessibility is granted, then quit
///   --snap-test     snap the front window left then right, then quit
///   --screen-test   print how screen time sorts the front app, then quit
extension AppDelegate {
    func runDevelopmentFlags() {
        if let index = CommandLine.arguments.firstIndex(of: "--event-title"), index + 1 < CommandLine.arguments.count {
            model.calendar.titleOverride = CommandLine.arguments[index + 1]
        }
    if CommandLine.arguments.contains("--expanded") { model.setMode(.expanded) }
    if CommandLine.arguments.contains("--snap-test") {
        // Snaps the front window left, then right, printing where it lands.
        Task {
            for region in [WindowSnapper.Region.leftHalf, .rightHalf] {
                try? await Task.sleep(for: .seconds(2))
                model.snapper.snap(region)
                try? await Task.sleep(for: .milliseconds(500))
                print("SNAP \(region.rawValue) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")"); fflush(stdout)
            }
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--screen-test") {
        // How screen time sorts the front app right now.
        Task {
            try? await Task.sleep(for: .seconds(2))
            let current = ScreenTime.current()
            let titleLength = NSWorkspace.shared.frontmostApplication.flatMap { ScreenTime.frontWindowTitle(of: $0.processIdentifier) }?.count
            print("SCREEN front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") category=\(current?.0?.rawValue ?? "other") name=\(current?.1 ?? "-") titleLength=\(titleLength.map(String.init) ?? "unreadable")"); fflush(stdout)
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--prompter-demo") {
        // Starts the teleprompter on a sample script (not saved).
        model.prompter.persists = false
        model.prompter.script = "Hi, I'm a second-year med student, and this is the notch app I built for studying. It counts down to boards, tracks Anki and UWorld, and now it has a teleprompter right under the camera, so I can read this while looking at you. Hover over it and it pauses. Scroll and it moves. And it's hidden from screen recordings, so nobody sees the script."
        Task { try? await Task.sleep(for: .seconds(1)); model.prompter.start() }
    }
    if CommandLine.arguments.contains("--aside-log") {
        // Prints when the island steps aside and whether its window is on screen.
        Task {
            var last = ""
            while true {
                let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
                let line = "ASIDE hidden=\(model.stepAside.hidden) fullscreen=\(StepAside.hasFullscreenWindow(on: screen)) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") panelVisible=\(panel.isVisible) prompter=\(model.prompter.running) keysToMacOS=\(MediaKeyTap.passThrough)"
                if line != last { print(line); fflush(stdout); last = line }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    if CommandLine.arguments.contains("--move-test") {
        // Moves this copy without asking (point ATTENDING_APPLICATIONS_DIR at a test folder).
        do { try MoveToApplications.move(Bundle.main.bundleURL) } catch { print("MOVE failed: \(error.localizedDescription)"); fflush(stdout); NSApp.terminate(nil) }
    }
    if CommandLine.arguments.contains("--study-test") {
        // The 1.2 study features: page reading, pre-read finding, weak spots, lecture day,
        // exam week and a short block. Prints counts and results only, never event titles.
        Task {
            func say(_ text: String) { print(text); fflush(stdout) }
            let cases: [(String, Int, Int?)] = [("Item 12 of 40", 40, 12), ("UWorld - Question 7 / 40", 40, 7), ("Q3 of 10", 10, 3), ("Item 12 of 40", 20, nil), ("Chapter 3 of 12", 12, nil), ("Item 41 of 40", 40, nil)]
            say("READER " + cases.map { QuestionReader.match($0.0, total: $0.1) == $0.2 ? "ok" : "FAIL(\($0.0))" }.joined(separator: " "))
            let notes: [(String?, Bool)] = [("Pre-read: Guyton ch. 26", true), ("Zoom: https://zoom.us/j/1\nPlease read chapter 4 before class", true), ("Room 204", false), (nil, false), ("https://canvas.example.edu/prep", false)]
            say("PREREAD " + notes.map { (LectureDay.preRead(in: $0.0) != nil) == $0.1 ? "ok" : "FAIL(\($0.0 ?? "nil"))" }.joined(separator: " "))
            let titles: [(String, Bool)] = [("Cardio Lecture 12", true), ("Anatomy Lab", true), ("PBL Group 4", true), ("Collab call", false), ("Dentist", false), ("OMM", true)]
            say("CLASSES " + titles.map { model.lectures.isClass(UpcomingEvent(title: $0.0, start: Date(), end: Date())) == $0.1 ? "ok" : "FAIL(\($0.0))" }.joined(separator: " "))
            let topics = WeakTopics()
            topics.showDemo(["Renal": 4, "Micro": 2, "Pharm": 3, "Cardio": 1])
            say("WEAK \(topics.weakest().map { "\($0.subject)=\($0.count)" }.joined(separator: ",")) week=\(topics.missedThisWeek())")
            try? await Task.sleep(for: .seconds(4))
            let today = model.lectures.classes(on: Date(), from: model.calendar)
            let tomorrow = model.lectures.classes(on: Date().addingTimeInterval(86400), from: model.calendar)
            if CommandLine.arguments.contains("--week-events") {
                for offset in 0..<7 {
                    let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(Double(offset) * 86400))
                    for event in model.calendar.events(from: day, to: day.addingTimeInterval(86400)) {
                        say("EVENT +\(offset)d \(event.start.formatted(date: .omitted, time: .shortened)) [\(event.calendarTitle ?? "-")] \(event.title) class=\(model.lectures.isClass(event)) notes=\(event.notes?.isEmpty == false)")
                    }
                }
            }
            say("LECTURES calendar=\(model.calendarEnabled) today=\(today.count) tomorrow=\(tomorrow.count) preReads=\(tomorrow.filter { $0.preRead != nil }.count) shown=\(model.lectures.shownDay(from: model.calendar).map { Calendar.current.isDateInToday($0.day) ? "today" : "tomorrow" } ?? "none")")
            for _ in 0..<15 where model.sheets.primaryTracker == nil && !model.sheets.trackers.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            let target = model.examWeekTarget
            say("EXAMWEEK auto=\(model.autoExamWeek) on=\(model.examWeek) target=\(target.map { "\($0.name) in \(BoardsMath.calendarDays(from: Date(), to: $0.date))d" } ?? "none") wing=\(model.wingCountdown?.text ?? "none")")
            let block = model.block
            let saved = (block.questions, block.minutes)
            block.questions = 4; block.minutes = 1
            block.start()
            let start = block.run!
            block.next(); block.next()
            say("BLOCK q=\(block.run!.current)/\(start.total) ahead=\(block.ahead()) per=\(Int(start.perQuestion))s wing=\(model.idleWing > 34)")
            block.previous()
            block.end()
            say("BLOCK end answered=\(block.result?.answered ?? -1) (expect 1) running=\(block.running)")
            block.result = nil
            block.questions = saved.0; block.minutes = saved.1
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--study-shots"), index + 1 < CommandLine.arguments.count {
        // Screenshots of the 1.2 study features with sample data that's never saved.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func shoot(_ name: String) { snapshot(to: directory.appendingPathComponent("\(name).png")) }
            model.holdOpen = true
            await wait(2.5)
            model.calendar.titleOverride = nil
            let today = Calendar.current.startOfDay(for: Date())
            func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { today.addingTimeInterval(Double(day) * 86400 + Double(hour) * 3600 + Double(minute) * 60) }
            let hour = Calendar.current.component(.hour, from: Date())
            model.lectures.showDemo([
                .init(id: "a", title: "Renal Physiology Lecture", start: at(0, max(0, hour - 2)), end: at(0, max(0, hour - 1)), location: "Room 1"),
                .init(id: "b", title: "Anatomy Lab: Retroperitoneum", start: at(0, hour, 30), end: at(0, hour + 1, 30), location: "Lab B", preRead: "Pre-read: Netter plates 312–318"),
                .init(id: "c", title: "PBL Case 6", start: at(0, hour + 2), end: at(0, hour + 3)),
                .init(id: "d", title: "Cardio Lecture 14", start: at(1, 8), end: at(1, 9), preRead: "Read Guyton ch. 20 before class"),
                .init(id: "e", title: "OMM Lab", start: at(1, 10), end: at(1, 12)),
                .init(id: "f", title: "Pharmacology: Diuretics", start: at(1, 13), end: at(1, 14), preRead: "Prep: watch the diuretics module"),
            ])
            model.weakTopics.showDemo(["Renal": 7, "Micro": 5, "Pharm": 4, "Cardio": 2, "Biochem": 1])
            // Home with today's classes.
            model.selectedTab = .home; model.setMode(.expanded)
            await wait(1.5); shoot("home-classes")
            // Study tab with a block under way.
            model.block.showDemo(current: 18, total: 40, minutesIn: 24, minutes: 60)
            model.objectWillChange.send(); model.onModeChange?()
            model.selectedTab = .study
            await wait(1.5); shoot("study-block")
            @MainActor func render<V: View>(_ name: String, width: CGFloat, _ view: V) {
                let renderer = ImageRenderer(content: view.frame(width: width).padding(16).background(Theme.background).environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
            render("card-block-running", width: 340, BlockCard(model: model, block: model.block))
            render("card-weak", width: 290, WeakTopicsCard(model: model, topics: model.weakTopics))
            // Hover preview and the closed notch during the block.
            model.setMode(.preview); await wait(1.2); shoot("preview-block")
            model.setMode(.idle); await wait(1.2); shoot("wing-block")
            // The block's result, ready for tagging misses.
            model.block.cancel()
            model.block.result = .init(total: 40, answered: 40, elapsed: 3390, timeUp: false)
            render("card-block-result", width: 340, BlockCard(model: model, block: model.block))
            model.block.result = nil
            render("card-block-setup", width: 340, BlockCard(model: model, block: model.block))
            model.block.result = .init(total: 40, answered: 40, elapsed: 3390, timeUp: false)
            model.selectedTab = .study; model.setMode(.expanded)
            await wait(1.5); shoot("study-result")
            model.block.result = nil
            // Exam week: the quiet hover preview and wing.
            let shortcuts = (model.focusStartShortcut, model.focusEndShortcut)
            model.focusStartShortcut = ""; model.focusEndShortcut = ""
            let wasExamWeek = model.examWeek
            model.examWeek = true
            model.setMode(.preview); await wait(1.2); shoot("preview-examweek")
            model.examWeek = wasExamWeek
            model.focusStartShortcut = shortcuts.0; model.focusEndShortcut = shortcuts.1
            // Tomorrow's summary alert.
            model.setMode(.idle); await wait(0.8)
            model.raise(NotchAlert(title: "Tomorrow: 3 classes, 2 pre-reads", subtitle: "First at 8:00 AM · Cardio Lecture 14", symbol: "books.vertical.fill", color: Theme.working, target: .home, actionTitle: "Show", action: {}))
            await wait(1.2); shoot("alert-tomorrow")
            model.alert = nil
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--approval-auto"), index + 1 < CommandLine.arguments.count {
        // Answers the first approval request (allow or deny) and prints what arrived, for bridge tests.
        let allow = CommandLine.arguments[index + 1] == "allow"
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let request = model.claudeApprovals.first else { continue }
                print("APPROVAL provider=\(request.provider.rawValue) tool=\(request.toolName) command=\(request.command ?? "-") alert=\(model.alert?.title ?? "-")"); fflush(stdout)
                model.respondClaude(request, decision: allow ? .allowOnce : .deny)
                try? await Task.sleep(for: .seconds(1))
                break
            }
            // Merge check: an existing hook is kept and the entry is added once.
            if let bridge = ClaudeHooks.bridge {
                let first = (try? CodexHooks.merged(["hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/policy"]]]], "Stop": [["hooks": [["type": "command", "command": "say done"]]]]]], bridge: bridge.path)) ?? [:]
                let twice = (try? CodexHooks.merged(first, bridge: bridge.path)) ?? [:]
                let entries = ((twice["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
                print("MERGE groups=\(entries.count) stop=\(((twice["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count ?? 0) idempotent=\(NSDictionary(dictionary: first).isEqual(to: twice)) installed=\(CodexHooks.installed)"); fflush(stdout)
            }
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--activity-quiet-test") {
        // Writes sample files into ~/Movies/Attending activity test and prints which alerts appear:
        // a render cache (ignored), a 6 s save (no alert), and two 25 s exports that pause
        // midway and finish together (one shared alert). The folder is removed afterward.
        Task {
            func say(_ text: String) { print(text); fflush(stdout) }
            let paths = ["/Users/x/Movies/CacheClip/a.mov", "/Volumes/SSK/Project/OptimizedMedia/b.mov", "/Users/x/Movies/Edit.fcpbundle/Render Files/c.mov", "/Users/x/Movies/Export 1.mp4", "/Volumes/SSK/TikTok/final.mov"]
            say("WORKING " + paths.map { "\(($0 as NSString).lastPathComponent)=\(ActivityCenter.isWorkingFile($0))" }.joined(separator: " "))
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Attending activity test", isDirectory: true)
            let cache = folder.appendingPathComponent("CacheClip", isDirectory: true)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            model.setLiveActivities(true)
            try? await Task.sleep(for: .seconds(2))
            var seen: [String] = []
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    if let title = model.alert?.title, seen.last != title { seen.append(title); say("ALERT \(title) · \(model.alert?.subtitle ?? "")") }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            // Written by a separate shell process, as an editor would (the watcher ignores Attending's own writes).
            func grow(_ url: URL, seconds: Int, pauseAt: Int? = nil) async {
                let pause = pauseAt.map { "[ $i -eq \($0) ] && sleep 12; " } ?? ""
                let script = "f=\"$1\"; : > \"$f\"; i=0; while [ $i -lt \(seconds) ]; do \(pause)head -c 200000 /dev/zero >> \"$f\"; sleep 1; i=$((i+1)); done"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script, "sh", url.path]
                try? process.run()
                while process.isRunning { try? await Task.sleep(for: .milliseconds(300)) }
            }
            async let cacheFile: Void = grow(cache.appendingPathComponent("render cache.mov"), seconds: 25)
            async let shortSave: Void = grow(folder.appendingPathComponent("quick save.mov"), seconds: 6)
            async let exportA: Void = grow(folder.appendingPathComponent("Export A.mp4"), seconds: 25, pauseAt: 10)
            async let exportB: Void = grow(folder.appendingPathComponent("Export B.mp4"), seconds: 27)
            _ = await (cacheFile, shortSave, exportA, exportB)
            try? await Task.sleep(for: .seconds(28))
            watch.cancel()
            say("TRACKED \(model.activities.activities.filter { $0.url.path.contains("Attending activity test") }.map { "\($0.name)=\($0.state)" }.joined(separator: ", "))")
            say("ALERTS \(seen.count)")
            try? FileManager.default.removeItem(at: folder)
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--canvas-test"), index + 2 < CommandLine.arguments.count {
        // Connects a separate Canvas client to a test server (address, flag file for a new
        // announcement) and prints what it read. Run with ATTENDING_DATA_DIR set to a scratch folder.
        let address = CommandLine.arguments[index + 1], flag = CommandLine.arguments[index + 2]
        Task {
            func say(_ text: String) { print(text); fflush(stdout) }
            let savedSeen = UserDefaults.standard.array(forKey: "canvasSeen")
            UserDefaults.standard.removeObject(forKey: "canvasSeen")
            let canvas = CanvasService()
            var alerts: [String] = []
            canvas.onNewAnnouncement = { alerts.append($0.title) }
            say("BADTOKEN \(await canvas.connect(address: address, token: "wrong") ?? "accepted")")
            say("BADADDRESS \(await canvas.connect(address: "not a url", token: "x") ?? "accepted")")
            say("CONNECT \(await canvas.connect(address: address, token: "test-token") ?? "ok") user=\(canvas.userName ?? "-")")
            for _ in 0..<20 where canvas.updatedAt == nil { try? await Task.sleep(for: .milliseconds(250)) }
            say("ANNOUNCEMENTS \(canvas.announcements.map { "\($0.title)|\($0.course)|unread=\($0.unread)|\($0.preview)" })")
            say("DUE \(canvas.due.map { "\($0.title)|\($0.kind)|\($0.url?.absoluteString ?? "-")" })")
            say("FEED \(canvas.calendarFeed ?? "-") alertsOnFirstFetch=\(alerts.count)")
            FileManager.default.createFile(atPath: flag, contents: Data())
            await canvas.refresh()
            say("NEW alerts=\(alerts)")
            await canvas.refresh()
            say("AGAIN alerts=\(alerts.count)")
            let file = AppPaths.directory.appendingPathComponent("canvas.json")
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int).map { String($0, radix: 8) } ?? "-"
            say("TOKENFILE mode=\(mode) in=\(AppPaths.directory.path.hasPrefix("/private/tmp") || AppPaths.directory.path.hasPrefix("/tmp"))")
            canvas.disconnect()
            say("DISCONNECT fileGone=\(!FileManager.default.fileExists(atPath: file.path))")
            if let savedSeen { UserDefaults.standard.set(savedSeen, forKey: "canvasSeen") } else { UserDefaults.standard.removeObject(forKey: "canvasSeen") }
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--connect-shots"), index + 1 < CommandLine.arguments.count {
        // Home and Study with sample Canvas and Reminders (never saved), and the Salah card in Shia timing.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            @MainActor func render<V: View>(_ name: String, width: CGFloat, _ view: V) {
                let renderer = ImageRenderer(content: view.frame(width: width).padding(16).background(Theme.background).environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            let now = Date()
            model.canvas.showDemo(announcements: [
                .init(id: 1, title: "Exam 3 moved to Room 204", course: "Cardiopulmonary System", posted: now.addingTimeInterval(-5 * 3600), url: nil, preview: "Bring your ID.", unread: true),
                .init(id: 2, title: "OMM lab slides posted", course: "OMM II", posted: now.addingTimeInterval(-3 * 86400), url: nil, preview: "", unread: false),
                .init(id: 3, title: "Office hours this week", course: "Clinical Skills", posted: now.addingTimeInterval(-4 * 86400), url: nil, preview: "", unread: false),
            ], due: [
                .init(id: "a", title: "Case write-up 4", course: "Cardiopulmonary System", due: now.addingTimeInterval(20 * 3600), kind: "Assignment", url: nil),
                .init(id: "b", title: "OMM quiz 6", course: "OMM II", due: now.addingTimeInterval(4 * 86400), kind: "Quiz", url: nil),
                .init(id: "c", title: "Ethics reflection", course: "Clinical Skills", due: now.addingTimeInterval(6 * 86400), kind: "Discussion", url: nil),
            ])
            let today = Calendar.current.startOfDay(for: now)
            model.reminders.showDemo([
                .init(id: "1", title: "Email Dr. Patel about shadowing", due: today.addingTimeInterval(-86400), hasTime: false, list: "School", color: .systemOrange, flagged: true),
                .init(id: "2", title: "Pick up white coat", due: today.addingTimeInterval(17 * 3600), hasTime: true, list: "Personal", color: .systemBlue, flagged: false),
                .init(id: "3", title: "Renew BLS", due: today.addingTimeInterval(3 * 86400), hasTime: false, list: "School", color: .systemOrange, flagged: false),
            ])
            let wasEnabled = model.reminders.enabled
            render("canvas", width: 360, CanvasCard(canvas: model.canvas))
            render("canvas-compact", width: 360, CanvasCard(canvas: model.canvas, compact: true))
            model.reminders.enabled = true
            render("reminders", width: 300, RemindersCard(reminders: model.reminders))
            let method = model.salah.method
            model.salah.method = .jafari
            try? await Task.sleep(for: .seconds(1))
            render("salah-shia", width: 300, SalahCard(salah: model.salah))
            print("SHIA \(model.salah.times[.sunset].map { $0.formatted(date: .omitted, time: .shortened) } ?? "-") maghrib=\(model.salah.times[.maghrib].map { $0.formatted(date: .omitted, time: .shortened) } ?? "-") midnight=\(model.salah.midnight.map { $0.formatted(date: .omitted, time: .shortened) } ?? "-") dhuhrEnds=\(model.salah.end(of: .dhuhr).map { $0.formatted(date: .omitted, time: .shortened) } ?? "-")"); fflush(stdout)
            model.salah.method = method
            model.reminders.enabled = wasEnabled
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--asked-assets"), index + 1 < CommandLine.arguments.count {
        // Every screen for the "you asked, I built it" video, with sample data that's never saved.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func shoot(_ name: String) { snapshot(to: directory.appendingPathComponent("\(name).png")) }
            @MainActor func render<V: View>(_ name: String, width: CGFloat, _ view: V) {
                let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, .dark))
                renderer.scale = 3
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
            model.holdOpen = true
            model.cleanScreen.set(false)
            await wait(2.5)
            let now = Date(), today = Calendar.current.startOfDay(for: now)
            let shortcuts = (model.focusStartShortcut, model.focusEndShortcut)
            model.focusStartShortcut = ""; model.focusEndShortcut = ""
            // Sample study progress for the glance tiles (never saved).
            model.sheets.showDemo(done: 0.62)
            var anki = AnkiService.Stats()
            anki.dueReviews = 38; anki.learning = 6; anki.reviewedToday = 312; anki.minutesToday = 74; anki.streak = 47; anki.dueTomorrow = 140
            anki.week = [286, 341, 298, 402, 330, 275, 312]
            model.anki.demoStats = anki
            await wait(0.5)
            // 1. A block under way: the wings and the hover strip.
            model.block.showDemo(current: 18, total: 40, minutesIn: 24, minutes: 60)
            model.objectWillChange.send(); model.onModeChange?()
            model.setMode(.idle); await wait(1.2); shoot("idle-block")
            model.setMode(.preview); await wait(1.2); shoot("preview-block")
            model.block.cancel()
            model.setMode(.idle); await wait(1)
            // 2. Canvas: the announcement dropping down, then the card.
            @MainActor func drop(_ name: String, _ alert: NotchAlert) async {
                model.setMode(.idle); await wait(0.8)
                model.raise(alert); await wait(1.3); shoot(name)
                model.alert = nil; model.setMode(.idle); await wait(0.9)
            }
            await drop("alert-canvas", NotchAlert(title: "Exam 3 moved to Room 204", subtitle: "Cardiopulmonary System · Canvas announcement", symbol: "megaphone.fill", color: Theme.working, target: .study, actionTitle: "Open", action: {}))
            model.canvas.showDemo(announcements: [
                .init(id: 1, title: "Exam 3 moved to Room 204", course: "Cardiopulmonary System", posted: now.addingTimeInterval(-600), url: nil, preview: "", unread: true),
                .init(id: 2, title: "OMM lab slides posted", course: "OMM II", posted: now.addingTimeInterval(-3 * 86400), url: nil, preview: "", unread: false),
            ], due: [
                .init(id: "a", title: "Case write-up 4", course: "Cardiopulmonary System", due: now.addingTimeInterval(20 * 3600), kind: "Assignment", url: nil),
                .init(id: "b", title: "OMM quiz 6", course: "OMM II", due: now.addingTimeInterval(4 * 86400), kind: "Quiz", url: nil),
                .init(id: "c", title: "Ethics reflection", course: "Clinical Skills", due: now.addingTimeInterval(6 * 86400), kind: "Discussion", url: nil),
            ])
            render("card-canvas", width: 380, CanvasCard(canvas: model.canvas).padding(10).background(Color.black))
            // 3. Lecture day: tomorrow's summary, then the classes in the Today card.
            await drop("alert-tomorrow", NotchAlert(title: "Tomorrow: 3 classes, 3 pre-reads", subtitle: "First at 8:00 AM · Cardio Lecture 14", symbol: "books.vertical.fill", color: Theme.working, target: .home, actionTitle: "Show", action: {}))
            func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { today.addingTimeInterval(Double(day) * 86400 + Double(hour) * 3600 + Double(minute) * 60) }
            model.lectures.showDemo([
                .init(id: "d", title: "Cardio Lecture 14", start: at(1, 8), end: at(1, 9), preRead: "Read Guyton ch. 20 before class"),
                .init(id: "e", title: "OMM Lab", start: at(1, 10), end: at(1, 12)),
                .init(id: "f", title: "Pharmacology: Diuretics", start: at(1, 13), end: at(1, 14), preRead: "Prep: watch the diuretics module"),
            ])
            render("card-classes", width: 330, Card(padding: 12) { ClassesSection(model: model, lectures: model.lectures, calendar: model.calendar, sheets: model.sheets) }.padding(10).background(Color.black))
            // 4. Weak spots: misses tapped in on the beat, then the week's ranking.
            let taps: [[String: Int]] = [[:], ["Cardio": 1], ["Cardio": 1, "Renal": 1], ["Cardio": 1, "Renal": 2], ["Cardio": 1, "Renal": 2, "Micro": 1], ["Cardio": 1, "Renal": 3, "Micro": 1]]
            for (i, counts) in taps.enumerated() {
                render("tagger-\(i)", width: 380, Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Block finished · 40 of 40")
                        Text("What did you miss? Tap a subject for each one.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        MissTagger(counts: .constant(counts))
                    }
                }.padding(10).background(Color.black))
            }
            model.weakTopics.showDemo(["Renal": 7, "Micro": 5, "Pharm": 4, "Cardio": 2])
            render("card-weak", width: 330, WeakTopicsCard(model: model, topics: model.weakTopics).padding(10).background(Color.black))
            // 5. Apple Reminders, before and after one is checked off.
            let reminders: [RemindersService.Item] = [
                .init(id: "1", title: "Email Dr. Patel about shadowing", due: today.addingTimeInterval(-86400), hasTime: false, list: "School", color: .systemOrange, flagged: true),
                .init(id: "2", title: "Pick up white coat", due: today.addingTimeInterval(17 * 3600), hasTime: true, list: "Personal", color: .systemBlue, flagged: false),
                .init(id: "3", title: "Renew BLS", due: today.addingTimeInterval(3 * 86400), hasTime: false, list: "School", color: .systemOrange, flagged: false),
            ]
            let remindersWere = model.reminders.enabled
            model.reminders.showDemo(reminders)
            model.reminders.enabled = true
            render("card-reminders", width: 330, RemindersCard(reminders: model.reminders, showsAdd: false).padding(10).background(Color.black))
            // 6. Exam week: it turns itself on, and the notch goes quiet.
            model.exams.showDemo([BoardExam(kind: .block, date: today.addingTimeInterval(5 * 86400 + 8 * 3600), customName: "Cardio block")])
            await drop("alert-examweek", NotchAlert(title: "Exam week is on", subtitle: "Exam 3 is in 3 days. The notch stays quiet until it's over.", symbol: "moon.fill", color: Theme.attention, target: .home, actionTitle: "Turn off", action: {}))
            let examWeekWas = model.examWeek
            model.examWeek = true
            model.setMode(.idle); await wait(1.2); shoot("idle-examweek")
            model.setMode(.preview); await wait(1.2); shoot("preview-examweek")
            model.examWeek = examWeekWas
            model.focusStartShortcut = shortcuts.0; model.focusEndShortcut = shortcuts.1
            model.reminders.enabled = remindersWere
            model.setMode(.idle); await wait(0.5)
            print("ASKED done"); fflush(stdout)
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--mission-control-check") {
        // The detection against sample window lists: a visible Dock bar, Mission Control, other apps.
        func window(_ owner: String, _ layer: Int, _ w: CGFloat, _ h: CGFloat) -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer, kCGWindowBounds as String: CGRect(x: 0, y: 0, width: w, height: h).dictionaryRepresentation]
        }
        let screen = [CGSize(width: 1710, height: 1112)], two = [CGSize(width: 1710, height: 1112), CGSize(width: 2560, height: 1440)]
        let cases: [(String, [[String: Any]], [CGSize], Bool)] = [
            ("visible Dock bar", [window("Dock", 20, 1710, 78)], screen, false),
            ("Dock on the side", [window("Dock", 20, 80, 900)], screen, false),
            ("Mission Control", [window("Dock", 20, 1710, 1112)], screen, true),
            ("Mission Control + Dock bar", [window("Dock", 20, 1710, 78), window("Dock", 20, 1710, 1112)], screen, true),
            ("Mission Control on external display", [window("Dock", 20, 2560, 1440)], two, true),
            ("full-screen app at layer 20", [window("Safari", 20, 1710, 1112)], screen, false),
            ("nothing", [], screen, false),
        ]
        print("MISSIONCONTROL " + cases.map { "\($0.0)=\(AppDelegate.isMissionControl($0.1, screens: $0.2) == $0.3 ? "ok" : "FAIL")" }.joined(separator: ", ") + " now=\(AppDelegate.missionControlOpen)"); fflush(stdout)
        NSApp.terminate(nil)
    }
    if CommandLine.arguments.contains("--mission-control-test") {
        // Opens the hover preview, then Mission Control for two seconds, printing the island's state.
        Task {
            func say(_ text: String) { print(text); fflush(stdout) }
            func toggle() { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"]) }
            try? await Task.sleep(for: .seconds(2))
            model.setMode(.preview)
            try? await Task.sleep(for: .seconds(0.6))
            say("BEFORE mode=\(model.mode) missionControl=\(AppDelegate.missionControlOpen)")
            toggle()
            try? await Task.sleep(for: .seconds(1.2))
            say("DURING mode=\(model.mode) missionControl=\(AppDelegate.missionControlOpen)")
            toggle()
            try? await Task.sleep(for: .seconds(1.5))
            say("AFTER mode=\(model.mode) missionControl=\(AppDelegate.missionControlOpen)")
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--reader-test") {
        // Starts a 4-question block and prints the question number read from the front window for 20 s.
        Task {
            let block = model.block
            let saved = (block.questions, block.minutes)
            block.questions = 4; block.minutes = 2
            block.start()
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                print("READ front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") q=\(block.run?.current ?? -1) reading=\(block.run?.reading ?? false)"); fflush(stdout)
            }
            block.cancel()
            block.questions = saved.0; block.minutes = saved.1
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--tracker-pick-test") {
        // Picks each tracker in turn and prints what the Study tab, hover glance and Home follow.
        Task {
            for _ in 0..<20 where model.sheets.trackers.contains(where: { if case .loaded = model.sheets.states[$0.id] { return false }; return true }) {
                try? await Task.sleep(for: .seconds(1))
            }
            let original = model.sheets.pickedID
            print("DEFAULT pick=\(original.isEmpty ? "none" : "set") -> focus=\(model.sheets.primaryTracker?.summary.shortName ?? "none") next=\(model.glanceReading?.item.title ?? "none")"); fflush(stdout)
            for tracker in model.sheets.trackers {
                model.sheets.pickedID = tracker.id.uuidString
                let focus = model.sheets.primaryTracker?.summary
                print("PICK \(tracker.label.isEmpty ? "-" : tracker.label) -> focus=\(focus?.shortName ?? "none") next=\(model.glanceReading?.item.title ?? "none") daysLeft=\(focus?.daysLeft.map(String.init) ?? "-")"); fflush(stdout)
            }
            model.sheets.pickedID = original
            NSApp.terminate(nil)
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--gemini-capture"), index + 1 < CommandLine.arguments.count {
        // Just the Gemini frames, for the update video.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model.holdOpen = true
            try? await Task.sleep(for: .seconds(2))
            await captureGemini(directory)
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--drag-test") {
        // Drags the island to the bottom of the screen and back, through the real drag code.
        Task {
            try? await Task.sleep(for: .seconds(2))
            let original = model.islandAnchor
            @MainActor func drag(to target: NSPoint) async {
                let start = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
                _ = handleIslandDrag(.leftMouseDown, window: panel.windowNumber, at: start)
                for step in 1...12 {
                    let t = CGFloat(step) / 12
                    _ = handleIslandDrag(.leftMouseDragged, window: panel.windowNumber, at: NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                _ = handleIslandDrag(.leftMouseUp, window: panel.windowNumber, at: target)
                try? await Task.sleep(for: .seconds(1.5))
                print("DRAG to (\(Int(target.x)), \(Int(target.y))) -> anchor=\(model.islandAnchor.rawValue) frame=\(panel.frame.integral) mode=\(model.mode)"); fflush(stdout)
            }
            let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
            let f = screen.visibleFrame
            await drag(to: NSPoint(x: f.midX + 40, y: f.minY + 60))
            await drag(to: NSPoint(x: f.maxX - 80, y: f.maxY - 30))
            await drag(to: NSPoint(x: f.midX - 10, y: screen.frame.maxY - 10))
            model.islandAnchor = original
            NSApp.terminate(nil)
        }
    }
    if CommandLine.arguments.contains("--hooks-check") {
        // Compares Claude's settings with what Connect would write, without writing.
        var line = "HOOKS installed=\(ClaudeHooks.installed)"
        if let bridge = ClaudeHooks.bridge, let data = try? Data(contentsOf: ClaudeHooks.settingsURL),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let merged = try? ClaudeHooks.merged(settings, bridge: bridge.path)
            line += " unchanged=\((merged?["hooks"] as? NSDictionary)?.isEqual(to: settings["hooks"] as? [String: Any] ?? [:]) ?? false)"
            var empty = (try? ClaudeHooks.merged(["hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "afplay done.aiff"]]]]]], bridge: bridge.path)) ?? [:]
            let stop = (empty["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
            line += " keepsOthers=\(stop.count == 2) events=\((empty["hooks"] as? [String: Any])?.count ?? 0)"
            empty = [:]
        }
        print(line); fflush(stdout)
        NSApp.terminate(nil)
    }
    if CommandLine.arguments.contains("--whats-new") {
        // Shows What's New for this version and, with --shot PATH, saves it as a PNG and quits.
        print("WHATSNEW version=\(WhatsNew.version) items=\(WhatsNew.highlights().count) parse=\(WhatsNew.section("1.0.0", in: "## 1.1.0\n- a\n## 1.0.0\n- **One:** x\n  more\n- two\n## 0.9\n- z") == ["**One:** x more", "two"])"); fflush(stdout)
        model.whatsNew.show()
        if let index = CommandLine.arguments.firstIndex(of: "--shot"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { try? await Task.sleep(for: .seconds(2)); model.whatsNew.snapshot(to: url); NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--onboarding") {
        // Shows the welcome (or, with --setup, the checklist) regardless of whether it was seen.
        model.onboarding.show(step: CommandLine.arguments.contains("--setup") ? .setup : .welcome)
        if let index = CommandLine.arguments.firstIndex(of: "--shot"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { try? await Task.sleep(for: .seconds(2)); model.onboarding.snapshot(to: url); NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--diagnostics") {
        print(Diagnostics.summary()); fflush(stdout)
        NSApp.terminate(nil)
    }
    if CommandLine.arguments.contains("--permissions") {
        print("PERMISSIONS accessibility=\(AXIsProcessTrusted()) bundle=\(Bundle.main.bundleIdentifier ?? "-") path=\(Bundle.main.bundlePath)"); fflush(stdout)
        NSApp.terminate(nil)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count { runSnapshots(URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) }
    if CommandLine.arguments.contains("--update-test") {
        Task {
            await model.updater.check(userInitiated: true)
            print("UPDATE current=\(model.updater.current) state=\(model.updater.state) release=\(model.updater.release?.version ?? "-")")
            if model.updater.state == .available { model.updater.install() }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if case .failed(let message) = model.updater.state { print("UPDATE failed: \(message)"); break }
            }
        }
    }
    if CommandLine.arguments.contains("--mirror-test") {
        // Development aid: reports camera pipeline state without the UI.
        Task {
            model.holdOpen = true
            model.open(.mirror)
            for second in 1...8 {
                try? await Task.sleep(for: .seconds(1))
                print("MIRROR t=\(second) \(model.mirror.diagnostics)")
                // With --capture, one photo at 3 s; reports its size, not its contents.
                if second == 3 && CommandLine.arguments.contains("--capture") { model.mirror.zoom = 1.5; model.mirror.shutter() }
                if second == 6, let index = CommandLine.arguments.firstIndex(of: "--mirror-snapshot"), index + 1 < CommandLine.arguments.count {
                    snapshot(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
            }
            if let url = model.mirror.lastPhoto, let rep = NSImageRep(contentsOf: url) {
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("MIRROR photo \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh) \(bytes / 1024) KB")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--pet-previews"), index + 1 < CommandLine.arguments.count {
        // Development aid: renders every notch mark in every mood, large, on black.
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = UserDefaults.standard.string(forKey: "pet")
        for pet in PetKind.allCases {
            UserDefaults.standard.set(pet.rawValue, forKey: "pet")
            let sheet = HStack(spacing: 28) {
                ForEach([SessionStatus.idle, .working, .attention, .completed], id: \.self) { mood in
                    VStack(spacing: 10) {
                        NotchMark(mood: mood, animate: false, height: 110)
                        Text(mood.title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(30).background(Color.black)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(pet.rawValue).png"))
            }
        }
        UserDefaults.standard.set(original, forKey: "pet")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if CommandLine.arguments.contains("--activity-test") {
        // Development aid: prints live activities once a second.
        Task {
            for second in 1...28 {
                try? await Task.sleep(for: .seconds(1))
                let line = model.activities.activities.map { "\($0.name) \($0.kind) \($0.state) \($0.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "-") \($0.sizeText)" }.joined(separator: " | ")
                print("ACT t=\(second) \(line.isEmpty ? "none" : line) alert=\(model.alert?.title ?? "-")")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-icons"), index + 1 < CommandLine.arguments.count {
        // Development aid: writes the 1024 px app icon (AppIcon.png).
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: AppIconArt())
        renderer.scale = 1
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("AppIcon.png"))
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if CommandLine.arguments.contains("--spectrum-test") {
        // Development aid: prints visualizer levels while media plays.
        Task {
            for second in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                model.media.updateSpectrum(awake: true)
                let levels = model.media.spectrum.levels.map { String(format: "%.2f", $0) }.joined(separator: " ")
                print("SPECTRUM t=\(second) playing=\(model.media.track?.playing ?? false) running=\(model.media.spectrum.running) live=\(model.media.spectrum.live) \(levels)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--claude-test") {
        // Development aid: what claude.ai shows this session, and whether usage reads.
        Task {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
            view.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
            try? await Task.sleep(for: .seconds(12))
            let probe = """
            const t = document.body ? document.body.innerText : '';
            return {title: document.title, path: location.pathname, login: /log in|continue with google|continue with email/i.test(t), verify: /verify you are human|checking your browser|cloudflare/i.test(t), unsupported: /unsupported|update your browser/i.test(t), chars: t.length};
            """
            let page = try? await view.callAsyncJavaScript(probe, contentWorld: .defaultClient)
            print("CLAUDE page \(String(describing: page))")
            let usage = """
            const r = await fetch('/api/organizations', {credentials: 'include'});
            let orgs = null; try { orgs = await r.json(); } catch (e) {}
            if (!Array.isArray(orgs) || !orgs.length) return {orgsStatus: r.status};
            const org = orgs.find(o => (o.capabilities || []).some(c => String(c).startsWith('claude_'))) || orgs[0];
            const u = await fetch(`/api/organizations/${org.uuid}/usage`, {credentials: 'include'});
            let body = null; try { body = await u.json(); } catch (e) {}
            return {orgsStatus: r.status, usageStatus: u.status, keys: body ? Object.keys(body) : null, five: body && body.five_hour ? body.five_hour.utilization : null};
            """
            let result = try? await view.callAsyncJavaScript(usage, contentWorld: .defaultClient)
            print("CLAUDE usage \(String(describing: result))")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--spotify-test") {
        // Development aid: read-only Spotify checks (no playback or library changes).
        Task {
            let spotify = model.media.spotify
            print("SPOTIFY connected=\(spotify.connected)")
            await spotify.refreshPlayer()
            print("SPOTIFY smartShuffle=\(spotify.smartShuffle) context=\(spotify.context?.name ?? "none") smartPick=\(spotify.isSmartPick) liked=\(String(describing: spotify.liked))")
            await spotify.loadPlaylists()
            print("SPOTIFY playlists=\(spotify.playlists.count)")
            await spotify.refreshQueue()
            print("SPOTIFY queue=\(spotify.spotifyQueue.count) notice=\(spotify.notice ?? "-")")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--tracker-test") {
        // Development aid: prints each tracker's parsed state (no secrets).
        Task {
            let started = Date()
            print("ANKI stats=\(model.anki.stats.map { "due \($0.dueReviews) done \($0.reviewedToday)" } ?? "nil") profile=\(model.anki.profile ?? "nil")")
            model.sheets.refreshAll()
            defer {
                print("TRACKER elapsed \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                print("ANKI after load: \(model.anki.stats.map { "due \($0.dueReviews) done \($0.reviewedToday) streak \($0.streak)" } ?? "nil")")
            }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if model.sheets.trackers.allSatisfy({ if case .loading = model.sheets.states[$0.id] ?? .loading { return false }; return true }) { break }
            }
            for tracker in model.sheets.trackers {
                switch model.sheets.states[tracker.id] ?? .idle {
                case .loaded(let summary):
                    print("TRACKER \(summary.title): \(summary.items.count) readings, \(summary.chaptersDone) done, \(summary.pagesLeft)/\(summary.pagesTotal) pages left, \(Int(summary.fractionLeft * 100))% left, days \(summary.daysLeft.map(String.init) ?? "-")")
                    for item in summary.items.prefix(40) { print("  [\(item.done ? "x" : " ")] r\(item.row) \(item.label) | \(item.book) | \(item.pages)p | \(item.section ?? "-")") }
                case let other: print("TRACKER \(tracker.label): \(other)")
                }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    if CommandLine.arguments.contains("--smoke-test") {
        Task {
            try? await Task.sleep(for: .seconds(2))
            let f = panel.frame
            print("ATTENDING_SMOKE screens=\(NSScreen.screens.count) frame=\(f) visible=\(panel.isVisible) mode=\(model.mode)")
            // Leave the Swift task before AppKit enters its termination loop.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    }

    /// Renders each panel state to PNG without screen-recording access.
    func runSnapshots(_ directory: URL) {
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model.holdOpen = true
            // --no-media: leave out what's playing (a browser video, say). Otherwise, when
            // something plays, wait for its artwork so the player isn't captured blank.
            if CommandLine.arguments.contains("--no-media") { model.media.hiddenForCapture = true }
            for _ in 0..<32 where model.media.track != nil && model.media.artwork == nil { try? await Task.sleep(for: .milliseconds(250)) }
            // --salah-demo: Fajr and Dhuhr prayed, twenty minutes into Asr, so the card reads in order.
            if CommandLine.arguments.contains("--salah-demo") {
                for _ in 0..<20 where model.salah.times[.asr] == nil { try? await Task.sleep(for: .milliseconds(250)) }
                if let asr = model.salah.times[.asr] { model.salah.showDemo(prayed: [.fajr, .dhuhr], at: asr.addingTimeInterval(20 * 60)) }
            }
            // --boards-demo: a sample COMLEX countdown with a question bank and practice scores.
            if CommandLine.arguments.contains("--boards-demo") {
                let day = Calendar.current.startOfDay(for: Date())
                var exam = BoardExam(kind: .comlex1, date: Calendar.current.date(byAdding: .day, value: 42, to: day)!.addingTimeInterval(8 * 3600))
                exam.dedicatedStart = Calendar.current.date(byAdding: .day, value: -14, to: day)
                exam.daysOff = [1]; exam.bankName = "UWorld"; exam.bankTotal = 3600; exam.bankDone = 3100
                exam.practice = [.init(name: "COMSAE 1", date: day.addingTimeInterval(-20 * 86400), score: 480), .init(name: "COMSAE 2", date: day.addingTimeInterval(-12 * 86400), score: 535),
                                 .init(name: "COMSAE 3", date: day.addingTimeInterval(-4 * 86400), score: 578), .init(name: "COMSAE 4", date: day.addingTimeInterval(6 * 86400))]
                // For the update video: sample Study progress (never saved).
                if CommandLine.arguments.contains("--video-assets") {
                    model.sheets.showDemo(done: 0.86)
                    var anki = AnkiService.Stats()
                    anki.dueReviews = 38; anki.learning = 6; anki.reviewedToday = 312; anki.minutesToday = 74; anki.streak = 47; anki.dueTomorrow = 140
                    anki.week = [286, 341, 298, 402, 330, 275, 312]
                    anki.cardOfDay = (front: "Drug of choice for absence seizures?", back: "Ethosuximide")
                    model.anki.demoStats = anki
                }
                let shelf = BoardExam(kind: .shelf, date: Calendar.current.date(byAdding: .day, value: 70, to: day)!, customName: "IM COMAT")
                model.exams.showDemo([exam, shelf])
                model.exams.pinToNotch = true
                let (value, label) = model.exams.countdown(exam)
                if let card = BoardsShareCard.render(exam, value: value, label: label) { try? FileManager.default.moveItem(at: card, to: directory.appendingPathComponent("boards-share.png")) }
                let recap = ImageRenderer(content: RecapShareCard(week: .init(focusMinutes: 765, pages: 412, questions: 480, reviews: 2140)))
                if let image = recap.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent("recap-share.png")) }
            }
            let states: [(String, PanelMode, Tab)] = [("idle", .idle, .home), ("home", .expanded, .home), ("agents", .expanded, .agents), ("assistant", .expanded, .assistant), ("study", .expanded, .study), ("preview", .preview, .home), ("shelf", .expanded, .shelf), ("clipboard", .expanded, .clipboard), ("prompter", .expanded, .prompter), ("settings", .expanded, .settings)]
            try? await Task.sleep(for: .seconds(2))
            for (name, mode, tab) in states {
                model.selectedTab = tab; model.setMode(mode)
                try? await Task.sleep(for: .seconds(name == "assistant" || name == "study" ? 6 : 1.2))
                snapshot(to: directory.appendingPathComponent("\(name).png"))
                if name == "assistant" {
                    // Switching providers should show the other page at once (it preloads), then come back intact.
                    let original = model.assistant.provider
                    for (index, item) in [AssistantProvider.chatGPT, .gemini, .claude].enumerated() {
                        model.assistant.provider = item
                        try? await Task.sleep(for: .seconds(index == 0 ? 3 : 0.6))
                        snapshot(to: directory.appendingPathComponent("assistant-switch\(index + 1)-\(item.rawValue).png"))
                    }
                    // Gemini prompt typing: find the message box, type, look for Send, then clear. Nothing is sent.
                    let probe = """
                    const box = document.querySelector('rich-textarea .ql-editor, div.ql-editor[contenteditable="true"], [contenteditable="true"][role="textbox"], textarea');
                    if (!box) return 'box: missing';
                    box.focus(); document.execCommand('insertText', false, 'probe');
                    await new Promise(r => setTimeout(r, 600));
                    const send = !!document.querySelector('button[aria-label*="Send" i]:not([disabled]), button.send-button:not([disabled])');
                    document.execCommand('selectAll', false); document.execCommand('delete', false);
                    return 'box: found, send: ' + (send ? 'found' : 'missing') + ', cleared: ' + (box.innerText.trim() === '');
                    """
                    print("gemini probe:", await model.assistant.evaluate(probe, in: .gemini) ?? "no page"); fflush(stdout)
                    model.assistant.provider = original
                }
            }
            if CommandLine.arguments.contains("--video-assets") { await captureVideoAssets(directory) }
            model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            model.showHUD(HUDState(kind: .volume, value: 0.6, symbol: "speaker.wave.2.fill", tint: Theme.primary))
            try? await Task.sleep(for: .seconds(0.9))
            snapshot(to: directory.appendingPathComponent("hud.png"))
            try? await Task.sleep(for: .seconds(1.5))
            // A file dragged over the notch: the drop targets.
            model.dragActive = true; model.setMode(.preview)
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("drop.png"))
            model.dragActive = false; model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            // AirPods battery, a screenshot landing on the Shelf, and an SSD with Eject.
            model.showHUD(HUDState(kind: .headphones, value: 0.82, symbol: "airpodspro", tint: Theme.primary, label: "L 82%  R 85%  Case 60%"), seconds: 4)
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: directory.appendingPathComponent("airpods-hud.png"))
            try? await Task.sleep(for: .seconds(4))
            var shot = NotchAlert(title: "Screenshot saved", subtitle: "On your Shelf · drag it anywhere", symbol: "camera.viewfinder", color: Theme.working, target: .shelf, actionTitle: "Copy", action: {})
            shot.image = NSImage(contentsOf: directory.appendingPathComponent("home.png"))
            model.raise(shot)
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("screenshot-alert.png"))
            model.raise(NotchAlert(title: "Samsung T7 connected", subtitle: "412 GB free", symbol: "externaldrive.fill", color: Theme.working, target: .home, actionTitle: "Eject", action: {}))
            try? await Task.sleep(for: .seconds(1.2))
            snapshot(to: directory.appendingPathComponent("drive-alert.png"))
            model.alert = nil; model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1))
            // A focus timer counting down in the wings.
            model.timer.start(minutes: 25, label: "Focus")
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("timer-wings.png"))
            model.timer.cancel()
            try? await Task.sleep(for: .seconds(1))
            // An agent at work: the mark becomes the ECG, and the Agents tab lists it.
            // The session is in memory only and removed before quitting.
            let started = Date().addingTimeInterval(-240)
            model.state.apply(AgentEvent(provider: .claudeCode, sessionID: "snapshot-demo", projectPath: "/Users/demo/Attending", kind: .started, timestamp: started))
            model.state.apply(AgentEvent(provider: .claudeCode, sessionID: "snapshot-demo", projectPath: "/Users/demo/Attending", kind: .working, title: "Fix the notch animation"))
            let demoID = ProviderID.claudeCode.rawValue + ":snapshot-demo"
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("agents-wings.png"))
            model.selectedTab = .agents; model.setMode(.expanded)
            try? await Task.sleep(for: .seconds(1.5))
            snapshot(to: directory.appendingPathComponent("agents-working.png"))
            model.agentsShowRecent = true
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: directory.appendingPathComponent("agents-recent.png"))
            model.agentsShowRecent = false
            model.selectedSessionID = demoID
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: directory.appendingPathComponent("agents-detail.png"))
            model.selectedSessionID = nil
            // A multiple-choice question from Claude, as the Agents tab shows it (render only).
            let question = #"{"questions":[{"question":"Which layout should the exam countdown use?","header":"Layout","multiSelect":false,"options":[{"label":"Days left","description":"A large number with the exam name"},{"label":"Progress ring","description":"How much of dedicated has passed"},{"label":"Both","description":"Ring with the number inside"}]}]}"#
            model.claudeApprovals = [ApprovalRequest(provider: .claudeCode, sessionID: "snapshot-demo", projectPath: "/Users/demo/Attending", toolName: "AskUserQuestion", toolInputJSON: question, command: nil, expiresAt: Date().addingTimeInterval(60))]
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: directory.appendingPathComponent("agents-question.png"))
            model.claudeApprovals = []
            model.state.sessions.removeAll { $0.id == demoID }
            model.setMode(.idle)
            try? await Task.sleep(for: .seconds(1.2))
            // A prayer-time alert, as it drops from the notch.
            if let asr = model.salah.times[.asr] {
                model.raise(NotchAlert(title: "Time for Asr", subtitle: asr.formatted(date: .omitted, time: .shortened), symbol: "moon.stars.fill", color: Theme.done, target: .home, actionTitle: "Prayed", action: {}))
                try? await Task.sleep(for: .seconds(1.2))
                snapshot(to: directory.appendingPathComponent("salah-alert.png"))
                model.alert = nil; model.setMode(.idle)
                try? await Task.sleep(for: .seconds(1))
            }
            // A frame mid-spring, to check the transition path.
            model.selectedTab = .home; model.setMode(.expanded)
            try? await Task.sleep(for: .milliseconds(140))
            snapshot(to: directory.appendingPathComponent("transition.png"))
            try? await Task.sleep(for: .seconds(1))
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    /// The 1.1 update video: each new alert as the notch drops it, the Study cards and a
    /// Shelf of sample files. Sample data only, nothing saved; the Shelf and the island's
    /// position are put back afterwards. Run with --boards-demo --salah-demo --no-media.
    private func captureVideoAssets(_ directory: URL) async {
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func shoot(_ name: String) { snapshot(to: directory.appendingPathComponent("\(name).png")) }
        func render<V: View>(_ name: String, width: CGFloat = 640, _ view: V) {
            let renderer = ImageRenderer(content: view.frame(width: width).padding(16).background(Theme.background).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        // Cards with sample data.
        let day = { (back: Int) in ActivityLog.dayKey(Calendar.current.date(byAdding: .day, value: -back, to: Date())!) }
        var week: [String: [String: Int]] = [:]
        for back in 0..<7 {
            week[day(back)] = ["focus": [110, 95, 140, 80, 120, 130, 90][back], "pages": [64, 52, 80, 40, 70, 66, 40][back], "questions": [80, 40, 120, 60, 80, 40, 60][back],
                               "screen.study": [11520, 9000, 12600, 7200, 10800, 9900, 8100][back], "screen.ai": [2400, 1800, 2700, 1500, 2100, 1800, 1200][back], "screen.distraction": [1500, 2400, 900, 3000, 1200, 1800, 2100][back]]
        }
        model.activity.showDemo(week)
        await wait(0.5)
        render("card-boards", BoardsCard(exams: model.exams, onShare: { _ in }, turnOnExamWeek: nil))
        render("card-scores", ScoresCard(exams: model.exams))
        render("card-anki", width: 380, Card(padding: 12) { CardOfDay(front: "Drug of choice for absence seizures?", back: "Ethosuximide") })
        render("card-anki-full", width: 460, AnkiCard(anki: model.anki))
        render("card-week", WeekCard(model: model, activity: model.activity))
        render("card-lookup", LookupBar())
        // Each new alert, as it drops from the notch.
        let alerts: [(String, NotchAlert, Bool)] = [
            ("alert-bedtime", NotchAlert(title: "COMLEX Level 1 tomorrow", subtitle: "Wind down by 10:30 PM. Sleep is part of the plan.", symbol: "moon.zzz.fill", color: Theme.working, target: .study), false),
            ("alert-goodluck", NotchAlert(title: "Good luck today", subtitle: "COMLEX Level 1 at 8:00 AM. You've got this.", symbol: "heart.fill", color: Theme.done, target: .study), false),
            ("alert-didit", NotchAlert(title: "You did it", subtitle: "COMLEX Level 1 is done. Go rest.", symbol: "party.popper.fill", color: Theme.done, target: .study), true),
            ("alert-tiktok", NotchAlert(title: "You're 14 min into focus", subtitle: "TikTok can wait. Back to it?", symbol: "brain.head.profile", color: Theme.attention, target: .home), false),
            ("alert-week", NotchAlert(title: "Your week", subtitle: "12h 45m focused · 412 pages · 2,140 reviews", symbol: "chart.bar.fill", color: Theme.done, target: .study, actionTitle: "Share", action: {}), false),
            ("alert-copied", NotchAlert(title: "Copied 18 words", subtitle: "Nephrotic syndrome: proteinuria > 3.5 g/day, hypoalbuminemia, edema, hyperlipidemia", symbol: "text.viewfinder", color: Theme.done, target: .shelf), false),
            ("alert-merged", NotchAlert(title: "Merged 3 PDFs", subtitle: "Renal block.pdf · 64 pages · on your Shelf", symbol: "doc.on.doc.fill", color: Theme.done, target: .shelf), false),
            ("alert-zotero", NotchAlert(title: "Added to Zotero", subtitle: "Zotero is looking up the paper's details", symbol: "books.vertical.fill", color: Theme.done, target: .shelf), false),
            ("alert-jummah", NotchAlert(title: "Jummah at 1:30 PM", subtitle: "Jummah Mubarak. Time to head to the masjid.", symbol: "building.columns.fill", color: Theme.done, target: .home), false),
            ("alert-class", NotchAlert(title: "Cardio lecture in 10 min", subtitle: "9:00 AM · Room 1", symbol: "calendar", color: Theme.working, target: .home), false),
        ]
        // Alerts drop from the closed island.
        model.alert = nil; model.setMode(.idle)
        await wait(1.2)
        for (name, alert, confetti) in alerts {
            model.raise(alert)
            if confetti { model.confetti = true }
            await wait(confetti ? 0.7 : 1.2)
            shoot(name)
            model.confetti = false
            model.alert = nil; model.setMode(.idle)
            await wait(0.9)
        }
        // A Shelf of sample files: two PDFs and a lecture slide.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attending-video-shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slide = folder.appendingPathComponent("Renal lecture slide 14.png")
        let slideView = VStack(alignment: .leading, spacing: 18) {
            Text("Nephrotic syndrome").font(.system(size: 44, weight: .bold))
            Text("• Proteinuria > 3.5 g/day\n• Hypoalbuminemia\n• Edema\n• Hyperlipidemia").font(.system(size: 30))
        }.foregroundStyle(.black).padding(50).frame(width: 960, height: 540, alignment: .topLeading).background(.white)
        let slideRenderer = ImageRenderer(content: slideView)
        if let image = slideRenderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: slide) }
        var files = [slide]
        for (name, title) in [("Glomerular diseases.pdf", "Glomerular diseases"), ("Acid-base review.pdf", "Acid-base review")] {
            let url = folder.appendingPathComponent(name)
            let page = ImageRenderer(content: Text(title).font(.system(size: 40, weight: .bold)).foregroundStyle(.black).padding(60).frame(width: 612, height: 792, alignment: .topLeading).background(.white))
            page.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil); draw(context); context.endPDFPage(); context.closePDF()
            }
            files.append(url)
        }
        let before = model.shelf.items
        model.shelf.add(files)
        model.selectedTab = .shelf; model.setMode(.expanded)
        // Long enough for Quick Look thumbnails.
        await wait(5)
        shoot("shelf-demo")
        for item in model.shelf.items where !before.contains(item) { model.shelf.remove(item) }
        await captureGemini(directory)
        // The island off the notch, at the top right.
        let anchor = model.islandAnchor
        model.setMode(.idle)
        model.islandAnchor = .topRight
        await wait(1.2)
        shoot("pill")
        model.islandAnchor = anchor
        await wait(1)
    }
    /// Gemini answering in the notch, a frame every few seconds. If Gemini reports an
    /// error, asks again in a new chat (up to three tries).
    func captureGemini(_ directory: URL) async {
        guard model.assistant.enabled.contains(.gemini) else { return }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let original = model.assistant.provider
        model.assistant.provider = .gemini
        model.selectedTab = .assistant; model.setMode(.expanded)
        await wait(3)
        for attempt in 1...3 {
            model.assistant.prompt = "Nephrotic vs nephritic syndrome: the key differences, in 3 short bullets"
            model.assistant.askHere()
            var failed = false
            for (index, delay) in [5.0, 3, 3, 3, 4, 5, 6].enumerated() {
                await wait(delay)
                let text = await model.assistant.evaluate("return document.body.innerText", in: .gemini) as? String ?? ""
                if text.contains("encountered an error") || text.contains("Something went wrong") { failed = true; break }
                snapshot(to: directory.appendingPathComponent("gemini-\(index + 1).png"))
            }
            print("GEMINI attempt \(attempt): \(failed ? "error" : "ok")"); fflush(stdout)
            if !failed { break }
            await wait(4)
        }
        model.assistant.provider = original
        model.setMode(.idle)
        await wait(1)
    }
    private func snapshot(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

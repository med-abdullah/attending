import Foundation
import CoreGraphics

import AttendingCore
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) { precondition(lhs == rhs, "Expected equality: \(lhs) != \(rhs)", file: file, line: line) }
func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
@main struct CoreTests {
    static func main() async throws {
        let suite = CoreTests()
        try suite.testExecutableDiscovery()
        suite.testOldEventsStayDisconnected()
        suite.testLifecycleAndProjectIdentity()
        suite.testRejectsInvalidAndOutOfOrderEvents()
        suite.testHistoryIsBounded()
        suite.testNotchAndExternalDisplayGeometry()
        try await suite.testPersistenceAndUnsupportedVersion()
        suite.testPrayerTimesMatchReference()
        suite.testQibla()
        suite.testCalendarFeeds()
        suite.testBoardsMath()
        suite.testIslandPositions()
        suite.testCodexRolloutsAndSessionNames()
        print("PASS: 13 core checks (lifecycle, validation, bounds, geometry, island positions, persistence, prayer times, qibla, calendar feeds, boards, session names)")
    }
    func testExecutableDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing").path
        let binary = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        XCTAssertEqual(CodexTransport.discoverExecutable(candidates: [missing, binary.path]), nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        XCTAssertEqual(CodexTransport.discoverExecutable(candidates: [missing, binary.path]), binary)
    }
    func testOldEventsStayDisconnected() {
        let launch = Date()
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "old", projectPath: "/work", kind: .working, timestamp: launch.addingTimeInterval(-3600)), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .stale)
        state.apply(.init(provider: .claudeCode, sessionID: "old", projectPath: "/work", kind: .working, timestamp: launch), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .working)
        state.apply(.init(provider: .claudeCode, sessionID: "done", projectPath: "/work", kind: .completed, timestamp: launch.addingTimeInterval(-1800)), liveEventsSince: launch)
        XCTAssertEqual(state.sessions.first?.status, .completed)
    }
    func testLifecycleAndProjectIdentity() {
        var state = AppState()
        let start = Date().addingTimeInterval(-20)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .started, timestamp: start))
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .working, timestamp: start.addingTimeInterval(1)))
        state.apply(.init(provider: .codex, sessionID: "one", projectPath: "/work/Attending", kind: .working, timestamp: start.addingTimeInterval(2)))
        XCTAssertEqual(state.sessions.count, 2)
        XCTAssertEqual(state.projects.count, 1)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .attention, timestamp: start.addingTimeInterval(3)))
        XCTAssertEqual(state.sessions.first?.status, .attention)
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work/Attending", kind: .completed, timestamp: start.addingTimeInterval(4)))
        XCTAssertEqual(state.sessions.first?.status, .completed)
        state.markDisconnected()
        XCTAssertEqual(state.sessions.first?.status, .completed)
        XCTAssertEqual(state.sessions.last?.status, .stale)
    }
    func testRejectsInvalidAndOutOfOrderEvents() {
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "", projectPath: "relative", kind: .working))
        XCTAssertTrue(state.sessions.isEmpty)
        let now = Date()
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .completed, timestamp: now))
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .working, timestamp: now.addingTimeInterval(-1)))
        XCTAssertEqual(state.sessions.first?.status, .completed)
        state.apply(.init(provider: .claudeCode, sessionID: "two", projectPath: "/work", kind: .working, timestamp: now.addingTimeInterval(120)))
        XCTAssertEqual(state.sessions.count, 1)
    }
    func testHistoryIsBounded() {
        var state = AppState()
        for i in 0..<250 { state.apply(.init(provider: .claudeCode, sessionID: "\(i)", projectPath: "/work", kind: .started)) }
        XCTAssertEqual(state.sessions.count, 200)
    }
    func testNotchAndExternalDisplayGeometry() {
        // Offset origin: a notched laptop screen left of a primary external display.
        let screen = CGRect(x: -1728, y: 400, width: 1728, height: 1117)
        let visible = CGRect(x: -1728, y: 440, width: 1728, height: 1040)
        let notched = NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 37)
        XCTAssertTrue(notched.hasNotch)
        XCTAssertEqual(notched.center, -864)
        let collapsed = IslandGeometry.collapsed(notched, wing: 40)
        // Symmetric wings: centered on the notch, flush with the top edge.
        XCTAssertEqual(collapsed.midX, -864)
        XCTAssertEqual(collapsed.width, 200 + 2 * (40 + IslandGeometry.ear))
        XCTAssertEqual(collapsed.maxY, screen.maxY)
        XCTAssertEqual(collapsed.minY, screen.maxY - 37)
        // A half-point notch height (37.5 on 14/15-inch panels) stays pixel-exact.
        let half = IslandGeometry.collapsed(NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 37.5), wing: 40)
        XCTAssertEqual(half.height, 37.5)
        XCTAssertTrue(screen.contains(collapsed))
        for size in [CGSize(width: 640, height: 480), CGSize(width: 420, height: 160)] {
            let panel = IslandGeometry.panel(notched, size: size)
            XCTAssertEqual(panel.maxY, screen.maxY)
            XCTAssertEqual(panel.midX, -864)
            XCTAssertTrue(screen.contains(panel))
        }
        // Oversized requests and notches near an edge stay on screen.
        XCTAssertTrue(screen.contains(IslandGeometry.panel(notched, size: CGSize(width: 4000, height: 4000))))
        let edge = NotchMetrics(screen: screen, visible: visible, notchLeft: screen.maxX - 150, notchRight: screen.maxX - 20, height: 37)
        XCTAssertTrue(screen.contains(IslandGeometry.collapsed(edge, wing: 60)))
        // Missing or implausible notch measurements fall back below the menu bar.
        for broken in [NotchMetrics(screen: screen, visible: visible, notchLeft: nil, notchRight: nil, height: 0),
                       NotchMetrics(screen: screen, visible: visible, notchLeft: -764, notchRight: -964, height: 37),
                       NotchMetrics(screen: screen, visible: visible, notchLeft: -964, notchRight: -764, height: 4)] {
            XCTAssertTrue(!broken.hasNotch)
            let pill = IslandGeometry.collapsed(broken, wing: 40)
            XCTAssertTrue(visible.contains(pill))
            XCTAssertEqual(pill.maxY, visible.maxY - 4)
            let panel = IslandGeometry.panel(broken, size: CGSize(width: 640, height: 480))
            XCTAssertEqual(panel.maxY, visible.maxY - 6)
            XCTAssertTrue(visible.contains(panel))
        }
    }
    func testPersistenceAndUnsupportedVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = StateStore(url: url)
        var state = AppState()
        state.apply(.init(provider: .claudeCode, sessionID: "one", projectPath: "/work", kind: .working))
        try await store.save(state)
        let restored = try await store.load()
        XCTAssertEqual(restored, state)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try Data("{\"version\":99,\"sessions\":[]}".utf8).write(to: url)
        do { _ = try await store.load(); XCTFail("Accepted an unsupported schema") } catch StorageError.unsupportedVersion(99) { }
    }

    /// Reference times from api.aladhan.com for the same places, dates and methods.
    /// Allows one minute for rounding differences.
    func testCalendarFeeds() {
        let ics = """
        BEGIN:VCALENDAR\r
        X-WR-CALNAME:LECOM OMS-II\r
        BEGIN:VTIMEZONE\r
        TZID:Eastern Standard Time\r
        BEGIN:STANDARD\r
        DTSTART:16010101T020000\r
        END:STANDARD\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        UID:cardio\r
        SUMMARY:Cardio lecture\\, Dr. Smith\r
        DTSTART;TZID=Eastern Standard Time:20261005T090000\r
        DTEND;TZID=Eastern Standard Time:20261005T100000\r
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261231T235959Z\r
        EXDATE;TZID=Eastern Standard Time:20261007T090000\r
        LOCATION:Room 1\r
        DESCRIPTION:Join: https://zoom.us/j/123\r
         456\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:cardio\r
        RECURRENCE-ID;TZID=Eastern Standard Time:20261009T090000\r
        SUMMARY:Cardio lecture (moved)\r
        DTSTART;TZID=Eastern Standard Time:20261009T130000\r
        DTEND;TZID=Eastern Standard Time:20261009T140000\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:gone\r
        SUMMARY:Cancelled lab\r
        STATUS:CANCELLED\r
        DTSTART:20261006T130000Z\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:exam\r
        SUMMARY:Exam 2\r
        DTSTART;VALUE=DATE:20261012\r
        END:VEVENT\r
        END:VCALENDAR
        """
        let feed = ICSCalendar.parse(ics)
        XCTAssertEqual(feed.name, "LECOM OMS-II")
        XCTAssertEqual(feed.events.count, 3)
        XCTAssertEqual(feed.events.first?.title, "Cardio lecture, Dr. Smith")
        XCTAssertEqual(feed.events.first?.notes, "Join: https://zoom.us/j/123456")
        var eastern = Calendar(identifier: .gregorian); eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let from = eastern.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let week = feed.occurrences(from: from, to: from.addingTimeInterval(7 * 86400)).filter { !$0.event.allDay }
        // Monday 9 AM, Wednesday skipped, Friday moved to 1 PM.
        XCTAssertEqual(week.map { eastern.component(.hour, from: $0.start) }, [9, 13])
        XCTAssertEqual(week.map { eastern.component(.weekday, from: $0.start) }, [2, 6])
        XCTAssertEqual(week.last?.event.title, "Cardio lecture (moved)")
        // Across the November daylight-saving change, the lecture stays at 9 AM local.
        let november = eastern.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        XCTAssertEqual(feed.occurrences(from: november, to: november.addingTimeInterval(86400)).map { eastern.component(.hour, from: $0.start) }, [9])
        XCTAssertEqual(ICSCalendar.parse("BEGIN:VEVENT\nUID:a\nDTSTART:20200101T120000Z\nDURATION:PT1H\nRRULE:FREQ=DAILY\nEND:VEVENT").occurrences(from: november, to: november.addingTimeInterval(86400)).count, 1)
    }
    func testIslandPositions() {
        let m = NotchMetrics(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 60, width: 1512, height: 885), notchLeft: 663, notchRight: 849, height: 37)
        let right = IslandGeometry.collapsed(m, wing: 40, anchor: .topRight)
        XCTAssertEqual(right.maxX, 1500)
        XCTAssertTrue(right.maxY <= m.visible.maxY)
        let left = IslandGeometry.panel(m, size: CGSize(width: 680, height: 500), anchor: .topLeft)
        XCTAssertEqual(left.minX, 12)
        let bottom = IslandGeometry.panel(m, size: CGSize(width: 680, height: 500), anchor: .bottom)
        XCTAssertEqual(bottom.minY, 68)
        XCTAssertEqual(bottom.midX, 756)
        // Under the notch it still hugs the hardware.
        XCTAssertEqual(IslandGeometry.collapsed(m, wing: 40, anchor: .notch).maxY, 982)
    }
    func testBoardsMath() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))!
        var exam = BoardExam(kind: .comlex1, date: cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8))!)
        XCTAssertEqual(BoardsMath.calendarDays(from: monday, to: exam.date, calendar: cal), 14)
        // Two weeks with Sundays off: 14 days minus 2 Sundays (Oct 11, 18).
        exam.daysOff = [1]
        XCTAssertEqual(BoardsMath.studyDays(from: monday, to: exam.date, daysOff: exam.daysOff, calendar: cal), 12)
        exam.bankTotal = 3600; exam.bankDone = 2400
        XCTAssertEqual(BoardsMath.questionsPerDay(for: exam, doneAtDayStart: 2400, now: monday, calendar: cal), 100)
        XCTAssertEqual(BoardsMath.milestone(for: exam, now: monday, calendar: cal), 14)
        XCTAssertEqual(BoardsMath.countdown(for: exam, unit: .studyDays, now: monday, calendar: cal).value, "12")
        XCTAssertEqual(BoardsMath.countdown(for: exam, unit: .weeks, now: monday, calendar: cal).value, "2")
        exam.dedicatedStart = cal.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        XCTAssertEqual(BoardsMath.phase(for: exam, now: monday, calendar: cal), .preDedicated(daysToDedicated: 3))
        XCTAssertEqual(BoardsMath.phase(for: exam, now: cal.date(byAdding: .day, value: 8, to: monday)!, calendar: cal), .finalWeek)
        XCTAssertEqual(BoardsMath.countdown(for: exam, unit: .days, now: exam.date.addingTimeInterval(-5400), calendar: cal).value, "1h 30m")
        XCTAssertEqual(BoardsMath.phase(for: exam, now: exam.date.addingTimeInterval(9 * 3600), calendar: cal), .finished)
        XCTAssertTrue(BoardExam.Kind.step1.passFail && !BoardExam.Kind.step2.passFail)
        // Exams saved before newer fields existed still load.
        let old = #"{"kind":"block","date":0,"customName":"Exam 1"}"#
        let loaded = try? JSONDecoder().decode(BoardExam.self, from: Data(old.utf8))
        XCTAssertEqual(loaded?.name, "Exam 1")
        XCTAssertTrue(loaded?.logged == false && loaded?.result == nil)
        var logged = BoardExam(kind: .block, date: Date().addingTimeInterval(3600), customName: "Exam 2"); logged.logged = true; logged.result = 86
        XCTAssertEqual(BoardsMath.phase(for: logged, now: Date()), .finished)
        XCTAssertEqual(logged.resultText, "86%")
    }
    func testQibla() {
        // New York's qibla is about 58.5° (NE), London's about 119°.
        let ny = PrayerTimes.qiblaBearing(latitude: 40.7128, longitude: -74.006)
        XCTAssertTrue(abs(ny - 58.5) < 1)
        XCTAssertEqual(PrayerTimes.compassPoint(ny), "NE")
        XCTAssertTrue(abs(PrayerTimes.qiblaBearing(latitude: 51.5, longitude: -0.13) - 119) < 1)
        XCTAssertEqual(PrayerTimes.compassPoint(350), "N")
    }
    func testPrayerTimesMatchReference() {
        func check(_ date: String, _ lat: Double, _ lon: Double, _ zone: String, _ method: PrayerTimes.Method, _ asr: PrayerTimes.Asr, _ expected: [String]) {
            let tz = TimeZone(identifier: zone)!
            let parser = DateFormatter(); parser.timeZone = tz; parser.dateFormat = "yyyy-MM-dd HH:mm"
            let noon = parser.date(from: "\(date) 12:00")!
            let times = PrayerTimes.times(on: noon, latitude: lat, longitude: lon, timeZone: tz, method: method, asr: asr)
            for (prayer, text) in zip([PrayerTimes.Prayer.fajr, .sunrise, .dhuhr, .asr, .maghrib, .isha], expected) {
                let want = parser.date(from: "\(date) \(text)")!
                let got = times[prayer]!
                if abs(got.timeIntervalSince(want)) > 60 { XCTFail("\(prayer) on \(date) at \(lat),\(lon): got \(parser.string(from: got)), expected \(text)") }
            }
        }
        // Gulf coast of Florida (27.50° N, 82.57° W).
        check("2026-09-29", 27.50, -82.57, "America/New_York", .isna, .standard, ["06:18", "07:22", "13:21", "16:45", "19:19", "20:22"])
        check("2026-09-29", 27.50, -82.57, "America/New_York", .mwl, .standard, ["06:05", "07:22", "13:21", "16:45", "19:19", "20:32"])
        check("2026-09-29", 27.50, -82.57, "America/New_York", .ummAlQura, .standard, ["06:02", "07:22", "13:21", "16:45", "19:19", "20:49"])
        // Shia methods against Aladhan (methods 0 and 7, Jafari midnight): Maghrib after the redness.
        check("2026-09-29", 27.50, -82.57, "America/New_York", .jafari, .standard, ["06:14", "07:22", "13:21", "16:46", "19:33", "20:18"])
        check("2026-09-29", 27.50, -82.57, "America/New_York", .tehran, .standard, ["06:06", "07:22", "13:21", "16:46", "19:35", "20:18"])
        do {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 12))!
            let today = PrayerTimes.times(on: day, latitude: 27.50, longitude: -82.57, timeZone: calendar.timeZone, method: .jafari)
            let tomorrow = PrayerTimes.times(on: day.addingTimeInterval(86400), latitude: 27.50, longitude: -82.57, timeZone: calendar.timeZone, method: .jafari)
            let midnight = PrayerTimes.midnight(sunset: today[.sunset]!, nextFajr: tomorrow[.fajr]!)
            let parts = calendar.dateComponents([.hour, .minute], from: midnight)
            if abs((parts.hour! * 60 + parts.minute!) - 46) > 1 { XCTFail("Jafari midnight: got \(parts.hour!):\(parts.minute!), expected 00:46") }
            if abs(today[.sunset]!.timeIntervalSince(PrayerTimes.times(on: day, latitude: 27.50, longitude: -82.57, timeZone: calendar.timeZone, method: .isna)[.maghrib]!)) > 60 { XCTFail("sunset should match Sunni Maghrib") }
        }
        // London in winter, Hanafi Asr.
        check("2027-01-15", 51.51, -0.13, "Europe/London", .mwl, .hanafi, ["05:59", "08:00", "12:10", "14:32", "16:21", "18:14"])
    }
    func testCodexRolloutsAndSessionNames() {
        var reader = CodexRolloutReader()
        let lines = [
            #"{"timestamp":"2026-10-01T20:13:50.789Z","type":"session_meta","payload":{"id":"t1","cwd":"/work/Attending","originator":"codex_work_desktop","source":"vscode"}}"#,
            #"{"timestamp":"2026-10-01T20:13:51.225Z","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"#,
            #"{"timestamp":"2026-10-01T20:13:52.000Z","type":"response_item","payload":{"type":"message","content":"mentions task_complete"}}"#,
            #"{"timestamp":"2026-10-01T20:14:10.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"#,
        ]
        let events = reader.consume(lines)
        XCTAssertEqual(events.map(\.kind), [.working, .completed])
        XCTAssertEqual(events.first?.projectPath, "/work/Attending")
        XCTAssertTrue(!reader.turnOpen)
        var helper = CodexRolloutReader()
        let helperEvents = helper.consume([
            #"{"timestamp":"2026-10-01T20:13:50Z","type":"session_meta","payload":{"id":"g","cwd":"/work","source":{"subagent":{"other":"guardian"}}}}"#,
            #"{"timestamp":"2026-10-01T20:13:51Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        ])
        XCTAssertTrue(helperEvents.isEmpty && helper.isSubagent)
        var asking = CodexRolloutReader()
        let asked = asking.consume([
            #"{"timestamp":"2026-10-01T20:13:50Z","type":"session_meta","payload":{"id":"q","cwd":"/work","source":"vscode"}}"#,
            #"{"timestamp":"2026-10-01T20:13:51Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-01T20:13:52Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"c1","arguments":"{}"}}"#,
            #"{"timestamp":"2026-10-01T20:14:30Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Detailed"}}"#,
        ])
        XCTAssertEqual(asked.map(\.kind), [.working, .attention, .working])
        let questions = ProviderQuestion.parse(toolName: "AskUserQuestion", inputJSON: #"{"questions":[{"question":"Which format?","header":"Format","options":[{"label":"Summary","description":"Brief"},{"label":"Detailed","description":""}],"multiSelect":true}]}"#)
        XCTAssertEqual(questions?.first?.options.map(\.label), ["Summary", "Detailed"])
        XCTAssertEqual(questions?.first?.options.last?.detail, nil)
        XCTAssertTrue(questions?.first?.multiSelect == true)
        XCTAssertTrue(ProviderQuestion.parse(toolName: "Bash", inputJSON: #"{"command":"ls"}"#) == nil)
        XCTAssertEqual(CodexThreadNames.parse("{\"id\":\"t1\",\"thread_name\":\"Old\"}\n{\"id\":\"t1\",\"thread_name\":\"Fix the build\"}\n"), ["t1": "Fix the build"])
        XCTAssertEqual(ClaudeSessionTitle.parse("{\"type\":\"ai-title\",\"aiTitle\":\"Generated\"}\n{\"type\":\"custom-title\",\"customTitle\":\"Mine\"}"), "Mine")
        XCTAssertEqual(ClaudeSessionTitle.parse("{\"type\":\"ai-title\",\"aiTitle\":\"Generated\"}"), "Generated")
        XCTAssertEqual(SessionNaming.folderTitle("/Users/me", home: "/Users/me"), "Home")
        XCTAssertEqual(SessionNaming.folderTitle("/Users/me/Library/CloudStorage/GoogleDrive-me@example.com", home: "/Users/me"), "Google Drive")
        XCTAssertEqual(SessionNaming.folderTitle("/Users/me/Documents/Codex/2026-10-01/fix-the-build", home: "/Users/me"), "Fix the build")
        XCTAssertTrue(SessionNaming.isScratch("/private/tmp/x") && !SessionNaming.isScratch("/work"))
        var state = AppState()
        let now = Date()
        state.apply(.init(provider: .codex, sessionID: "t1", projectPath: "/work/Attending", kind: .working, timestamp: now.addingTimeInterval(-2), title: "Fix the build"))
        state.apply(.init(provider: .codex, sessionID: "t1", projectPath: "/work/Attending", kind: .stopped, timestamp: now.addingTimeInterval(-1)))
        XCTAssertEqual(state.sessions.first?.title, "Fix the build")
        XCTAssertEqual(state.sessions.first?.status, .idle)
    }
}

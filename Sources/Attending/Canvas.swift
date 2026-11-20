import AppKit
import SwiftUI
import AttendingCore

/// Canvas LMS through its REST API with a personal access token the user makes in Canvas
/// (Account › Settings › New Access Token): recent announcements from current courses,
/// assignments and quizzes due in the next two weeks, and the Canvas calendar, added to
/// Calendars from the profile's iCal feed. The token lives in a file only this user can
/// read and is sent only to the school's Canvas address. Refreshes every 15 minutes.
@MainActor final class CanvasService: ObservableObject {
    struct Announcement: Identifiable, Equatable {
        var id: Int
        var title: String
        var course: String
        var posted: Date
        var url: URL?
        var preview: String
        var unread: Bool
    }
    struct Due: Identifiable, Equatable {
        var id: String
        var title: String
        var course: String
        var due: Date
        var kind: String
        var url: URL?
    }
    private struct Saved: Codable { var base: String; var token: String; var name: String? }

    @Published private(set) var base: URL?
    @Published private(set) var userName: String?
    @Published private(set) var announcements: [Announcement] = []
    @Published private(set) var due: [Due] = []
    @Published private(set) var problem: String?
    @Published private(set) var updatedAt: Date?
    /// The profile's calendar feed, for Calendars to add.
    @Published private(set) var calendarFeed: String?
    var onNewAnnouncement: ((Announcement) -> Void)?
    var connected: Bool { base != nil && token != nil }

    private var token: String?
    private var timer: Timer?
    private var seen = Set(UserDefaults.standard.array(forKey: "canvasSeen") as? [Int] ?? [])
    private var demo = false
    private let fileURL = AppPaths.directory.appendingPathComponent("canvas.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            base = URL(string: saved.base); token = saved.token; userName = saved.name
        }
    }

    func start() {
        guard connected, timer == nil else { return }
        Task { await refresh() }
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// "school.instructure.com", "canvas.school.edu" or a full link, as https://host.
    static func normalize(_ text: String) -> URL? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty { return nil }
        if !link.contains("://") { link = "https://" + link }
        guard let url = URL(string: link), let host = url.host, host.contains(".") || host == "127.0.0.1" else { return nil }
        // Plain http only for a local test server.
        guard url.scheme == "https" || (url.scheme == "http" && host == "127.0.0.1") else { return nil }
        return URL(string: "\(url.scheme!)://\(host)\(url.port.map { ":\($0)" } ?? "")")
    }

    /// Checks the token with Canvas, then saves it. Returns a problem to show, or nil.
    func connect(address: String, token newToken: String) async -> String? {
        guard let url = Self.normalize(address) else { return "Enter your school's Canvas address, like school.instructure.com." }
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Paste the access token you made in Canvas." }
        switch await request(url.appendingPathComponent("api/v1/users/self"), token: trimmed) {
        case .failure(let message): return message
        case .success(let data):
            let me = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            base = url; token = trimmed; userName = me?["name"] as? String
            save()
            seen = []
            UserDefaults.standard.removeObject(forKey: "canvasSeen")
            timer?.invalidate(); timer = nil
            start()
            return nil
        }
    }
    func disconnect() {
        timer?.invalidate(); timer = nil
        base = nil; token = nil; userName = nil; announcements = []; due = []; calendarFeed = nil; problem = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
    private func save() {
        guard let base, let token, let data = try? JSONEncoder().encode(Saved(base: base.absoluteString, token: token, name: userName)) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: Fetching

    func refresh() async {
        guard !demo, let base, let token else { return }
        // Courses you're in now.
        guard case .success(let courseData) = await request(base.appendingPathComponent("api/v1/courses"), token: token, query: [("enrollment_state", "active"), ("per_page", "100")]) else {
            problem = "Couldn't reach Canvas. It tries again in 15 minutes."; return
        }
        let courses = ((try? JSONSerialization.jsonObject(with: courseData)) as? [[String: Any]] ?? []).compactMap { course -> (Int, String)? in
            guard let id = course["id"] as? Int, let name = course["name"] as? String ?? course["course_code"] as? String else { return nil }
            return (id, name)
        }
        let names = Dictionary(courses, uniquingKeysWith: { a, _ in a })
        // Announcements from the last three weeks.
        var fresh: [Announcement] = []
        if !courses.isEmpty {
            let start = Calendar.current.date(byAdding: .day, value: -21, to: Date())!
            var query = courses.map { ("context_codes[]", "course_\($0.0)") }
            query += [("start_date", Self.day.string(from: start)), ("end_date", Self.day.string(from: Date().addingTimeInterval(86400))), ("per_page", "50")]
            if case .success(let data) = await request(base.appendingPathComponent("api/v1/announcements"), token: token, query: query) {
                fresh = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { item in
                    guard let id = item["id"] as? Int, let title = item["title"] as? String, let posted = (item["posted_at"] as? String).flatMap(Self.parseDate) else { return nil }
                    let course = (item["context_code"] as? String).flatMap { Int($0.replacingOccurrences(of: "course_", with: "")) }.flatMap { names[$0] } ?? ""
                    return Announcement(id: id, title: title, course: course, posted: posted, url: (item["html_url"] as? String).flatMap { Self.link($0, base: base) },
                                        preview: Self.plainText(item["message"] as? String ?? ""), unread: item["read_state"] as? String == "unread")
                }.sorted { $0.posted > $1.posted }
            }
        }
        // Assignments, quizzes and discussions due in the next two weeks that aren't submitted.
        var upcoming: [Due] = []
        let end = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
        if case .success(let data) = await request(base.appendingPathComponent("api/v1/planner/items"), token: token,
                                                   query: [("start_date", Self.iso.string(from: Date())), ("end_date", Self.iso.string(from: end)), ("per_page", "100")]) {
            upcoming = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []).compactMap { item in
                guard let type = item["plannable_type"] as? String, ["assignment", "quiz", "discussion_topic", "wiki_page"].contains(type),
                      let plannable = item["plannable"] as? [String: Any], let title = plannable["title"] as? String,
                      let due = ((plannable["due_at"] as? String) ?? (item["plannable_date"] as? String)).flatMap(Self.parseDate) else { return nil }
                if let submissions = item["submissions"] as? [String: Any], submissions["submitted"] as? Bool == true { return nil }
                return Due(id: "\(type)-\(item["plannable_id"] ?? title)", title: title, course: item["context_name"] as? String ?? "", due: due,
                           kind: type == "quiz" ? "Quiz" : type == "discussion_topic" ? "Discussion" : "Assignment", url: (item["html_url"] as? String).flatMap { Self.link($0, base: base) })
            }.sorted { $0.due < $1.due }
        }
        // The Canvas calendar's iCal feed.
        if calendarFeed == nil, case .success(let data) = await request(base.appendingPathComponent("api/v1/users/self/profile"), token: token),
           let profile = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ics = (profile["calendar"] as? [String: Any])?["ics"] as? String {
            calendarFeed = ics
        }
        // New announcements drop down (the first fetch only sets what's been seen).
        let firstFetch = seen.isEmpty && updatedAt == nil && UserDefaults.standard.array(forKey: "canvasSeen") == nil
        for item in fresh where !seen.contains(item.id) && !firstFetch && Date().timeIntervalSince(item.posted) < 2 * 86400 { onNewAnnouncement?(item) }
        seen.formUnion(fresh.map(\.id))
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: "canvasSeen")
        announcements = fresh
        due = upcoming
        problem = nil
        updatedAt = Date()
    }

    private enum Result { case success(Data), failure(String) }
    private func request(_ url: URL, token: String, query: [(String, String)] = []) async -> Result {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let full = components.url else { return .failure("That Canvas address didn't work.") }
        var request = URLRequest(url: full)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .failure("Couldn't reach Canvas at \(url.host ?? "that address"). Check the address.")
        }
        switch http.statusCode {
        case 200: return .success(data)
        case 401: return .failure("Canvas didn't accept that token. Make a new one in Canvas › Account › Settings.")
        case 403: return .failure("Your school doesn't allow this through Canvas's API. Add the Canvas calendar link in Calendars instead.")
        case 404: return .failure("That doesn't look like a Canvas address.")
        default: return .failure("Canvas answered \(http.statusCode). Try again in a bit.")
        }
    }

    static func link(_ text: String, base: URL) -> URL? { text.hasPrefix("http") ? URL(string: text) : URL(string: text, relativeTo: base)?.absoluteURL }
    static func plainText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
        let words = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.replacingOccurrences(of: #" ([.,;:!?])"#, with: "$1", options: .regularExpression).prefix(160).description
    }
    nonisolated(unsafe) private static let isoParser: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func parseDate(_ text: String) -> Date? { isoParser.date(from: text) ?? isoFractional.date(from: text) }
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    nonisolated(unsafe) private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    func showDemo(announcements: [Announcement], due: [Due]) { demo = true; base = URL(string: "https://canvas.example.edu"); token = "demo"; userName = "Demo"; self.announcements = announcements; self.due = due; updatedAt = Date() }
}

/// Canvas on Home and in Study: the latest announcements and what's due soon.
struct CanvasCard: View {
    @ObservedObject var canvas: CanvasService
    var compact = false
    var body: some View {
        if canvas.connected {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Canvas")
                        if let problem = canvas.problem { Text(problem).font(.system(size: 10)).foregroundStyle(Theme.attention).lineLimit(1) }
                        Spacer()
                        if let base = canvas.base { Button("Open") { NSWorkspace.shared.open(base) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary) }
                    }
                    let announcements = Array(canvas.announcements.prefix(compact ? 2 : 4))
                    if announcements.isEmpty && canvas.due.isEmpty {
                        Text(canvas.updatedAt == nil ? "Loading…" : "No new announcements, and nothing due in the next two weeks.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    ForEach(announcements) { item in
                        Button { if let url = item.url { NSWorkspace.shared.open(url) } } label: {
                            HStack(alignment: .top, spacing: 7) {
                                Circle().fill(item.unread ? Theme.working : Color.clear).frame(width: 6, height: 6).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.system(size: 11.5, weight: item.unread ? .semibold : .medium)).lineLimit(1)
                                    Text("\(item.course) · \(item.posted.formatted(.relative(presentation: .named)))").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.preview)
                    }
                    if !canvas.due.isEmpty {
                        if !announcements.isEmpty { Divider().overlay(Theme.stroke) }
                        ForEach(canvas.due.prefix(compact ? 2 : 5)) { item in
                            Button { if let url = item.url { NSWorkspace.shared.open(url) } } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: item.kind == "Quiz" ? "checklist" : item.kind == "Discussion" ? "bubble.left.and.bubble.right" : "doc.text").font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 12)
                                    Text(item.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Self.dueText(item.due)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(item.due.timeIntervalSinceNow < 86400 ? Theme.attention : Theme.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(item.kind) · \(item.course) · due \(item.due.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            }
        }
    }
    static func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Settings › Canvas.
struct CanvasSettings: View {
    @ObservedObject var canvas: CanvasService
    @ObservedObject var calendar: CalendarService
    @State private var address = ""
    @State private var token = ""
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        if canvas.connected {
            HStack {
                Text("Connected\(canvas.userName.map { " as \($0)" } ?? "") · \(canvas.base?.host ?? "")").foregroundStyle(Theme.done)
                Spacer()
                Button("Refresh") { Task { await canvas.refresh() } }
                Button("Disconnect") { canvas.disconnect() }
            }
            if let feed = canvas.calendarFeed {
                HStack {
                    Text("Canvas calendar (due dates and course events)")
                    Spacer()
                    if calendar.feeds.contains(where: { $0.url == feed }) { Text("In Calendars").foregroundStyle(Theme.done) }
                    else { Button(busy ? "Adding…" : "Add to Calendars") { busy = true; Task { message = await calendar.addFeed(feed, name: "Canvas"); busy = false } } }
                }
            }
        } else {
            HStack {
                TextField("school.instructure.com", text: $address).textFieldStyle(.roundedBorder).frame(width: 190)
                SecureField("Access token", text: $token).textFieldStyle(.roundedBorder)
                Button(busy ? "Checking…" : "Connect") {
                    busy = true
                    Task { message = await canvas.connect(address: address, token: token); busy = false; if message == nil { token = "" } }
                }.disabled(busy || address.isEmpty || token.isEmpty)
            }
        }
        if let message { Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention).fixedSize(horizontal: false, vertical: true) }
        Text("Shows announcements from your current courses (a drop-down when a new one is posted) and assignments and quizzes due in the next two weeks. To connect: in Canvas, open Account › Settings › New Access Token, name it Attending, then paste it here. The token stays on this Mac and goes only to your school's Canvas. If your school blocks tokens, add the link from Canvas › Calendar › Calendar Feed in Calendars instead.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

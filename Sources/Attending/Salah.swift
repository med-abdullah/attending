import AppKit
import AttendingCore
import CoreLocation

/// Today's prayer times for the Mac's location, which prayers are done, and the
/// streak of days with all five. Times are calculated on the Mac; the location is
/// looked up about once a day and kept, rounded to about a kilometer, for offline use.
@MainActor final class SalahTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    typealias Prayer = PrayerTimes.Prayer
    @Published private(set) var times: [Prayer: Date] = [:]
    @Published private(set) var prayed: Set<Prayer> = []
    @Published private(set) var streak = 0
    @Published private(set) var place: String?
    @Published private(set) var denied = false
    /// Tomorrow's Fajr, the next prayer once Isha has begun.
    private var tomorrowFajr: Date?
    var onPrayerTime: ((Prayer, Date) -> Void)?
    var onEndingSoon: ((Prayer, Date) -> Void)?
    /// Friday reminders: Jummah ahead of the khutbah, and Surah Al-Kahf in the morning.
    var onJummah: ((Date) -> Void)?
    var onKahf: (() -> Void)?

    private let manager = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var timerTask: Task<Void, Never>?
    private var history: [String: [String]] = [:]
    private let historyKey = "salahPrayed"
    private let coordinateKey = "salahCoordinate"
    private var running = false

    var method: PrayerTimes.Method {
        get { PrayerTimes.Method(rawValue: UserDefaults.standard.string(forKey: "salahMethod") ?? "") ?? .isna }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "salahMethod"); objectWillChange.send(); recalculate() }
    }
    var asr: PrayerTimes.Asr {
        get { PrayerTimes.Asr(rawValue: UserDefaults.standard.integer(forKey: "salahAsr")) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "salahAsr"); objectWillChange.send(); recalculate() }
    }

    var jummahReminder: Bool {
        get { UserDefaults.standard.object(forKey: "jummahReminder") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "jummahReminder"); objectWillChange.send(); schedule() }
    }
    /// Khutbah time on Fridays, as minutes after midnight (1:30 PM unless set).
    var jummahMinutes: Int {
        get { UserDefaults.standard.object(forKey: "jummahMinutes") as? Int ?? 13 * 60 + 30 }
        set { UserDefaults.standard.set(newValue, forKey: "jummahMinutes"); objectWillChange.send(); schedule() }
    }
    var jummahLead: Int {
        get { UserDefaults.standard.object(forKey: "jummahLead") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "jummahLead"); objectWillChange.send(); schedule() }
    }
    var kahfReminder: Bool {
        get { UserDefaults.standard.bool(forKey: "kahfReminder") }
        set { UserDefaults.standard.set(newValue, forKey: "kahfReminder"); objectWillChange.send(); schedule() }
    }
    /// Today's khutbah time, on Fridays.
    var jummahToday: Date? {
        guard Calendar.current.component(.weekday, from: now) == 6 else { return nil }
        return Calendar.current.startOfDay(for: now).addingTimeInterval(TimeInterval(jummahMinutes * 60))
    }
    /// Direction of the Kaaba, in degrees from north.
    var qibla: Double? { coordinate.map { PrayerTimes.qiblaBearing(latitude: $0.latitude, longitude: $0.longitude) } }


    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let data = UserDefaults.standard.data(forKey: historyKey), let saved = try? JSONDecoder().decode([String: [String]].self, from: data) { history = saved }
        if let saved = UserDefaults.standard.array(forKey: coordinateKey) as? [Double], saved.count == 2 {
            coordinate = CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1])
        }
        place = UserDefaults.standard.string(forKey: "salahPlace")
    }

    func start() {
        running = true
        recalculate()
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = coordinate == nil
        default: manager.requestLocation()
        }
    }
    func stop() { running = false; timerTask?.cancel(); times = [:] }

    // MARK: State

    /// For screenshots and videos: a fixed time and set of prayers, never saved.
    private(set) var demoTime: Date?
    private var demoPrayed: Set<Prayer>?
    func showDemo(prayed: Set<Prayer>, at time: Date) {
        demoTime = time
        demoPrayed = prayed
        self.prayed = prayed
        objectWillChange.send()
    }
    var now: Date { demoTime ?? Date() }

    /// The prayer whose time it is now (Fajr until sunrise, then Dhuhr onward), if any.
    var current: Prayer? {
        let now = self.now
        guard let fajr = times[.fajr], now >= fajr else { return nil }
        if let sunrise = times[.sunrise], let dhuhr = times[.dhuhr], now >= sunrise, now < dhuhr { return nil }
        return Prayer.obligatory.last { (times[$0] ?? .distantFuture) <= now }
    }
    var next: (prayer: Prayer, time: Date)? {
        let now = self.now
        if let upcoming = Prayer.obligatory.first(where: { (times[$0] ?? .distantPast) > now }) { return (upcoming, times[upcoming]!) }
        return tomorrowFajr.map { (.fajr, $0) }
    }
    /// Islamic midnight (halfway from sunset to Fajr): the end of Maghrib and Isha for Shia methods.
    var midnight: Date? {
        guard let sunset = times[.sunset], let tomorrowFajr else { return nil }
        return PrayerTimes.midnight(sunset: sunset, nextFajr: tomorrowFajr)
    }
    /// When `prayer`'s time ends: sunrise for Fajr, the next prayer otherwise, midnight-ish for Isha (next Fajr).
    /// Shia methods share the times: Dhuhr and Asr until sunset, Maghrib and Isha until Islamic midnight.
    func end(of prayer: Prayer) -> Date? {
        if method.isShia {
            switch prayer {
            case .fajr: return times[.sunrise]
            case .dhuhr, .asr: return times[.sunset]
            case .maghrib, .isha: return midnight
            default: return nil
            }
        }
        return switch prayer {
        case .fajr: times[.sunrise]
        case .dhuhr: times[.asr]
        case .asr: times[.maghrib]
        case .maghrib: times[.isha]
        case .isha: tomorrowFajr
        case .sunrise, .sunset: nil
        }
    }
    func toggle(_ prayer: Prayer) {
        if prayed.contains(prayer) { prayed.remove(prayer) } else { prayed.insert(prayer) }
        history[Self.dayKey(Date())] = prayed.map(\.rawValue).sorted()
        // Keep about two months.
        let cutoff = Self.dayKey(Date().addingTimeInterval(-60 * 86400))
        history = history.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
        updateStreak()
    }

    // MARK: Calculation

    private func recalculate() {
        guard running, let coordinate else { return }
        let now = Date()
        times = PrayerTimes.times(on: now, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: .current, method: method, asr: asr)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        tomorrowFajr = PrayerTimes.times(on: tomorrow, latitude: coordinate.latitude, longitude: coordinate.longitude, timeZone: .current, method: method, asr: asr)[.fajr]
        prayed = demoPrayed ?? Set((history[Self.dayKey(now)] ?? []).compactMap(Prayer.init(rawValue:)))
        updateStreak()
        schedule()
    }

    /// Sleeps until the next prayer (or 15 minutes before the current one ends), then
    /// reports it and recalculates. Midnight rolls the day over the same way.
    private func schedule() {
        timerTask?.cancel()
        guard running else { return }
        let now = Date()
        var events: [(Date, () -> Void)] = []
        if let next { let (prayer, time) = next; events.append((time, { [weak self] in self?.onPrayerTime?(prayer, time) })) }
        // With Shia timing, Dhuhr stays due until sunset even after Asr begins (and Maghrib until midnight).
        let due: Prayer? = {
            guard method.isShia, let current else { return current }
            let pair: [Prayer] = current == .asr ? [.dhuhr, .asr] : current == .isha ? [.maghrib, .isha] : [current]
            return pair.first { !prayed.contains($0) } ?? current
        }()
        if let due, let end = end(of: due), !prayed.contains(due) {
            let warn = end.addingTimeInterval(-15 * 60)
            if warn > now { events.append((warn, { [weak self] in
                guard let self, !prayed.contains(due) else { return }
                onEndingSoon?(due, end)
            })) }
        }
        if jummahReminder, let jummah = jummahToday {
            let remind = jummah.addingTimeInterval(TimeInterval(-jummahLead * 60))
            if remind > now { events.append((remind, { [weak self] in self?.onJummah?(jummah) })) }
        }
        if kahfReminder, jummahToday != nil, let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now), morning > now {
            events.append((morning, { [weak self] in self?.onKahf?() }))
        }
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) {
            events.append((midnight, {}))
        }
        guard let (fire, action) = events.min(by: { $0.0 < $1.0 }) else { return }
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, fire.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            action()
            recalculate()
        }
    }

    private func updateStreak() {
        let calendar = Calendar.current
        var day = Date()
        // Today counts once all five are done; otherwise the streak runs through yesterday.
        if prayed.isSuperset(of: Prayer.obligatory) == false { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while let done = history[Self.dayKey(day)], Set(done.compactMap(Prayer.init(rawValue:))).isSuperset(of: Prayer.obligatory) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        streak = count
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Location

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            denied = (status == .denied || status == .restricted) && coordinate == nil
            if status == .authorizedAlways || status == .authorized { self.manager.requestLocation() }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated {
            let rounded = CLLocationCoordinate2D(latitude: (last.coordinate.latitude * 100).rounded() / 100, longitude: (last.coordinate.longitude * 100).rounded() / 100)
            coordinate = rounded
            denied = false
            UserDefaults.standard.set([rounded.latitude, rounded.longitude], forKey: coordinateKey)
            recalculate()
            Task {
                if let name = try? await CLGeocoder().reverseGeocodeLocation(last).first?.locality {
                    place = name
                    UserDefaults.standard.set(name, forKey: "salahPlace")
                }
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

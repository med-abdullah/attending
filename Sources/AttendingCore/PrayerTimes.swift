import Foundation

/// Daily prayer times from the sun's position (the PrayTimes.org method): Fajr and
/// Isha at a twilight angle below the horizon, Dhuhr just after solar noon, Asr when
/// an object's shadow reaches its length (or twice it, Hanafi) plus its noon shadow,
/// Maghrib at sunset (Sunni methods) or once the sun is 4–4.5° below the horizon and the
/// eastern redness is gone (Shia methods). Offline and deterministic.
public enum PrayerTimes {
    public enum Prayer: String, CaseIterable, Codable, Sendable {
        case fajr, sunrise, dhuhr, asr, sunset, maghrib, isha
        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        /// The five daily prayers (sunrise marks the end of Fajr's time, not a prayer).
        public static let obligatory: [Prayer] = [.fajr, .dhuhr, .asr, .maghrib, .isha]
    }

    public enum Method: String, CaseIterable, Codable, Sendable {
        case isna, mwl, egyptian, karachi, ummAlQura, jafari, tehran
        public var title: String {
            switch self {
            case .isna: "ISNA (North America)"
            case .mwl: "Muslim World League"
            case .egyptian: "Egyptian Authority"
            case .karachi: "Karachi (University of Islamic Sciences)"
            case .ummAlQura: "Umm al-Qura (Makkah)"
            case .jafari: "Shia Ithna-Ashari (Jafari, Leva Institute, Qum)"
            case .tehran: "Shia (Institute of Geophysics, Tehran)"
            }
        }
        /// Shia (Jafari) timing: Maghrib after the redness, shared Dhuhr–Asr and Maghrib–Isha times, Islamic midnight.
        public var isShia: Bool { self == .jafari || self == .tehran }
        var fajrAngle: Double { switch self { case .isna: 15; case .mwl: 18; case .egyptian: 19.5; case .karachi: 18; case .ummAlQura: 18.5; case .jafari: 16; case .tehran: 17.7 } }
        /// Isha as a twilight angle, or nil when it's a fixed time after Maghrib.
        var ishaAngle: Double? { switch self { case .isna: 15; case .mwl: 17; case .egyptian: 17.5; case .karachi: 18; case .ummAlQura: nil; case .jafari, .tehran: 14 } }
        var ishaMinutesAfterMaghrib: Double { self == .ummAlQura ? 90 : 0 }
        /// Maghrib as the sun's angle below the horizon; Sunni methods use sunset.
        var maghribAngle: Double? { switch self { case .jafari: 4; case .tehran: 4.5; default: nil } }
    }

    public enum Asr: Int, CaseIterable, Codable, Sendable {
        case standard = 1, hanafi = 2
        public var title: String { self == .standard ? "Standard (Shafi'i, Maliki, Hanbali)" : "Hanafi" }
    }

    /// Times for the calendar day containing `date` in `timeZone`, rounded to the minute.
    public static func times(on date: Date, latitude: Double, longitude: Double, timeZone: TimeZone, method: Method = .isna, asr: Asr = .standard) -> [Prayer: Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let midnight = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return [:] }
        let offset = Double(timeZone.secondsFromGMT(for: midnight.addingTimeInterval(12 * 3600))) / 3600
        let jd = julianDay(year: year, month: month, day: day) - longitude / (15 * 24)

        // Estimates in hours, refined twice with the sun's position at each estimate.
        var hours: [Prayer: Double] = [.fajr: 5, .sunrise: 6, .dhuhr: 12, .asr: 13, .sunset: 18, .maghrib: 18, .isha: 18]
        for _ in 0..<2 {
            func t(_ prayer: Prayer) -> Double { hours[prayer]! / 24 }
            let sun = Sun(jd: jd, latitude: latitude)
            var next: [Prayer: Double] = [:]
            next[.fajr] = sun.angleTime(method.fajrAngle, t(.fajr), before: true)
            next[.sunrise] = sun.angleTime(0.833, t(.sunrise), before: true)
            next[.dhuhr] = sun.noon(t(.dhuhr))
            next[.asr] = sun.asrTime(Double(asr.rawValue), t(.asr))
            next[.sunset] = sun.angleTime(0.833, t(.sunset), before: false)
            next[.maghrib] = sun.angleTime(method.maghribAngle ?? 0.833, t(.maghrib), before: false)
            next[.isha] = method.ishaAngle.map { sun.angleTime($0, t(.isha), before: false) } ?? next[.maghrib]!
            hours = next.mapValues { $0.isNaN ? 0 : $0 }
        }
        if method.ishaAngle == nil { hours[.isha] = hours[.maghrib]! + method.ishaMinutesAfterMaghrib / 60 }

        var result: [Prayer: Date] = [:]
        for (prayer, solar) in hours {
            let local = solar + offset - longitude / 15
            let seconds = (local * 3600 / 60).rounded() * 60
            result[prayer] = midnight.addingTimeInterval(seconds)
        }
        return result
    }

    /// Islamic midnight in Jafari reckoning: halfway from sunset to the next Fajr. The end of
    /// Maghrib and Isha for Shia methods.
    public static func midnight(sunset: Date, nextFajr: Date) -> Date {
        let seconds = (nextFajr.timeIntervalSince(sunset) / 2 / 60).rounded() * 60
        return sunset.addingTimeInterval(seconds)
    }

    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 { y -= 1; m += 12 }
        let a = (y / 100).rounded(.down)
        let b = 2 - a + (a / 4).rounded(.down)
        return (365.25 * (y + 4716)).rounded(.down) + (30.6001 * (m + 1)).rounded(.down) + Double(day) + b - 1524.5
    }

    private struct Sun {
        let jd: Double
        let latitude: Double
        /// Declination and equation of time for a fraction of the day.
        func position(_ t: Double) -> (declination: Double, equation: Double) {
            let d = jd + t - 2451545.0
            let g = fix(357.529 + 0.98560028 * d, 360)
            let q = fix(280.459 + 0.98564736 * d, 360)
            let l = fix(q + 1.915 * sin(rad(g)) + 0.020 * sin(rad(2 * g)), 360)
            let e = 23.439 - 0.00000036 * d
            let ra = fix(deg(atan2(cos(rad(e)) * sin(rad(l)), cos(rad(l)))) / 15, 24)
            return (deg(asin(sin(rad(e)) * sin(rad(l)))), q / 15 - ra)
        }
        func noon(_ t: Double) -> Double { fix(12 - position(t).equation, 24) }
        /// When the sun is `angle` degrees below the horizon, before or after noon.
        func angleTime(_ angle: Double, _ t: Double, before: Bool) -> Double {
            let decl = position(t).declination
            let cosine = (-sin(rad(angle)) - sin(rad(decl)) * sin(rad(latitude))) / (cos(rad(decl)) * cos(rad(latitude)))
            let span = deg(acos(max(-1, min(1, cosine)))) / 15
            return noon(t) + (before ? -span : span)
        }
        func asrTime(_ shadow: Double, _ t: Double) -> Double {
            let decl = position(t).declination
            let angle = -deg(atan(1 / (shadow + tan(rad(abs(latitude - decl))))))
            return angleTime(angle, t, before: false)
        }
    }
    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
    private static func fix(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }

    /// Direction of the Kaaba from a location, in degrees clockwise from true north.
    public static func qiblaBearing(latitude: Double, longitude: Double) -> Double {
        let kaaba = (lat: 21.4225 * .pi / 180, lon: 39.8262 * .pi / 180)
        let lat = latitude * .pi / 180, delta = kaaba.lon - longitude * .pi / 180
        let bearing = atan2(sin(delta), cos(lat) * tan(kaaba.lat) - sin(lat) * cos(delta)) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
    /// "NE" style compass point for a bearing.
    public static func compassPoint(_ bearing: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
    }
}

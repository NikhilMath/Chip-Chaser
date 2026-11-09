import Foundation

/// A store's regular weekly hours, as Harley-Davidson's dealer locator lists them.
///
/// Times are wall-clock times in the store's own time zone (`Dealer.timeZone`), never the phone's.
/// `dealers.json` keeps one string per day, Sunday first: `"closed"`, `"09:00-18:00"`, or several
/// ranges joined by commas. A range that ends at or before its start runs past midnight
/// (`"20:00-02:00"`), so `"00:00-00:00"` is open all day.
nonisolated struct OpeningHours: Hashable, Sendable {
    /// One stretch of opening time, in minutes after midnight.
    struct Interval: Hashable, Sendable {
        var open: Int
        /// At or before `open` means it closes the next day.
        var close: Int

        /// How long it's open, in minutes. A range that wraps past midnight counts into the next day.
        var length: Int { close > open ? close - open : close + 1440 - open }
    }

    /// Seven entries, Sunday first (index = `Calendar` weekday - 1). `nil` when that day isn't
    /// listed, empty when the store is closed all day.
    let days: [[Interval]?]

    init(days: [[Interval]?]) {
        self.days = Array((days + Array(repeating: nil, count: 7)).prefix(7))
    }

    /// Reads the `dealers.json` form. Anything it can't read counts as "not listed" for that day.
    init(strings: [String?]) {
        self.init(days: strings.map(Self.parseDay))
    }

    /// Every day of the week is listed, so "closed" really means closed.
    var isComplete: Bool { days.allSatisfy { $0 != nil } }

    /// Some day has opening time. A few seasonal shops list every day as closed off-season.
    var hasOpenTime: Bool { days.contains { !($0 ?? []).isEmpty } }

    /// The listed hours for a `Calendar` weekday (1 = Sunday … 7 = Saturday).
    func intervals(forWeekday weekday: Int) -> [Interval]? {
        days.indices.contains(weekday - 1) ? days[weekday - 1] : nil
    }

    // MARK: Reading and writing the dealers.json form

    static func parseDay(_ text: String?) -> [Interval]? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "closed" { return [] }
        var intervals: [Interval] = []
        for range in trimmed.split(separator: ",") {
            let ends = range.split(separator: "-")
            guard ends.count == 2, let open = minutes(ends[0]), let close = minutes(ends[1]) else { return nil }
            intervals.append(Interval(open: open % 1440, close: close % 1440))
        }
        return intervals.isEmpty ? nil : intervals
    }

    /// "09:30" → 570. Accepts "24:00" as midnight.
    private static func minutes(_ text: Substring) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0..<60).contains(minute), hour * 60 + minute <= 1440 else { return nil }
        return hour * 60 + minute
    }

    static func dayString(_ intervals: [Interval]) -> String {
        guard !intervals.isEmpty else { return "closed" }
        func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
        return intervals.map { "\(clock($0.open))-\(clock($0.close))" }.joined(separator: ",")
    }
}

nonisolated extension OpeningHours: Codable {
    init(from decoder: Decoder) throws {
        // Lenient on purpose: odd hours for one store must never stop the dealer list from loading.
        let strings = (try? decoder.singleValueContainer().decode([String?].self)) ?? []
        self.init(strings: strings)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(days.map { $0.map(Self.dayString) })
    }
}

// MARK: - Open or closed right now

nonisolated extension OpeningHours {
    enum Status: Hashable, Sendable {
        /// Open now. `closes` is nil when it doesn't close in the coming week (open around the clock).
        case open(closes: Date?)
        /// Closed now. `opens` is nil when no opening is listed in the coming week.
        case closed(opens: Date?)

        var isOpen: Bool {
            if case .open = self { return true }
            return false
        }
    }

    /// Whether the store is open at `date`, reading its hours in the store's `timeZone`.
    /// `nil` when a day isn't listed, since the answer could then be wrong.
    func status(at date: Date, in timeZone: TimeZone) -> Status? {
        guard isComplete else { return nil }
        let calendar = Self.calendar(in: timeZone)
        let today = calendar.startOfDay(for: date)

        // Opening periods from yesterday (an overnight range may still be running) to a week out.
        var periods: [(start: Date, end: Date)] = []
        for offset in -1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for interval in intervals(forWeekday: calendar.component(.weekday, from: day)) ?? [] {
                guard let start = Self.date(minutes: interval.open, after: day, calendar),
                      let end = Self.date(minutes: interval.open + interval.length, after: day, calendar),
                      end > start else { continue }
                periods.append((start, end))
            }
        }

        // Join back-to-back periods, so 24-hour days or a late night running into the next
        // day's hours read as one stretch.
        var merged: [(start: Date, end: Date)] = []
        for period in periods.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, period.start <= last.end {
                merged[merged.count - 1].end = max(last.end, period.end)
            } else {
                merged.append(period)
            }
        }

        if let current = merged.first(where: { $0.start <= date && date < $0.end }) {
            let windowEnd = calendar.date(byAdding: .day, value: 8, to: today) ?? .distantFuture
            return .open(closes: current.end >= windowEnd ? nil : current.end)
        }
        return .closed(opens: merged.first { $0.start > date }?.start)
    }

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The moment `minutes` after the start of `day` on the wall clock (1500 is 1 AM the next day).
    /// On a daylight-saving change, a time that doesn't exist moves to the next one that does.
    private static func date(minutes: Int, after day: Date, _ calendar: Calendar) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: minutes / 1440, to: day) else { return nil }
        let rest = minutes % 1440
        return calendar.date(bySettingHour: rest / 60, minute: rest % 60, second: 0, of: base)
    }
}

// MARK: - Display text

nonisolated extension OpeningHours.Status {
    /// "Open now", "Open 24 hours" or "Closed".
    var headline: String {
        switch self {
        case .open(let closes): closes == nil ? "Open 24 hours" : "Open now"
        case .closed: "Closed"
        }
    }

    /// "closes 6 PM", "opens 9 AM Tue", or nil. Times are the store's (`timeZone`); a weekday is
    /// added when it isn't today there.
    func detail(now: Date, timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String? {
        let (verb, moment): (String, Date?) = switch self {
        case .open(let closes): ("closes", closes)
        case .closed(let opens): ("opens", opens)
        }
        guard let moment else { return nil }
        var text = "\(verb) \(OpeningHours.timeText(moment, timeZone: timeZone, locale: locale))"
        if !OpeningHours.calendar(in: timeZone).isDate(moment, inSameDayAs: now) {
            let day = moment.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated))
            text += " \(day)"
        }
        return text
    }

    /// "Open now · closes 6 PM" or "Closed · opens 9 AM Tue".
    func text(now: Date, timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        guard let detail = detail(now: now, timeZone: timeZone, locale: locale) else { return headline }
        return "\(headline) · \(detail)"
    }
}

nonisolated extension OpeningHours {
    /// "6 PM", or "5:30 PM" when it isn't on the hour, as the store's clock shows it.
    static func timeText(_ date: Date, timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour(.defaultDigits(amPM: .abbreviated))
        let onTheHour = calendar(in: timeZone).component(.minute, from: date) == 0
        return date.formatted(onTheHour ? style : style.minute())
    }

    /// One day's line in the weekly schedule: "9 AM – 6 PM", "Closed", "Open 24 hours" or "Not listed".
    func text(forWeekday weekday: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard let intervals = intervals(forWeekday: weekday) else { return "Not listed" }
        if intervals.isEmpty { return "Closed" }
        if intervals.count == 1, intervals[0].length == 1440 { return "Open 24 hours" }
        let utc = TimeZone(identifier: "UTC")!
        func clock(_ minutes: Int) -> String {
            Self.timeText(Date(timeIntervalSinceReferenceDate: TimeInterval(minutes % 1440 * 60)), timeZone: utc, locale: locale)
        }
        return intervals.map { "\(clock($0.open)) – \(clock($0.close))" }.joined(separator: ", ")
    }
}

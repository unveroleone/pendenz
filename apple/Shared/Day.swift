import Foundation

// A calendar day without a time or a zone, which is how the server stores an all-day due date.
nonisolated struct Day: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    // The API speaks Gregorian dates. A device set to another calendar would otherwise read
    // 2026 as a year long past and send its own year back. The zone follows the device.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date) {
        let calendar = Self.calendar
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    // Reads "2026-11-13".
    init?(text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    // "2026-11-13", the form the API takes for an all-day due date.
    var text: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // The start of this day in the device's time zone.
    func date() -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    func adding(days: Int) -> Day {
        Day(Self.calendar.date(byAdding: .day, value: days, to: date()) ?? date())
    }

    // 1 for Sunday to 7 for Saturday.
    var weekday: Int {
        Self.calendar.component(.weekday, from: date())
    }

    // The instant of a clock time on this day in the device's zone.
    func date(hour: Int, minute: Int) -> Date {
        Self.calendar
            .date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? date()
    }

    func days(until other: Day) -> Int {
        Self.calendar.dateComponents([.day], from: date(), to: other.date()).day ?? 0
    }
}

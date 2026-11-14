import Foundation

// How dates read in lists: "Today", "Tomorrow", a weekday inside the coming week, then the date.
enum DueText {
    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func dayName(for day: Day, today: Day) -> String {
        let date = day.date()
        let distance = today.days(until: day)
        if abs(distance) <= 1 {
            return relative.string(from: date)
        }
        if (2 ... 6).contains(distance) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if day.year == today.year {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    // A section heading in Reminders. Days beyond tomorrow carry the weekday and the date.
    static func heading(for day: Day, today: Day) -> String {
        let distance = today.days(until: day)
        if distance <= 1 {
            return dayName(for: day, today: today)
        }
        let date = day.date()
        if day.year == today.year {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    // The label in a row. Lists that already group by day only need the time.
    static func label(for due: Due, today: Day, showsDay: Bool) -> String? {
        let time = due.time?.formatted(date: .omitted, time: .shortened)
        guard showsDay else { return time }
        let day = dayName(for: due.day, today: today)
        return time.map { "\(day), \($0)" } ?? day
    }
}

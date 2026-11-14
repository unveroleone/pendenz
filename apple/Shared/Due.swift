import Foundation

// A due date as the API sends it: a day ("2026-11-13") or a time with an offset
// ("2026-11-13T09:00:00+01:00").
nonisolated enum Due: Hashable, Sendable, Codable {
    case day(Day)
    case time(Date)

    init?(text: String) {
        if text.count == 10, let day = Day(text: text) {
            self = .day(day)
        } else if let date = try? Date(text, strategy: .iso8601) {
            self = .time(date)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let due = Due(text: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable due date: \(text)")
        }
        self = due
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    // What the API takes: a day, or an instant in UTC that the server turns into local time
    // in the item's zone.
    var text: String {
        switch self {
        case .day(let day): day.text
        case .time(let date): date.formatted(.iso8601)
        }
    }

    // The day this falls on for the person looking at the device.
    var day: Day {
        switch self {
        case .day(let day): day
        case .time(let date): Day(date)
        }
    }

    var time: Date? {
        if case .time(let date) = self { date } else { nil }
    }

    // An all-day date sorts at the start of its day, before the timed items of that day.
    var sortDate: Date {
        switch self {
        case .day(let day): day.date()
        case .time(let date): date
        }
    }
}

import Foundation

// A repeat rule in words: "Every day", "Every 2 weeks", "Every Monday".
enum RepeatText {
    private static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    static func describe(_ rule: String) -> String {
        var parts: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[String(pair[0])] = String(pair[1]) }
        }
        let interval = parts["INTERVAL"].flatMap { Int($0) } ?? 1
        // The calendar of the API has no locale, and would name the days "Mon", "Tue".
        var calendar = Day.calendar
        calendar.locale = .autoupdatingCurrent
        let names = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { code in
            codes.firstIndex(of: String(code)).map { calendar.weekdaySymbols[$0] }
        }
        if !names.isEmpty, interval == 1 {
            return "Every \(names.formatted(.list(type: .and)))"
        }
        let unit: String
        switch parts["FREQ"] {
        case "DAILY": unit = interval == 1 ? "day" : "days"
        case "WEEKLY": unit = interval == 1 ? "week" : "weeks"
        case "MONTHLY": unit = interval == 1 ? "month" : "months"
        case "YEARLY": unit = interval == 1 ? "year" : "years"
        default: return "Repeats"
        }
        let every = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)"
        return names.isEmpty ? every : "\(every) on \(names.formatted(.list(type: .and)))"
    }
}

import Foundation

// Reads a line of quick add: "Call the dentist tomorrow 9", "Water the plants every Monday",
// "Order cables #homelab". English and German words are understood. What is recognised leaves
// the title; everything else stays as typed.
nonisolated enum QuickAddParser {
    enum Kind: Hashable, Sendable {
        case due, repeats, project
    }

    struct Result: Sendable {
        var title = ""
        var due: Due?
        var repeatRule: String?
        var projectId: String?

        // The kinds that were found, in the order the chips show them.
        var kinds: [Kind] {
            var kinds: [Kind] = []
            if due != nil { kinds.append(.due) }
            if repeatRule != nil { kinds.append(.repeats) }
            if projectId != nil { kinds.append(.project) }
            return kinds
        }
    }

    // `ignoring` switches a kind off, for the case that a word was meant literally.
    static func parse(_ text: String, now: Date, projects: [Project], ignoring: Set<Kind> = []) -> Result {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;")) }
        var used = [Bool](repeating: false, count: words.count)
        let today = Day(now)
        var result = Result()
        var day: Day?
        var time: Clock?
        var repeatWeekday: Int?

        func take(_ range: Range<Int>) {
            for index in range { used[index] = true }
        }

        var index = 0
        while index < keys.count {
            let key = keys[index]
            if !ignoring.contains(.project), result.projectId == nil, key.hasPrefix("#"),
               let id = project(named: String(key.dropFirst()), in: projects)
            {
                result.projectId = id
                take(index ..< index + 1)
                index += 1
                continue
            }
            if result.repeatRule == nil, let found = repeatRule(in: keys, at: index) {
                // Switched off, the whole phrase stays in the title: "every Monday" must not
                // turn into the date "Monday".
                if !ignoring.contains(.repeats) {
                    result.repeatRule = found.rule
                    repeatWeekday = found.weekday
                    take(index ..< index + found.length)
                }
                index += found.length
                continue
            }
            if !ignoring.contains(.due) {
                if day == nil, !isNoun(words[index], at: index), let found = self.day(
                    in: keys,
                    at: index,
                    today: today,
                ) {
                    day = found.day
                    take(index ..< index + found.length)
                    index += found.length
                    // A written time first, so "tomorrow 5 pm" is not five in the morning. A
                    // bare hour only counts right after a date: "tomorrow 9".
                    if time == nil, index < keys.count, clock(in: keys, at: index) == nil,
                       let hour = bareHour(keys[index])
                    {
                        time = Clock(hour: hour, minute: 0)
                        let length = index + 1 < keys.count && keys[index + 1] == "uhr" ? 2 : 1
                        take(index ..< index + length)
                        index += length
                    }
                    continue
                }
                if time == nil, let found = clock(in: keys, at: index) {
                    time = found.clock
                    take(index ..< index + found.length)
                    index += found.length
                    continue
                }
            }
            index += 1
        }

        // Without a date word, a repeat or a time still needs a day: the named weekday of the
        // repeat, or today. If the time has passed on that day, it is the next one.
        let isGuessed = day == nil
        if day == nil, result.repeatRule != nil || time != nil {
            day = repeatWeekday.map { today.adding(days: ($0 - today.weekday + 7) % 7) } ?? today
        }
        if let time, var target = day {
            if isGuessed, target.date(hour: time.hour, minute: time.minute) <= now {
                target = target.adding(days: repeatWeekday == nil ? 1 : 7)
            }
            result.due = .time(target.date(hour: time.hour, minute: time.minute))
        } else if let day {
            result.due = .day(day)
        }

        let rest = zip(words, used).filter { !$0.1 }.map(\.0).joined(separator: " ")
        // A line that is nothing but a date keeps its words as the title.
        result.title = rest.isEmpty ? words.joined(separator: " ") : rest
        return result
    }

    private struct Clock {
        var hour: Int
        var minute: Int
    }

    // MARK: Projects

    // "#homelab", "#home-lab" and "#home" all find "Home lab", as long as only one project fits.
    private static func project(named text: String, in projects: [Project]) -> String? {
        let wanted = text.filter { $0.isLetter || $0.isNumber }
        guard !wanted.isEmpty else { return nil }
        func plain(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
        if let exact = projects.first(where: { plain($0.name) == wanted || plain($0.id) == wanted }) {
            return exact.id
        }
        let starting = projects.filter { plain($0.name).hasPrefix(wanted) }
        return starting.count == 1 ? starting[0].id : nil
    }

    // MARK: Repeats

    private static let everyWords: Set = ["every", "each", "jeden", "jede", "jedes", "alle"]
    private static let single: [String: String] = [
        "daily": "DAILY", "täglich": "DAILY", "taeglich": "DAILY",
        "weekly": "WEEKLY", "wöchentlich": "WEEKLY", "woechentlich": "WEEKLY",
        "monthly": "MONTHLY", "monatlich": "MONTHLY",
        "yearly": "YEARLY", "annually": "YEARLY", "jährlich": "YEARLY", "jaehrlich": "YEARLY",
    ]
    private static let units: [String: String] = [
        "day": "DAILY", "days": "DAILY", "tag": "DAILY", "tage": "DAILY", "tagen": "DAILY",
        "week": "WEEKLY", "weeks": "WEEKLY", "woche": "WEEKLY", "wochen": "WEEKLY",
        "month": "MONTHLY", "months": "MONTHLY", "monat": "MONTHLY", "monate": "MONTHLY", "monaten": "MONTHLY",
        "year": "YEARLY", "years": "YEARLY", "jahr": "YEARLY", "jahre": "YEARLY", "jahren": "YEARLY",
    ]
    // Sunday first, as the calendar counts weekdays from 1.
    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7,
    ]

    private static func repeatRule(in keys: [String], at index: Int) -> (rule: String, weekday: Int?, length: Int)? {
        if let frequency = single[keys[index]] {
            return ("FREQ=\(frequency)", nil, 1)
        }
        guard everyWords.contains(keys[index]), index + 1 < keys.count else { return nil }
        let next = keys[index + 1]
        if let frequency = units[next] {
            return ("FREQ=\(frequency)", nil, 2)
        }
        // "every mondays" is as clear as "every monday".
        if let weekday = weekdays[next] ?? weekdays[String(next.dropLast())]
            .flatMap({ next.hasSuffix("s") ? $0 : nil })
        {
            return ("FREQ=WEEKLY;BYDAY=\(weekdayCodes[weekday - 1])", weekday, 2)
        }
        if let count = Int(next), (1 ... 999).contains(count), index + 2 < keys.count,
           let frequency = units[keys[index + 2]]
        {
            return (count == 1 ? "FREQ=\(frequency)" : "FREQ=\(frequency);INTERVAL=\(count)", nil, 3)
        }
        return nil
    }

    // MARK: Days

    private static func day(in keys: [String], at index: Int, today: Day) -> (day: Day, length: Int)? {
        let key = keys[index]
        switch key {
        case "today", "heute": return (today, 1)
        case "tomorrow", "morgen": return (today.adding(days: 1), 1)
        case "übermorgen", "uebermorgen": return (today.adding(days: 2), 1)
        default: break
        }
        if let weekday = weekdays[key] {
            // The coming one. On a Monday, "monday" is next week's.
            let ahead = (weekday - today.weekday + 7) % 7
            return (today.adding(days: ahead == 0 ? 7 : ahead), 1)
        }
        if key.count == 10, let day = Day(text: key), exists(day) {
            return (day, 1)
        }
        return swissDate(key, today: today).map { ($0, 1) }
    }

    // German writes the morning with a capital: "Guten Morgen" is no date, "morgen" is. At the
    // start of the line both are capitalised, and there it is read as the date.
    private static func isNoun(_ word: String, at index: Int) -> Bool {
        index > 0 && word.lowercased() == "morgen" && word.first?.isUppercase == true
    }

    // "13.11.", "13.11.2026" or "13.11.26". A year or the closing dot is needed, so that
    // "3.5 kg" stays a number.
    private static func swissDate(_ key: String, today: Day) -> Day? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let day = Int(parts[0]), let month = Int(parts[1]),
              parts[0].count <= 2, parts[1].count <= 2
        else { return nil }
        if parts[2].isEmpty {
            // Without a year: this year, or the next one when the day has passed.
            let thisYear = Day(year: today.year, month: month, day: day)
            let candidate = thisYear < today ? Day(year: today.year + 1, month: month, day: day) : thisYear
            return exists(candidate) ? candidate : nil
        }
        guard var year = Int(parts[2]), parts[2].count == 2 || parts[2].count == 4 else { return nil }
        if year < 100 { year += 2000 }
        let candidate = Day(year: year, month: month, day: day)
        return exists(candidate) ? candidate : nil
    }

    // False for the 31st of a short month and the like.
    private static func exists(_ day: Day) -> Bool {
        (1970 ... 2200).contains(day.year) && Day(day.date()) == day
    }

    // MARK: Times

    private static func bareHour(_ key: String) -> Int? {
        guard key.count <= 2, key.allSatisfy(\.isNumber), let hour = Int(key), hour < 24 else { return nil }
        return hour
    }

    // "9:30", "17:00", "9am", "9:30pm", with or without a space before am or pm.
    private static func written(_ key: String, suffix: String?) -> (clock: Clock, usedSuffix: Bool)? {
        var text = key
        var half: String?
        for marker in ["am", "pm"] where text.hasSuffix(marker) {
            half = marker
            text.removeLast(2)
        }
        var usedSuffix = false
        if half == nil, let suffix, suffix == "am" || suffix == "pm" {
            half = suffix
            usedSuffix = true
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]), let minute = parts.count == 2 ? Int(parts[1]) : 0, minute < 60
        else { return nil }
        // A bare number is no time by itself: it needs the colon, am or pm.
        if parts.count == 1, half == nil { return nil }
        if let half {
            guard (1 ... 12).contains(hour) else { return nil }
            hour = hour % 12 + (half == "pm" ? 12 : 0)
        }
        guard hour < 24 else { return nil }
        return (Clock(hour: hour, minute: minute), usedSuffix)
    }

    private static func clock(in keys: [String], at index: Int) -> (clock: Clock, length: Int)? {
        func key(_ offset: Int) -> String? {
            index + offset < keys.count ? keys[index + offset] : nil
        }
        // "at 9", "um 9", "at 9:30", "at 9 pm", "um 9 uhr".
        if ["at", "um", "@"].contains(keys[index]), let next = key(1) {
            if let found = written(next, suffix: key(2)) {
                let length = found.usedSuffix ? 3 : 2
                return (found.clock, key(length) == "uhr" ? length + 1 : length)
            }
            if let hour = bareHour(next) {
                return (Clock(hour: hour, minute: 0), key(2) == "uhr" ? 3 : 2)
            }
            return nil
        }
        if let found = written(keys[index], suffix: key(1)) {
            let length = found.usedSuffix ? 2 : 1
            return (found.clock, key(length) == "uhr" ? length + 1 : length)
        }
        // "9 uhr".
        if let hour = bareHour(keys[index]), key(1) == "uhr" {
            return (Clock(hour: hour, minute: 0), 2)
        }
        return nil
    }
}

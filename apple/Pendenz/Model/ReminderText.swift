import Foundation

// What a reminder's notification says under the item's title: when the item is due and where
// it is filed, then the start of its description.
enum ReminderText {
    // The longest body. The system shortens it further where it has less room.
    private static let bodyLimit = 180

    // What markdown puts in front of a line: a heading, a quote, a list entry with or without
    // a box to tick, a number.
    private static let lineMark = #/^(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/#
    private static let link = #/!?\[([^\]]*)\]\([^)]*\)/#
    // A line that only draws something: a rule, the underline of a heading, or a code fence,
    // which may name the language of the code under it.
    private static let drawn = #/^\s*(?:[-*_=#>\s]+|(?:```|~~~).*)$/#

    // The due date and the project, as a row shows them.
    static func subtitle(for item: Item, firing: Date, project: String?) -> String {
        [dueLine(item.dueAt, firing: firing), project].compactMap(\.self).joined(separator: " · ")
    }

    // The day is named as seen from the moment the notification fires, which can be days after
    // it was scheduled: a reminder set for the evening before says "tomorrow".
    private static func dueLine(_ due: Due?, firing: Date) -> String? {
        guard let due else { return nil }
        let today = Day(firing)
        // The three days next to the firing day are named here. `DueText` leaves them to a
        // formatter that counts from the day it is asked, not from the day given to it.
        let day = switch today.days(until: due.day) {
        case -1: "yesterday"
        case 0: "today"
        case 1: "tomorrow"
        default: DueText.dayName(for: due.day, today: today)
        }
        let time = due.time?.formatted(date: .omitted, time: .shortened)
        return "Due " + (time.map { "\(day), \($0)" } ?? day)
    }

    // The start of the description without the marks of its markdown and without empty lines.
    // The lines stay lines: a list run together into one sentence cannot be read.
    static func body(for item: Item) -> String {
        var text = ""
        for line in item.description.split(whereSeparator: \.isNewline) {
            let words = plain(line)
            if words.isEmpty { continue }
            text += text.isEmpty ? words : "\n" + words
            if text.count > bodyLimit { break }
        }
        return shortened(text)
    }

    private static func plain(_ line: Substring) -> String {
        if line.wholeMatch(of: drawn) != nil { return "" }
        return line.trimmingCharacters(in: .whitespaces)
            .replacing(lineMark, with: "")
            .replacing(link) { String($0.1) }
            .replacing("**", with: "")
            .replacing("`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // Cut between two words where there is one in the second half, with a mark that says so.
    private static func shortened(_ text: String) -> String {
        guard text.count > bodyLimit else { return text }
        var cut = text.prefix(bodyLimit)
        if let space = cut.lastIndex(where: \.isWhitespace),
           cut.distance(from: cut.startIndex, to: space) > bodyLimit / 2
        {
            cut = cut[..<space]
        }
        let end = cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return end + "…"
    }
}

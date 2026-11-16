import Foundation

// What a reminder's notification says under the item's title: when the item is due and where
// it is filed, then the start of its description.
enum ReminderText {
    // The longest body. The system shortens it further where it has less room.
    private static let bodyLimit = 180

    // What markdown puts in front of a line: a heading, a quote, a list entry with or without
    // a box to tick, a number.
    private static let lineMark = #/^(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/#
    // A line that only draws something: a rule, the underline of a heading, or a code fence,
    // which may name the language of the code under it.
    private static let drawn = #/^(?:[-*_=#>\s]+|\s*(?:```|~~~).*)$/#

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
            .linkTexts
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

private extension String {
    // Each markdown link or image, [text](target) or ![text](target), replaced by its text. One
    // pass over the line: a pattern for it tries every `[` and reads on to the end of the line
    // from each, which takes a minute on a long line that an agent can write.
    var linkTexts: String {
        let chars = Array(self)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else {
                out.append(chars[i])
                i += 1
                continue
            }
            // Every `[` up to the first `]` ends there, so they all fail or match together.
            guard let close = chars[(i + 1)...].firstIndex(of: "]") else { break }
            guard close + 1 < chars.count, chars[close + 1] == "(" else {
                out.append(contentsOf: chars[i ... close])
                i = close + 1
                continue
            }
            // Without a `)` after this `](` no later link can end either.
            guard let end = chars[(close + 2)...].firstIndex(of: ")") else { break }
            if i > 0, chars[i - 1] == "!", out.last == "!" { out.removeLast() }
            out.append(contentsOf: chars[(i + 1) ..< close])
            i = end + 1
        }
        if i < chars.count { out.append(contentsOf: chars[i...]) }
        return out
    }
}

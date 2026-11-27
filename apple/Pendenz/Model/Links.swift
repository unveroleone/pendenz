import Foundation
import SwiftUI

// The addresses in the text of a note or a description, which open with a tap or a click as
// in Notes. The text stays as typed: markdown is not rendered, and the address inside
// `[label](https://…)` is the link. Links never reach what is saved or synced.
enum Links {
    // Only these open. The detector also finds `shortcuts://`, `tel:` or `ftp://`, which stay
    // plain text: the system opens a link tapped in an editor itself, past the app's `openURL`,
    // so a link that is made is a link that opens.
    static let schemes: Set<String> = ["http", "https", "mailto"]

    static func opens(_ url: URL) -> Bool {
        url.scheme.map { schemes.contains($0.lowercased()) } ?? false
    }

    // The text with a link on every address in it.
    static func marked(_ plain: String) -> AttributedString {
        var text = AttributedString(plain)
        for (range, url) in found(in: plain) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower ..< upper].link = url
        }
        return text
    }

    // A text from the editor with only the links its own characters back: a link whose text is
    // not exactly that address, such as a pasted "click here" or a typed letter inside an
    // address, loses its link until the next marking. Nil when every link holds, which is
    // almost always, so the editor's value is only replaced when something had to go.
    static func checked(_ text: AttributedString) -> AttributedString? {
        var cleaned = text
        var changed = false
        for (link, range) in text.runs[\.link] {
            guard let link else { continue }
            let shown = String(text[range].characters)
            let matches = found(in: shown)
            let holds = matches.count == 1 && matches[0].1 == link
                && matches[0].0 == shown.startIndex ..< shown.endIndex
            if !holds {
                cleaned[range].link = nil
                changed = true
            }
        }
        return changed ? cleaned : nil
    }

    // Where the links of an edited text are and where they lead, in Unicode scalars. When this
    // differs from what the text itself holds, an address was typed or changed since the links
    // were made.
    static func places(in text: AttributedString) -> [LinkPlace] {
        let scalars = text.unicodeScalars
        return text.runs[\.link].compactMap { link, range in
            guard let link else { return nil }
            return LinkPlace(
                start: scalars.distance(from: scalars.startIndex, to: range.lowerBound),
                length: scalars.distance(from: range.lowerBound, to: range.upperBound),
                url: link,
            )
        }
    }

    static func places(in plain: String) -> [LinkPlace] {
        let scalars = plain.unicodeScalars
        return found(in: plain).map { range, url in
            LinkPlace(
                start: scalars.distance(from: scalars.startIndex, to: range.lowerBound),
                length: scalars.distance(from: range.lowerBound, to: range.upperBound),
                url: url,
            )
        }
    }

    private static func found(in plain: String) -> [(Range<String.Index>, URL)] {
        guard let detector else { return [] }
        return detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap { match in
            guard let url = match.url, opens(url), let range = Range(match.range, in: plain) else { return nil }
            return (range, url)
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

// One link in a text, counted in Unicode scalars.
struct LinkPlace: Equatable {
    let start: Int
    let length: Int
    let url: URL
}

// What the editors of notes and descriptions hold besides the characters: links, and how they
// look. Nothing else, so Command-B, the format menu and a pasted styled text add no style that
// would not be saved.
struct LinkTextScope: AttributeScope {
    let link: AttributeScopes.FoundationAttributes.LinkAttribute
    let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
    let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
}

struct LinkTextFormatting: AttributedTextFormattingDefinition {
    var body: some AttributedTextFormattingDefinition<LinkTextScope> {
        LinkLine()
        LinkInk()
    }
}

// A link is underlined and nothing else is: the tint is black or white, so the line is what
// tells a link apart. The editor applies it as it draws, without changing the bound text.
private struct LinkLine: AttributedTextValueConstraint {
    typealias Scope = LinkTextScope
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute

    func constrain(_ container: inout Attributes) {
        container.underlineStyle = container.link == nil ? nil : .single
    }
}

// A link keeps the color of the text. The Mac would draw it in the system's blue.
private struct LinkInk: AttributedTextValueConstraint {
    typealias Scope = LinkTextScope
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

    func constrain(_ container: inout Attributes) {
        container.foregroundColor = container.link == nil ? nil : .primary
    }
}

extension View {
    // An editor that holds plain text and its links. The system's format controls (the
    // Format menu, the font panel) are hidden: the editor keeps no style that they could set.
    func linkTextEditor() -> some View {
        attributedTextFormattingDefinition(LinkTextFormatting())
            .textInputFormattingControlVisibility(.hidden, for: .all)
    }
}

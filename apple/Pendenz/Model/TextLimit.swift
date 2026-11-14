import Foundation

// The server counts the length of a text in Unicode scalars, as Rust's `chars()` does. Swift
// counts characters, and one character can be several scalars: an "é" typed as "e" and an
// accent, a flag, a family emoji. A text cut to 240 characters could then be too long for the
// server, which refuses it.
nonisolated extension String {
    // The length as the server counts it.
    var serverLength: Int {
        unicodeScalars.count
    }

    // The text cut to at most `limit` of the server's units, without splitting a character.
    func cut(to limit: Int) -> String {
        guard unicodeScalars.count > limit else { return self }
        var count = 0
        var end = startIndex
        for character in self {
            let size = character.unicodeScalars.count
            if count + size > limit { break }
            count += size
            end = index(after: end)
        }
        return String(self[..<end])
    }
}

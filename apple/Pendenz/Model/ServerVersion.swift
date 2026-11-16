import Foundation

// The version a server names in the Pendenz-Version header of every answer. Ordered as in
// semantic versioning: 0.3.0-rc.1 comes before 0.3.0, because a release candidate may still
// lack something the release has.
nonisolated struct ServerVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    // The oldest server this build works with. Raise it whenever the app starts to send a
    // route, a method or a field that an older server does not know: a change such a server
    // refuses then waits in the outbox instead of being dropped.
    static let minimum = ServerVersion("0.3.0")!

    // A server from before the header.
    static let legacy = ServerVersion("0.1.0")!

    let description: String
    private let core: [Int]
    private let prerelease: [String]

    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        // Build metadata after "+" does not count for the order.
        let withoutBuild = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init) : []
        guard !prerelease.contains(where: \.isEmpty) else { return nil }
        description = text
        core = numbers.compactMap(\.self)
        self.prerelease = prerelease
    }

    // The version an answer names. One without the header comes from a server before it.
    init(header: String?) {
        self = header.flatMap(ServerVersion.init) ?? .legacy
    }

    static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        lhs.core == rhs.core && lhs.prerelease == rhs.prerelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(core)
        hasher.combine(prerelease)
    }

    static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        // A release comes after every pre-release of it.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case (let left?, let right?): return left < right
            // Numbers come before words.
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

import Foundation

nonisolated struct Project: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    // The name of the symbol drawn next to the name. Missing means the default.
    var icon: String?
    // True once the project was deleted. The row stays, so every device learns about it.
    var deleted = false
    var seq: Int
    // When the server made the row, as it sends it: UTC in one fixed shape, so two of them
    // compare as text. Missing until the server has answered for a project made here.
    var createdAt: String?

    var symbol: String {
        icon ?? Self.defaultSymbol
    }

    static let defaultSymbol = "number"
    // What the server accepts. The name is counted in Unicode scalars there.
    static let nameLimit = 80
    static let idLimit = 40

    // The symbols a project can choose from, with the words VoiceOver reads for each.
    static let symbols: [(name: String, label: String)] = [
        ("number", "Number sign"), ("house", "House"), ("briefcase", "Briefcase"), ("cart", "Cart"),
        ("book", "Book"), ("graduationcap", "Graduation cap"), ("heart", "Heart"), ("star", "Star"),
        ("flag", "Flag"), ("bolt", "Bolt"), ("leaf", "Leaf"), ("pawprint", "Paw print"),
        ("hammer", "Hammer"), ("wrench.and.screwdriver", "Tools"), ("server.rack", "Server"),
        ("desktopcomputer", "Computer"), ("chevron.left.forwardslash.chevron.right", "Code"),
        ("banknote", "Banknote"), ("car", "Car"), ("airplane", "Airplane"), ("fork.knife", "Fork and knife"),
        ("dumbbell", "Dumbbell"), ("music.note", "Music note"), ("lightbulb", "Light bulb"),
    ]

    // The ID of a project made on this device: its name in lowercase letters, digits and
    // hyphens, as the server would make it, with a number behind it when that is taken. The app
    // chooses it, so items can be filed under the project before the server has answered.
    static func makeID(for name: String, taken: Set<String>) -> String {
        var text = ""
        for character in name.lowercased().folding(options: .diacriticInsensitive, locale: nil) {
            if character.isASCII, character.isLetter || character.isNumber {
                text.append(character)
            } else if !text.hasSuffix("-") {
                text.append("-")
            }
        }
        let hyphen = CharacterSet(charactersIn: "-")
        var base = String(text.trimmingCharacters(in: hyphen).prefix(idLimit)).trimmingCharacters(in: hyphen)
        if base.isEmpty || base == "inbox" { base = "project" }
        var id = base
        var number = 1
        while taken.contains(id) {
            number += 1
            let suffix = "-\(number)"
            id = String(base.prefix(idLimit - suffix.count)).trimmingCharacters(in: hyphen) + suffix
        }
        return id
    }
}

// Read by hand: a row stored before projects could be deleted has no `deleted`.
nonisolated extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, deleted, seq, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            icon: container.decodeIfPresent(String.self, forKey: .icon),
            deleted: container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false,
            seq: container.decode(Int.self, forKey: .seq),
            createdAt: container.decodeIfPresent(String.self, forKey: .createdAt),
        )
    }
}

// How the lists of projects are ordered: the sidebar and the Tasks tab. The menus that file an
// item under a project stay sorted by name.
nonisolated enum ProjectOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    // The project made last comes first.
    case added
    // The project whose items, notes or own row changed last comes first.
    case edited

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .added: "Date Added"
        case .edited: "Last Edited"
        }
    }
}

// A project made on this device, with the ID the app already shows it under.
nonisolated struct NewProject: Equatable, Sendable, Codable {
    var id: String
    var name: String
    var icon: String?
}

// A new name, a new icon or both. The default icon travels under its own name, so there is
// nothing to clear.
nonisolated struct ProjectPatch: Equatable, Sendable, Codable {
    var name: String?
    var icon: String?

    var isEmpty: Bool {
        self == ProjectPatch()
    }

    func apply(to project: inout Project) {
        if let name { project.name = name }
        if let icon { project.icon = icon }
    }
}

// The sheet that makes a project or edits one.
nonisolated enum ProjectEditor: Identifiable, Hashable, Sendable {
    case new
    case edit(String)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): "edit-\(id)"
        }
    }
}

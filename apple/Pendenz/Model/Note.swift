import Foundation

// A note as the server returns it: markdown text whose first line is its title. The same
// shape is kept on disk.
nonisolated struct Note: Identifiable, Hashable, Sendable, Codable {
    // Below zero for a note that was written on this device and has not reached the server.
    var id: Int
    var body: String
    var projectId: String?
    var pinned: Bool
    var hiddenFromAgents: Bool
    // The app asks for Face ID or Touch ID before it shows the text. See `NoteLock`.
    var locked = false
    var trashed: Bool
    var version: Int
    var seq: Int
    // The time of the last edit as the server writes it, "2026-11-12T14:33:36.095Z". Kept as
    // text: these sort in the order of their times.
    var updatedAt: String
    // The files the server holds for it, pictures among them. Missing in rows from a server or
    // a build before files on notes.
    var files: [ItemFile] = []

    // What the server accepts.
    static let bodyLimit = 100_000

    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    var edited: Date? {
        try? Date(updatedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // The first line with text in it, without the marks of a markdown heading.
    var title: String {
        Self.title(of: body)
    }

    // What follows the title, on one line, for the row in the list.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.dropFirst().prefix(3).joined(separator: " ")
    }

    static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let plain = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? line : plain
    }
}

// Written by hand for one reason: a server or a stored row from before the lock or the files
// sends no `locked` or `files`, and such a note has to read as one without a lock or files. In an extension, so the
// memberwise initialiser stays.
nonisolated extension Note {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            body: container.decode(String.self, forKey: .body),
            projectId: container.decodeIfPresent(String.self, forKey: .projectId),
            pinned: container.decode(Bool.self, forKey: .pinned),
            hiddenFromAgents: container.decode(Bool.self, forKey: .hiddenFromAgents),
            locked: container.decodeIfPresent(Bool.self, forKey: .locked) ?? false,
            trashed: container.decode(Bool.self, forKey: .trashed),
            version: container.decode(Int.self, forKey: .version),
            seq: container.decode(Int.self, forKey: .seq),
            updatedAt: container.decode(String.self, forKey: .updatedAt),
            files: container.decodeIfPresent([ItemFile].self, forKey: .files) ?? [],
        )
    }
}

// What a new note sends. Fields left out take the server's defaults.
nonisolated struct NewNote: Equatable, Sendable, Codable {
    var body: String
    var projectId: String?
    var pinned = false
    var hiddenFromAgents = false
}

extension Note {
    // How a new note looks in the list until the server has answered.
    nonisolated init(local new: NewNote, id: Int, updatedAt: String) {
        self.init(
            id: id, body: new.body, projectId: new.projectId, pinned: new.pinned,
            hiddenFromAgents: new.hiddenFromAgents, trashed: false, version: 0, seq: 0, updatedAt: updatedAt,
        )
    }
}

// The fields of an edit to a note. Only the ones that are set are sent.
nonisolated struct NotePatch: Equatable, Sendable, Codable {
    var body: String?
    var projectId: Clearable<String>?
    var pinned: Bool?
    var hiddenFromAgents: Bool?
    var locked: Bool?
    var trashed: Bool?

    var isEmpty: Bool {
        self == NotePatch()
    }

    func apply(to note: inout Note) {
        if let body { note.body = body }
        if let projectId { note.projectId = projectId.value }
        if let pinned { note.pinned = pinned }
        if let hiddenFromAgents { note.hiddenFromAgents = hiddenFromAgents }
        if let locked { note.locked = locked }
        if let trashed { note.trashed = trashed }
    }

    // Lays a later edit over this one, so two edits in a row travel as one request.
    mutating func merge(_ later: NotePatch) {
        body = later.body ?? body
        projectId = later.projectId ?? projectId
        pinned = later.pinned ?? pinned
        hiddenFromAgents = later.hiddenFromAgents ?? hiddenFromAgents
        locked = later.locked ?? locked
        trashed = later.trashed ?? trashed
    }

    private enum CodingKeys: String, CodingKey {
        case body, projectId, pinned, hiddenFromAgents, locked, trashed
    }
}

// Written by hand for the same reason as in ItemPatch: "no project" travels as null, and a
// null must not read back as "not set".
nonisolated extension NotePatch {
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        if container.contains(.projectId) {
            projectId = try container.decodeNil(forKey: .projectId)
                ? .clear : .set(container.decode(String.self, forKey: .projectId))
        }
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
        hiddenFromAgents = try container.decodeIfPresent(Bool.self, forKey: .hiddenFromAgents)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked)
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(body, forKey: .body)
        switch projectId {
        case nil: break
        case .clear: try container.encodeNil(forKey: .projectId)
        case .set(let id): try container.encode(id, forKey: .projectId)
        }
        try container.encodeIfPresent(pinned, forKey: .pinned)
        try container.encodeIfPresent(hiddenFromAgents, forKey: .hiddenFromAgents)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encodeIfPresent(trashed, forKey: .trashed)
    }
}

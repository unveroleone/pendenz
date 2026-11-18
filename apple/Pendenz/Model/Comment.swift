import Foundation

// A comment on an item: a question, a plan or a result, mostly from an agent. The owner can
// edit it, mark it outdated and delete it. A deleted comment arrives once more from the server
// with `deleted` set, so this device learns that it is gone.
nonisolated struct Comment: Identifiable, Hashable, Sendable, Codable {
    var id: Int
    var itemId: Int
    // The actor who wrote it: "owner" or an agent's ID.
    var authorId: String
    var body: String
    var seq: Int
    // As the server writes it, "2026-11-12T14:33:36.095Z".
    var createdAt: String
    // A server before 0.4.0 sends none of the fields below. Its comments cannot be changed,
    // and these are what they were then.
    var version = 1
    var outdated = false
    var deleted = false
    // Set when the text was changed. Nil for a comment that was never edited.
    var editedAt: String?

    // What the server accepts.
    static let bodyLimit = 10000

    var created: Date? {
        Self.date(createdAt)
    }

    var isEdited: Bool {
        editedAt != nil
    }

    private static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601))
    }

    private enum CodingKeys: String, CodingKey {
        case id, itemId, authorId, body, seq, createdAt, version, outdated, deleted, editedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        itemId = try container.decode(Int.self, forKey: .itemId)
        authorId = try container.decode(String.self, forKey: .authorId)
        body = try container.decode(String.self, forKey: .body)
        seq = try container.decode(Int.self, forKey: .seq)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        outdated = try container.decodeIfPresent(Bool.self, forKey: .outdated) ?? false
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        editedAt = try container.decodeIfPresent(String.self, forKey: .editedAt)
    }
}

// A change to a comment: a new text, the outdated mark, or both.
nonisolated struct CommentPatch: Equatable, Sendable, Codable {
    var body: String?
    var outdated: Bool?

    func apply(to comment: inout Comment) {
        if let body, body != comment.body {
            comment.body = body
            // Shown as edited before the server has answered.
            comment.editedAt = comment.editedAt ?? Note.stamp(.now)
        }
        if let outdated { comment.outdated = outdated }
    }

    // Lays a later edit over this one, so two edits in a row travel as one request.
    mutating func merge(_ later: CommentPatch) {
        body = later.body ?? body
        outdated = later.outdated ?? outdated
    }
}

// The people and agents that write on this server, by their ID, as the server names them.
nonisolated struct Author: Sendable, Codable {
    let id: String
    let name: String
    let kind: String

    var isOwner: Bool {
        kind == "human"
    }
}

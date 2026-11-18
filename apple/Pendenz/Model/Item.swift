import Foundation

nonisolated struct ChecklistLine: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var text: String
    var done: Bool
}

// An item as the server returns it. The same shape is kept on disk.
nonisolated struct Item: Identifiable, Hashable, Sendable, Codable {
    enum Status: String, Sendable, Codable {
        case todo, doing, done
    }

    // Below zero for an item that was added on this device and has not reached the server.
    var id: Int
    var title: String
    var description: String
    var status: Status
    var projectId: String?
    var priority: Int
    var position: Double
    var tags: [String]
    var checklist: [ChecklistLine]
    var dueAt: Due?
    var dueTz: String?
    var remindAt: Date?
    var repeatRule: String?
    var hiddenFromAgents: Bool
    var createdVia: String
    var sourceUrl: String?
    var archived: Bool
    var trashed: Bool
    // The server refuses an edit that names an older version than the one it holds.
    var version: Int
    // Grows with every write on the server. The higher number is the newer state of a row.
    var seq: Int
    // When it was completed, as the server sends it: UTC in one fixed shape, so two of them
    // compare as text. Missing while the item is open and until the server has answered.
    var completedAt: String?
    // The files the server holds for it, pictures among them. Missing in rows stored by a build
    // without files.
    var files: [ItemFile] = []
    // Where an agent is with it: "new", "none", "gathering", "needs_answer", "ready", "running",
    // "review" or "declined". Kept as text, so a stage a newer server adds reads as unknown.
    // Missing in rows stored by a build before the Agents screen.
    var agentStage: String?

    // The day it was completed, on this device's calendar.
    var completedDay: Day? {
        guard let completedAt else { return nil }
        let date = (try? Date(completedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(completedAt, strategy: .iso8601))
        return date.map { Day($0) }
    }

    // What the server accepts. Text is cut to these before it is queued, because a refused
    // request would take the other edits it travels with down with it.
    static let titleLimit = 240
    static let descriptionLimit = 20000
    static let stepLimit = 500
    static let stepCount = 100

    var isOpen: Bool {
        status != .done && !trashed && !archived
    }

    // When the reminder fires: its own time, or the due time when that has one.
    var reminderDate: Date? {
        remindAt ?? dueAt?.time
    }
}

// Written by hand for one reason: a row stored before files existed has no list of them and has
// to read as an item without any. In an extension, so the memberwise initialiser stays.
nonisolated extension Item {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(Int.self, forKey: .id),
            title: container.decode(String.self, forKey: .title),
            description: container.decode(String.self, forKey: .description),
            status: container.decode(Status.self, forKey: .status),
            projectId: container.decodeIfPresent(String.self, forKey: .projectId),
            priority: container.decode(Int.self, forKey: .priority),
            position: container.decode(Double.self, forKey: .position),
            tags: container.decode([String].self, forKey: .tags),
            checklist: container.decode([ChecklistLine].self, forKey: .checklist),
            dueAt: container.decodeIfPresent(Due.self, forKey: .dueAt),
            dueTz: container.decodeIfPresent(String.self, forKey: .dueTz),
            remindAt: container.decodeIfPresent(Date.self, forKey: .remindAt),
            repeatRule: container.decodeIfPresent(String.self, forKey: .repeatRule),
            hiddenFromAgents: container.decode(Bool.self, forKey: .hiddenFromAgents),
            createdVia: container.decode(String.self, forKey: .createdVia),
            sourceUrl: container.decodeIfPresent(String.self, forKey: .sourceUrl),
            archived: container.decode(Bool.self, forKey: .archived),
            trashed: container.decode(Bool.self, forKey: .trashed),
            version: container.decode(Int.self, forKey: .version),
            seq: container.decode(Int.self, forKey: .seq),
            completedAt: container.decodeIfPresent(String.self, forKey: .completedAt),
            files: container.decodeIfPresent([ItemFile].self, forKey: .files) ?? [],
            agentStage: container.decodeIfPresent(String.self, forKey: .agentStage),
        )
    }
}

// A file on an item, as the server lists it, byte for byte as it was added. The hash names the
// copy kept on this device: a server restored from a backup can give the ID to another file, the
// hash stays true. The upload ID is the one the adding device sent along: it tells that device
// which file its upload became, which the hash cannot when the same bytes are added twice. A
// picture the server could measure has its width and height.
nonisolated struct ItemFile: Identifiable, Hashable, Sendable, Codable {
    var id: Int
    var name: String
    var mime: String
    var bytes: Int
    var sha256: String
    var uploadId: String?
    var width: Int?
    var height: Int?
}

// A file that waits to be sent. Its bytes lie in a file named by the ID, which is also the
// upload ID the server keeps. A photo was scaled here and knows its size already.
nonisolated struct PendingFile: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    var mime: String
    var bytes: Int
    var width: Int?
    var height: Int?
    // Set before the first request for it leaves. From then on the server may hold the file,
    // whatever became of the answer.
    var isSent = false
    // Removed here after it was sent. It is no longer shown, and it is removed from the server
    // as soon as the upload has told which file it became there.
    var isUnwanted = false
}

// One file as an item shows it: held by the server, or still waiting here.
nonisolated enum ShownFile: Identifiable, Hashable, Sendable {
    case stored(ItemFile)
    case waiting(PendingFile)

    var id: String {
        switch self {
        case .stored(let file): "s\(file.id)"
        case .waiting(let file): "w\(file.id)"
        }
    }

    var name: String {
        switch self {
        case .stored(let file): file.name
        case .waiting(let file): file.name
        }
    }

    var mime: String {
        switch self {
        case .stored(let file): file.mime
        case .waiting(let file): file.mime
        }
    }

    var bytes: Int {
        switch self {
        case .stored(let file): file.bytes
        case .waiting(let file): file.bytes
        }
    }

    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }

    // A picture is shown as a thumbnail, any other file as a row.
    var isPicture: Bool {
        switch self {
        case .stored(let file): file.width != nil && file.height != nil
        case .waiting(let file): file.width != nil && file.height != nil
        }
    }
}

// What quick add sends. Fields left out take the server's defaults.
nonisolated struct NewItem: Equatable, Sendable, Codable {
    var title: String
    // Set when a note becomes an item.
    var description: String?
    var projectId: String?
    var dueAt: Due?
    var dueTz: String?
    var repeatRule: String?
    var hiddenFromAgents = false
    var createdVia = "app"
    // Set when text is dropped between two rows. Without it the server puts the item on top.
    var position: Double?
    var sourceUrl: String?
}

extension Item {
    // How a new item looks in the lists until the server has answered.
    nonisolated init(local new: NewItem, id: Int, position: Double) {
        self.init(
            id: id, title: new.title, description: new.description ?? "", status: .todo, projectId: new.projectId,
            priority: 0, position: new.position ?? position, tags: [], checklist: [], dueAt: new.dueAt,
            dueTz: new.dueTz, remindAt: nil, repeatRule: new.repeatRule,
            hiddenFromAgents: new.hiddenFromAgents, createdVia: new.createdVia, sourceUrl: new.sourceUrl,
            archived: false, trashed: false, version: 0, seq: 0,
        )
    }
}

// A field of an edit that can also be emptied: a due date is set to a value or cleared.
nonisolated enum Clearable<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
    case clear
    case set(Value)

    var value: Value? {
        if case .set(let value) = self { value } else { nil }
    }
}

// The fields of an edit. Only the ones that are set are sent and laid over the item.
nonisolated struct ItemPatch: Equatable, Sendable, Codable {
    var title: String?
    var description: String?
    var status: Item.Status?
    var projectId: Clearable<String>?
    var priority: Int?
    var checklist: [ChecklistLine]?
    var dueAt: Clearable<Due>?
    var dueTz: String?
    var remindAt: Clearable<Date>?
    var repeatRule: Clearable<String>?
    var hiddenFromAgents: Bool?
    var trashed: Bool?
    var position: Double?

    var isEmpty: Bool {
        self == ItemPatch()
    }

    func apply(to item: inout Item) {
        if let title { item.title = title }
        if let description { item.description = description }
        if let status { item.status = status }
        if let projectId { item.projectId = projectId.value }
        if let priority { item.priority = priority }
        if let checklist { item.checklist = checklist }
        if let dueAt {
            item.dueAt = dueAt.value
            if dueAt == .clear { item.dueTz = nil }
        }
        if let dueTz { item.dueTz = dueTz }
        if let remindAt { item.remindAt = remindAt.value }
        if let repeatRule { item.repeatRule = repeatRule.value }
        if let hiddenFromAgents { item.hiddenFromAgents = hiddenFromAgents }
        if let trashed { item.trashed = trashed }
        if let position { item.position = position }
    }

    // Lays a later edit over this one, so two edits in a row travel as one request.
    mutating func merge(_ later: ItemPatch) {
        title = later.title ?? title
        description = later.description ?? description
        status = later.status ?? status
        projectId = later.projectId ?? projectId
        priority = later.priority ?? priority
        checklist = later.checklist ?? checklist
        dueAt = later.dueAt ?? dueAt
        // A cleared date takes its zone with it.
        dueTz = later.dueAt == .clear ? nil : later.dueTz ?? dueTz
        remindAt = later.remindAt ?? remindAt
        repeatRule = later.repeatRule ?? repeatRule
        hiddenFromAgents = later.hiddenFromAgents ?? hiddenFromAgents
        trashed = later.trashed ?? trashed
        position = later.position ?? position
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, status, projectId, priority, checklist, dueAt, dueTz, remindAt
        case repeatRule, hiddenFromAgents, trashed, position
    }
}

// Written by hand: "cleared" travels as null, and a null must not read back as "not set".
// In an extension, so the struct keeps its memberwise initialiser.
nonisolated extension ItemPatch {
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func clearable<Value>(_ key: CodingKeys) throws -> Clearable<Value>? {
            guard container.contains(key) else { return nil }
            return try container.decodeNil(forKey: key) ? .clear : .set(container.decode(Value.self, forKey: key))
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(Item.Status.self, forKey: .status)
        projectId = try clearable(.projectId)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        checklist = try container.decodeIfPresent([ChecklistLine].self, forKey: .checklist)
        dueAt = try clearable(.dueAt)
        dueTz = try container.decodeIfPresent(String.self, forKey: .dueTz)
        remindAt = try clearable(.remindAt)
        repeatRule = try clearable(.repeatRule)
        hiddenFromAgents = try container.decodeIfPresent(Bool.self, forKey: .hiddenFromAgents)
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed)
        position = try container.decodeIfPresent(Double.self, forKey: .position)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func write(_ field: Clearable<some Any>?, _ key: CodingKeys) throws {
            switch field {
            case nil: break
            case .clear: try container.encodeNil(forKey: key)
            case .set(let value): try container.encode(value, forKey: key)
            }
        }
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(status, forKey: .status)
        try write(projectId, .projectId)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(checklist, forKey: .checklist)
        try write(dueAt, .dueAt)
        try container.encodeIfPresent(dueTz, forKey: .dueTz)
        try write(remindAt, .remindAt)
        try write(repeatRule, .repeatRule)
        try container.encodeIfPresent(hiddenFromAgents, forKey: .hiddenFromAgents)
        try container.encodeIfPresent(trashed, forKey: .trashed)
        try container.encodeIfPresent(position, forKey: .position)
    }
}

// A change made on this device that the server has not confirmed yet.
nonisolated enum PendingWrite: Sendable, Codable {
    case create(localID: Int, item: NewItem)
    case update(itemID: Int, patch: ItemPatch)
    case createNote(localID: Int, note: NewNote)
    case updateNote(noteID: Int, patch: NotePatch)
    case createProject(NewProject)
    case updateProject(projectID: String, patch: ProjectPatch)
    case deleteProject(projectID: String)
    case addFile(itemID: Int, file: PendingFile)
    case removeFile(itemID: Int, fileID: Int)
    case updateComment(itemID: Int, commentID: Int, patch: CommentPatch)
    case deleteComment(itemID: Int, commentID: Int)
}

extension PendingWrite {
    // What a change is about, for keeping the changes to one row in order.
    nonisolated struct Rows {
        var items: Set<Int> = []
        var notes: Set<Int> = []
        // The project a change to a project is about.
        var project: String?
        // The project a new or moved item or note is filed into.
        var filedInto: String?
    }

    var rows: Rows {
        switch self {
        case .create(let localID, let item): Rows(items: [localID], filedInto: item.projectId)
        case .update(let id, let patch): Rows(items: [id], filedInto: patch.projectId?.value)
        case .createNote(let localID, let note): Rows(notes: [localID], filedInto: note.projectId)
        case .updateNote(let id, let patch): Rows(notes: [id], filedInto: patch.projectId?.value)
        case .createProject(let project): Rows(project: project.id)
        case .updateProject(let id, _), .deleteProject(let id): Rows(project: id)
        case .addFile(let id, _), .removeFile(let id, _): Rows(items: [id])
        case .updateComment(let id, _, _), .deleteComment(let id, _): Rows(items: [id])
        }
    }
}

nonisolated struct PendingEntry: Sendable {
    // The idempotency key. It stays the same for every retry of this request.
    var key: String
    var order: Int
    // A completion waits a moment before it is sent, so a second tap can take it back.
    var sendAfter: Date
    var write: PendingWrite
    // The version of a server that refused this change for being older than this build needs.
    // The change then waits until the server is updated.
    var heldFor: String?
}

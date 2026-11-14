import Foundation
import SwiftData

// The rows on disk. Each keeps the item as JSON, so a new field on the server needs no
// migration here: rows that no longer decode are dropped and loaded again from the server.
@Model
final class StoredItem {
    @Attribute(.unique) var id: Int
    var isOpen: Bool
    // Lets the trash be read without decoding every done item.
    var isTrashed: Bool = false
    var payload: Data

    init(id: Int, isOpen: Bool, isTrashed: Bool, payload: Data) {
        self.id = id
        self.isOpen = isOpen
        self.isTrashed = isTrashed
        self.payload = payload
    }
}

@Model
final class StoredProject {
    @Attribute(.unique) var id: String
    var payload: Data

    init(id: String, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

@Model
final class StoredNote {
    @Attribute(.unique) var id: Int
    var isTrashed: Bool
    var payload: Data

    init(id: Int, isTrashed: Bool, payload: Data) {
        self.id = id
        self.isTrashed = isTrashed
        self.payload = payload
    }
}

@Model
final class StoredWrite {
    @Attribute(.unique) var key: String
    var order: Int
    var sendAfter: Date
    var payload: Data

    init(key: String, order: Int, sendAfter: Date, payload: Data) {
        self.key = key
        self.order = order
        self.sendAfter = sendAfter
        self.payload = payload
    }
}

@Model
final class StoredState {
    var server: String
    var cursor: Int
    // Which build wrote the rows. See `LocalStore.format`.
    var format: Int = 0

    init(server: String, cursor: Int, format: Int) {
        self.server = server
        self.cursor = cursor
        self.format = format
    }
}

// The copy of the server's rows on this device, and the changes that still wait to be sent.
// The rows can always be loaded again. The waiting changes exist only here.
final class LocalStore {
    struct Snapshot {
        var items: [Item] = []
        var projects: [Project] = []
        var notes: [Note] = []
        var cursor = 0
        var outbox: [PendingEntry] = []
    }

    // Raised when rows on disk need a pass before this build can use them.
    // 1: an item's row says whether it is in the trash.
    // 2: a project's row says when it was made.
    // 3: an item's row says when it was completed.
    // 4: a note's row says whether it is locked.
    private static let format = 4

    // Kept alive here: a context whose container is gone traps on its first fetch.
    private let container: ModelContainer
    private let context: ModelContext
    private let server: String
    // False when the file could not be opened and the store only lives in memory.
    let isDurable: Bool
    // Set when the pairing this store belongs to has ended. A request that was still on its
    // way then cannot write its answer into the file, which may belong to a new pairing by then.
    private var isClosed = false

    init(server: URL) {
        self.server = server.absoluteString
        let schema = Schema([StoredItem.self, StoredProject.self, StoredNote.self, StoredWrite.self, StoredState.self])
        do {
            container = try ModelContainer(for: schema)
            isDurable = true
        } catch {
            // A store that cannot be opened must not keep the app from starting. It then runs
            // from memory and loads everything from the server, and the person is told.
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: memory)
            isDurable = false
        }
        context = container.mainContext
        context.autosaveEnabled = false
    }

    // Open items, the projects, the notes, the cursor and the waiting changes. Done items and
    // trashed notes stay on disk.
    func load() -> Snapshot {
        let states: [StoredState]
        do {
            states = try context.fetch(FetchDescriptor<StoredState>())
        } catch {
            // The store cannot be read. Run from the server and leave the file alone.
            return Snapshot()
        }
        guard let state = states.first, state.server == server else {
            // A first launch, or another server than last time: nothing here belongs to it,
            // the queue included.
            try? wipe(includingOutbox: true)
            return Snapshot()
        }
        var snapshot = Snapshot(cursor: state.cursor)
        let decoder = JSONDecoder()
        if state.format < Self.format {
            // Rows from before the trash screen do not say whether they are in the trash.
            let closed = (try? context.fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { !$0.isOpen }))) ?? []
            for row in closed where (try? decoder.decode(Item.self, from: row.payload))?.trashed == true {
                row.isTrashed = true
            }
            if state.format < 4 {
                // Rows stored by an older build lack a field: when a project was made, when an
                // item was completed, whether a note is locked. The server sends every row
                // again from the start, and each replaces the one kept here.
                state.cursor = 0
                snapshot.cursor = 0
                // The notes do not wait here for their replacement: one that was locked on
                // another device would show its text until the sync is through, and without
                // a connection that can be a long time. Waiting changes to them stay queued.
                try? context.delete(model: StoredNote.self)
            }
            state.format = Self.format
            try? context.save()
        }
        // A waiting change that cannot be read is dropped by itself. The others stay.
        let writes = (try? context.fetch(FetchDescriptor<StoredWrite>(sortBy: [SortDescriptor(\.order)]))) ?? []
        for row in writes {
            if let write = try? decoder.decode(PendingWrite.self, from: row.payload) {
                snapshot.outbox.append(PendingEntry(
                    key: row.key,
                    order: row.order,
                    sendAfter: row.sendAfter,
                    write: write,
                ))
            } else {
                context.delete(row)
            }
        }
        do {
            // The open rows, and any row a waiting change is about: reopening a done item has
            // to find it.
            let targets = snapshot.outbox.compactMap { entry -> Int? in
                switch entry.write {
                case .update(let id, _), .addImage(let id, _), .removeImage(let id, _): id
                default: nil
                }
            }
            let wanted = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.isOpen || targets.contains($0.id) })
            snapshot.items = try context.fetch(wanted).map { try decoder.decode(Item.self, from: $0.payload) }
            snapshot.projects = try context.fetch(FetchDescriptor<StoredProject>())
                .map { try decoder.decode(Project.self, from: $0.payload) }
            let noteTargets = snapshot.outbox.compactMap { entry -> Int? in
                if case .updateNote(let id, _) = entry.write { id } else { nil }
            }
            let listed =
                FetchDescriptor<StoredNote>(predicate: #Predicate { !$0.isTrashed || noteTargets.contains($0.id) })
            snapshot.notes = try context.fetch(listed).map { try decoder.decode(Note.self, from: $0.payload) }
        } catch {
            // The rows were written by an older build. Load them again from the server.
            try? wipe(includingOutbox: false)
            snapshot.items = []
            snapshot.projects = []
            snapshot.notes = []
            snapshot.cursor = 0
        }
        return snapshot
    }

    // Stages rows and the cursor. Nothing is on disk until `commit`.
    func put(items: [Item], projects: [Project], notes: [Note], cursor: Int) {
        guard !isClosed else { return }
        // Plain keys on disk. The snake case of the API is only for the wire: converting keys
        // there and back does not return every name unchanged.
        let encoder = JSONEncoder()
        for item in items {
            guard let payload = try? encoder.encode(item) else { continue }
            // A row with a known ID replaces the stored one.
            context.insert(StoredItem(id: item.id, isOpen: item.isOpen, isTrashed: item.trashed, payload: payload))
        }
        for project in projects {
            guard let payload = try? encoder.encode(project) else { continue }
            context.insert(StoredProject(id: project.id, payload: payload))
        }
        for note in notes {
            guard let payload = try? encoder.encode(note) else { continue }
            context.insert(StoredNote(id: note.id, isTrashed: note.trashed, payload: payload))
        }
        state().cursor = cursor
    }

    // What is in the trash. The store loads it when the trash is opened, not at launch.
    func trashed() -> (items: [Item], notes: [Note]) {
        guard !isClosed else { return ([], []) }
        let decoder = JSONDecoder()
        let items = (try? context.fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.isTrashed }))) ?? []
        let notes = (try? context.fetch(FetchDescriptor<StoredNote>(predicate: #Predicate { $0.isTrashed }))) ?? []
        return (
            items.compactMap { try? decoder.decode(Item.self, from: $0.payload) },
            notes.compactMap { try? decoder.decode(Note.self, from: $0.payload) },
        )
    }

    // Every finished item. The store loads them when Completed is opened, not at launch.
    func completed() -> [Item] {
        guard !isClosed else { return [] }
        let decoder = JSONDecoder()
        let closed = (try? context
            .fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { !$0.isOpen && !$0.isTrashed }))) ?? []
        return closed.compactMap { try? decoder.decode(Item.self, from: $0.payload) }
            .filter { $0.status == .done && !$0.archived }
    }

    func put(_ entry: PendingEntry) {
        guard !isClosed, let payload = try? JSONEncoder().encode(entry.write) else { return }
        context.insert(StoredWrite(key: entry.key, order: entry.order, sendAfter: entry.sendAfter, payload: payload))
    }

    func remove(key: String) {
        guard !isClosed else { return }
        try? context.delete(model: StoredWrite.self, where: #Predicate { $0.key == key })
    }

    // The server came back from an older backup: its rows replace the ones here.
    func dropRows() {
        guard !isClosed else { return }
        try? wipe(includingOutbox: false)
    }

    // This device was unpaired: nothing of the server's data stays on it, the queue included.
    func erase() {
        context.rollback()
        try? wipe(includingOutbox: true)
        isClosed = true
    }

    // The pairing ended. What is on disk stays as it is, and nothing is added to it.
    func close() {
        context.rollback()
        isClosed = true
    }

    // False when the changes did not reach the disk.
    @discardableResult
    func commit() -> Bool {
        guard !isClosed else { return true }
        do {
            try context.save()
            return isDurable
        } catch {
            return false
        }
    }

    private func state() -> StoredState {
        if let state = try? context.fetch(FetchDescriptor<StoredState>()).first {
            return state
        }
        let state = StoredState(server: server, cursor: 0, format: Self.format)
        context.insert(state)
        return state
    }

    private func wipe(includingOutbox: Bool) throws {
        try context.delete(model: StoredItem.self)
        try context.delete(model: StoredProject.self)
        try context.delete(model: StoredNote.self)
        if includingOutbox {
            try context.delete(model: StoredWrite.self)
        }
        try context.delete(model: StoredState.self)
        context.insert(StoredState(server: server, cursor: 0, format: Self.format))
        try context.save()
    }
}

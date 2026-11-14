import AppIntents
import CoreSpotlight
import Foundation

// Keeps Spotlight's copy of the open items and the notes in step with the store, on this device
// only. A result opens through `OpenItemIntent` or `OpenNoteIntent`. Only what changed is sent
// again, a moment after the last change, so typing in a note does not index every key. Every
// call to the index runs in one queue, in the order it was asked for.
final class SpotlightFeed {
    static let shared = SpotlightFeed()

    // What the index holds for this pairing, by ID, as the text it was given. Missing until the
    // first full update, which first removes whatever an earlier launch or pairing left there.
    private var indexedItems: [Int: String]?
    private var indexedNotes: [Int: String]?
    // The notes whose text is in the index. A lock takes the text out at once, without the
    // moment's wait.
    private var notesWithText: Set<Int> = []
    // The update that waits for the moment after the last change.
    private var waiting: Task<Void, Never>?
    // The last call in the queue. The next one starts after it.
    private var queue: Task<Void, Never>?
    // Counts the pairings that ended. An update asked for by one of them writes nothing.
    private var epoch = 0

    private static let delay: Duration = .seconds(2)

    // The rows changed. One waiting update covers every change until it runs.
    func changed(_ store: Store) {
        if store.notes.contains(where: { $0.locked && notesWithText.contains($0.id) }) {
            waiting?.cancel()
            waiting = nil
            enqueueUpdate(store)
            return
        }
        guard waiting == nil else { return }
        let epoch = epoch
        waiting = Task { [weak store] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            waiting = nil
            guard let store, epoch == self.epoch else { return }
            enqueueUpdate(store)
        }
    }

    // Brings the index up to date now and waits for it. For a launch in the background, which
    // may be suspended right after its handler returns.
    func flush(_ store: Store) async {
        waiting?.cancel()
        waiting = nil
        enqueueUpdate(store)
        await queue?.value
    }

    // The pairing ended. Nothing of it stays in Spotlight. Also called at a launch without a
    // pairing, which tries again what an earlier launch could not remove.
    func clear() {
        epoch += 1
        waiting?.cancel()
        waiting = nil
        indexedItems = nil
        indexedNotes = nil
        notesWithText = []
        enqueue {
            for attempt in 0 ..< 3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
                do {
                    try await CSSearchableIndex.default().deleteAppEntities(ofType: ItemEntity.self)
                    try await CSSearchableIndex.default().deleteAppEntities(ofType: NoteEntity.self)
                    return
                } catch {}
            }
        }
    }

    private func enqueueUpdate(_ store: Store) {
        let epoch = epoch
        enqueue { [weak store] in
            guard let store, !store.isClosed, epoch == self.epoch else { return }
            await self.update(from: store, epoch: epoch)
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            await work()
        }
    }

    private func update(from store: Store, epoch: Int) async {
        // Rows the server has not numbered yet wait: such a number means another row after the
        // next launch.
        let notes = store.notes.filter { $0.id > 0 }.map(NoteEntity.init)
        // Until this launch has synced, the rows are what was on disk, and a note may have been
        // locked on another device since. Only the locks are passed on until then: a locked
        // note is sent again with its title alone, which replaces what the index had.
        guard store.isCurrent else {
            let locked = notes.filter(\.isLocked)
            guard !locked.isEmpty,
                  await (try? CSSearchableIndex.default().indexAppEntities(locked)) != nil else { return }
            notesWithText.subtract(locked.map(\.id))
            if indexedNotes != nil {
                for note in locked { indexedNotes?[note.id] = note.spotlightText }
            }
            return
        }
        let items = store.openItems.filter { $0.isOpen && $0.id > 0 }.map { ItemEntity($0, in: store) }
        do {
            if indexedItems == nil || indexedNotes == nil {
                try await CSSearchableIndex.default().deleteAppEntities(ofType: ItemEntity.self)
                try await CSSearchableIndex.default().deleteAppEntities(ofType: NoteEntity.self)
                indexedItems = [:]
                indexedNotes = [:]
                notesWithText = []
            }
            indexedItems = try await send(items, against: indexedItems ?? [:], epoch: epoch)
            indexedNotes = try await send(notes, against: indexedNotes ?? [:], epoch: epoch)
            notesWithText = Set(notes.filter { !$0.isLocked && !$0.text.isEmpty }.map(\.id))
        } catch {
            // From the start with the next change. Until then the index may hold text of a note
            // that has a lock now, so the next update of a lock is not left waiting.
            indexedItems = nil
            indexedNotes = nil
            notesWithText = Set(notes.map(\.id))
        }
    }

    private func send<Entity: IndexedEntity & SpotlightText>(
        _ entities: [Entity], against indexed: [Int: String], epoch: Int,
    ) async throws -> [Int: String] where Entity.ID == Int {
        let now = Dictionary(entities.map { ($0.id, $0.spotlightText) }, uniquingKeysWith: { $1 })
        let gone = indexed.keys.filter { now[$0] == nil }
        let changed = entities.filter { indexed[$0.id] != $0.spotlightText }
        guard epoch == self.epoch else { throw CancellationError() }
        if !gone.isEmpty { try await CSSearchableIndex.default().deleteAppEntities(
            identifiedBy: gone,
            ofType: Entity.self,
        ) }
        guard epoch == self.epoch else { throw CancellationError() }
        if !changed.isEmpty { try await CSSearchableIndex.default().indexAppEntities(changed) }
        return now
    }
}

// What an entity gives Spotlight, as one text: when it changes, the entity is indexed again.
nonisolated protocol SpotlightText {
    var spotlightText: String { get }
}

extension ItemEntity: IndexedEntity, SpotlightText {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .item)
        set.title = title
        set.contentDescription = [subtitle, details].filter { !$0.isEmpty }.joined(separator: "\n")
        set.dueDate = dueDate
        return set
    }

    var spotlightText: String {
        [title, subtitle, details, dueDate?.formatted(.iso8601) ?? ""].joined(separator: "\u{1F}")
    }
}

// A locked note is found by its title alone, as in the app's search while the lock is closed.
extension NoteEntity: IndexedEntity, SpotlightText {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .text)
        set.title = title
        if !isLocked, !text.isEmpty {
            set.contentDescription = String(text.prefix(300))
            set.textContent = text
        }
        return set
    }

    var spotlightText: String {
        [isLocked ? "locked" : "open", title, text].joined(separator: "\u{1F}")
    }
}

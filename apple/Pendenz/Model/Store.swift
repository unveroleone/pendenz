import Foundation
import Observation

// Everything the screens read. Views never wait for the network: they render what is here.
// The rows come from disk at launch and from the server's changes feed after that. A change
// made on this device goes into the outbox, shows at once and is sent when the server answers.
@Observable
final class Store {
    enum Phase: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var openItems: [Item] = []
    // Every item in memory with the waiting changes laid over it, by ID. The detail reads from
    // here, so it can still show an item that has just left its list.
    private(set) var visible: [Int: Item] = [:]
    private(set) var projects: [Project] = []
    // How the sidebar and the Tasks tab order the projects. Kept on this device.
    var projectOrder = ProjectOrder(rawValue: UserDefaults.standard.string(forKey: "projectOrder") ?? "") ?? .name {
        didSet {
            UserDefaults.standard.set(projectOrder.rawValue, forKey: "projectOrder")
            feedWidgets()
        }
    }

    // The notes that are not in the trash: pinned ones first, then by the last edit.
    private(set) var notes: [Note] = []
    // Every note in memory with the waiting changes laid over it, by ID.
    private(set) var visibleNotes: [Int: Note] = [:]
    // What is in the trash, the last one moved there first. Complete once `loadTrash` has run.
    private(set) var trashedItems: [Item] = []
    private(set) var trashedNotes: [Note] = []
    // The finished items, the last one completed first. Complete once `loadCompleted` has run.
    private(set) var completedItems: [Item] = []
    // The order of the lists that are not in the manual one, by list. Kept on this device.
    private(set) var itemOrders: [String: String] = UserDefaults.standard
        .dictionary(forKey: "itemOrders") as? [String: String] ?? [:]
    {
        didSet {
            UserDefaults.standard.set(itemOrders, forKey: "itemOrders")
            feedWidgets()
        }
    }

    private(set) var phase: Phase = .idle
    // False until this device has synced once, so an empty list is not shown as "nothing to do".
    private(set) var hasLoaded = false
    private(set) var today = Day(.now)
    // Changes that wait for the server.
    private(set) var pendingCount = 0
    // Those of them that wait until the server is updated, with the ones that depend on them.
    // See `ServerVersion.minimum`.
    private(set) var heldCount = 0
    // The version the server named in its last answer. Unknown until it answers.
    private(set) var serverVersion: ServerVersion?
    // Counts completions, for the haptic.
    private(set) var completions = 0
    // Set when the server refused a waiting change for good. The root view shows it once.
    var rejection: String?
    // The files that wait to be sent, by their item.
    private(set) var waitingFiles: [Int: [PendingFile]] = [:]
    // The server's settings as it last confirmed them, kept per server on this device. Missing
    // until a server new enough for files has answered.
    private(set) var settings: ServerSettings?
    // The comments of each item, oldest first, with the waiting changes laid over them.
    private(set) var comments: [Int: [Comment]] = [:]
    // Who writes comments, by actor ID, kept per server on this device.
    private(set) var authors: [String: Author] = [:]

    // How long a completed item stays in its list, so a second tap can take it back.
    private static let lingerTime: TimeInterval = 2

    // The server's state of the rows held in memory: the open ones and those touched since launch.
    @ObservationIgnored private var items: [Int: Item] = [:]
    @ObservationIgnored private var projectsByID: [String: Project] = [:]
    @ObservationIgnored private var notesByID: [Int: Note] = [:]
    // Every comment this device holds, deleted ones too while the app runs, so an older
    // answer cannot bring one back.
    @ObservationIgnored private var commentsByID: [Int: Comment] = [:]
    @ObservationIgnored private var outbox: [PendingEntry] = []
    @ObservationIgnored private var inFlightKey: String?
    // The server IDs of items that were added here since launch, by their local ID. A screen can
    // still hold the local ID for a moment after the server has answered.
    @ObservationIgnored private var serverIDs: [Int: Int] = [:]
    @ObservationIgnored private var noteServerIDs: [Int: Int] = [:]
    @ObservationIgnored private var lingering: [Int: Date] = [:]
    @ObservationIgnored private(set) var cursor = 0
    // Whether a pull in this launch has brought the rows up to the server's state. Until then,
    // and while the rows are fetched again after a reset, an item that is missing here may
    // still be open on the server.
    @ObservationIgnored private(set) var isCurrent = false
    // Rows merged since the last write to disk.
    @ObservationIgnored private var unsavedItems: [Int: Item] = [:]
    @ObservationIgnored private var unsavedProjects: [String: Project] = [:]
    @ObservationIgnored private var unsavedNotes: [Int: Note] = [:]
    @ObservationIgnored private var unsavedComments: [Int: Comment] = [:]
    // The author IDs that were asked for since launch and that the server did not name.
    @ObservationIgnored private var askedAuthors: Set<String> = []
    // Called when the server no longer takes this device's token.
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    @ObservationIgnored private var wantsSync = false
    // Whether this sync has already let the changes go that waited for a server update.
    @ObservationIgnored private var hasReleased = false
    // Set when the pairing this store belongs to has ended. It then starts no request and
    // writes nothing to disk.
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var hasReportedStorage = false
    @ObservationIgnored private var hasLoadedTrash = false
    @ObservationIgnored private var hasLoadedCompleted = false
    // Every project ID this device knows, the deleted ones included. An ID is never used twice.
    @ObservationIgnored private var usedProjectIDs: Set<String> = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var wakeUp: Task<Void, Never>?
    @ObservationIgnored private var wakeAt: Date?
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let disk: LocalStore
    @ObservationIgnored private let attachments = AttachmentFiles()
    // One request per file, however many views ask for it.
    @ObservationIgnored private var fileDownloads: [String: Task<URL?, Never>] = [:]

    init(api: APIClient, disk: LocalStore) {
        self.api = api
        self.disk = disk
        settings = Self.keptSettings[api.baseURL.absoluteString].flatMap {
            try? JSONDecoder().decode(ServerSettings.self, from: $0)
        }
        let snapshot = disk.load()
        items = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        projectsByID = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        notesByID = Dictionary(snapshot.notes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        commentsByID = Dictionary(snapshot.comments.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        authors = Self.keptAuthors[api.baseURL.absoluteString].flatMap {
            try? JSONDecoder().decode([String: Author].self, from: $0)
        } ?? [:]
        outbox = snapshot.outbox
        cursor = snapshot.cursor
        // What the server was when it last refused a change, until it answers again.
        serverVersion = outbox.compactMap(\.heldFor).last.flatMap(ServerVersion.init)
        // Rows without a cursor: the store asked for every row again, and what it has is shown
        // until they arrive.
        hasLoaded = snapshot.cursor > 0 || !snapshot.items.isEmpty || !snapshot.projects.isEmpty
            || !snapshot.notes.isEmpty
        if !disk.isDurable { reportStorageProblem() }
        // After the load, which took over the photos an older build left waiting.
        AttachmentFiles.removeOldImageFolders(keepingWaiting: snapshot.keepsOldImages)
        attachments.discardWaiting(except: outbox.compactMap { entry in
            if case .addFile(_, let file) = entry.write { file } else { nil }
        })
        publish()
    }

    // MARK: Sync

    // Sends the waiting changes, then loads what changed on the server. A call that arrives
    // while a sync runs asks for one more pass and waits for it.
    func sync() async {
        guard !isClosed else { return }
        refreshToday()
        wantsSync = true
        if let running {
            await running.value
            return
        }
        let task = Task {
            hasReleased = false
            while wantsSync {
                wantsSync = false
                await pass()
            }
            // Cleared here, in the same step as the last check, so no request falls between.
            running = nil
        }
        running = task
        await task.value
    }

    func refreshToday() {
        let now = Day(.now)
        if now != today {
            today = now
            publish()
        }
    }

    private func pass() async {
        phase = .syncing
        do {
            try await flush()
            try await pull()
            hasLoaded = true
            phase = .idle
        } catch {
            save()
            phase = .failed(error.localizedDescription)
            if case APIError.status(401, _) = error, let onUnauthorized {
                // The device was revoked. Nothing is sent until it is paired again.
                if !isClosed { onUnauthorized() }
            } else if !outbox.isEmpty, !isClosed {
                // Waiting changes are tried again without the person having to do anything.
                wake(after: 20)
            }
        }
        publish()
    }

    private func pull() async throws {
        var hasMore = true
        while hasMore, !isClosed {
            let (page, version) = try await api.changes(after: cursor)
            // The pairing ended while the request was on its way.
            if isClosed { return }
            observe(version)
            if page.reset {
                // The server came back from an older backup. Start over from its state.
                isCurrent = false
                items.removeAll()
                projectsByID.removeAll()
                notesByID.removeAll()
                commentsByID.removeAll()
                // An agent may have another name on the restored server.
                authors = [:]
                askedAuthors.removeAll()
                Self.keptAuthors[api.baseURL.absoluteString] = nil
                unsavedItems.removeAll()
                unsavedProjects.removeAll()
                unsavedNotes.removeAll()
                unsavedComments.removeAll()
                disk.dropRows()
                // The copies are named by their content, so they would stay right. They go
                // anyway: the restored server may no longer hold these files at all.
                attachments.emptyCache()
            }
            if let settings = page.settings { keep(settings) }
            for change in page.changes {
                switch change {
                case .item(let item): merge(item)
                case .project(let project): merge(project)
                case .note(let note): merge(note)
                case .comment(let comment): merge(comment)
                case .other: continue
                }
            }
            cursor = page.cursor
            hasMore = page.hasMore
            save()
        }
        if !isClosed { isCurrent = true }
        await learnAuthors()
    }

    // The names of the authors of the comments here, asked for once per launch for an ID this
    // device does not know yet, until the server has answered. A comment without a known name
    // shows its author's ID.
    private func learnAuthors() async {
        let unknown = Set(commentsByID.values.map(\.authorId))
            .subtracting(authors.keys).subtracting(askedAuthors)
        guard !unknown.isEmpty, !isClosed else { return }
        // Without an answer the next sync asks again.
        guard let named = try? await api.authors(), !isClosed else { return }
        askedAuthors.formUnion(unknown)
        var known = authors
        for author in named {
            known[author.id] = author
        }
        authors = known
        Self.keptAuthors[api.baseURL.absoluteString] = try? JSONEncoder().encode(known)
    }

    private static var keptAuthors: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: "commentAuthors") as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "commentAuthors") }
    }

    // A server that is new enough now gets the changes that waited for its update, in the
    // order they were made. They go in one more pass of this sync, since the outbox was sent
    // before the pull. Once per sync: a server that refuses them again keeps them waiting.
    private func observe(_ version: ServerVersion) {
        if serverVersion != version { serverVersion = version }
        guard version >= .minimum, !hasReleased, outbox.contains(where: { $0.heldFor != nil }) else { return }
        for index in outbox.indices where outbox[index].heldFor != nil {
            outbox[index].heldFor = nil
            disk.put(outbox[index])
        }
        // On disk with the page, in `save`.
        hasReleased = true
        wantsSync = true
    }

    // An answer can arrive after a sync has already brought a newer state of the same row, so
    // a row only replaces one with a lower sequence number.
    private func merge(_ item: Item) {
        if let known = items[item.id], known.seq > item.seq { return }
        // The copy of a file the item no longer has is not kept.
        for file in items[item.id]?.files ?? [] where !item.files.contains(where: { $0.sha256 == file.sha256 }) {
            attachments.forget(file)
        }
        items[item.id] = item
        unsavedItems[item.id] = item
    }

    private func merge(_ project: Project) {
        if let known = projectsByID[project.id], known.seq > project.seq { return }
        projectsByID[project.id] = project
        unsavedProjects[project.id] = project
    }

    private func merge(_ note: Note) {
        if let known = notesByID[note.id], known.seq > note.seq { return }
        notesByID[note.id] = note
        unsavedNotes[note.id] = note
    }

    private func merge(_ comment: Comment) {
        if let known = commentsByID[comment.id], known.seq > comment.seq { return }
        commentsByID[comment.id] = comment
        unsavedComments[comment.id] = comment
    }

    // Rows, cursor and outbox changes reach the disk in one step. False when they did not.
    @discardableResult
    private func save() -> Bool {
        disk.put(
            items: Array(unsavedItems.values), projects: Array(unsavedProjects.values),
            notes: Array(unsavedNotes.values), comments: Array(unsavedComments.values), cursor: cursor,
        )
        let isSaved = disk.commit()
        if !isSaved { reportStorageProblem() }
        unsavedItems.removeAll()
        unsavedProjects.removeAll()
        unsavedNotes.removeAll()
        unsavedComments.removeAll()
        return isSaved
    }

    // The pairing ended. What is stored stays, for the day the device is paired again.
    func close() {
        isClosed = true
        wantsSync = false
        wakeUp?.cancel()
        disk.close()
    }

    // This device was unpaired. Nothing more is sent, and nothing of the data stays on it.
    func erase() {
        isClosed = true
        wantsSync = false
        wakeUp?.cancel()
        outbox.removeAll()
        disk.erase()
        attachments.erase()
        Self.keptSettings[api.baseURL.absoluteString] = nil
        Self.keptAuthors[api.baseURL.absoluteString] = nil
    }

    // MARK: Settings

    // The settings of every server this device knows, by its address.
    private static var keptSettings: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: "serverSettings") as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "serverSettings") }
    }

    // Settings the server confirmed: from the changes feed, or from the answer to a change made
    // in Settings.
    func keep(_ confirmed: ServerSettings) {
        guard !isClosed, confirmed != settings else { return }
        settings = confirmed
        Self.keptSettings[api.baseURL.absoluteString] = try? JSONEncoder().encode(confirmed)
    }

    // Said once: from here on a change only lasts as long as the app stays open.
    private func reportStorageProblem() {
        guard !hasReportedStorage else { return }
        hasReportedStorage = true
        rejection = "Pendenz cannot write to its storage on this device. Changes are sent to the server while the app stays open, and are lost if it closes before that."
    }

    // MARK: Outbox

    // Sends the waiting changes in the order they were made. Throws when the server cannot be
    // reached; the changes then stay where they are.
    private func flush() async throws {
        var rebases = 0
        while !isClosed, let entry = nextEntry() {
            let wait = entry.sendAfter.timeIntervalSinceNow
            if wait > 0 {
                wake(after: wait)
                return
            }
            inFlightKey = entry.key
            defer { inFlightKey = nil }
            do {
                switch entry.write {
                case .create(let localID, let item):
                    let created = try await api.create(item, key: entry.key)
                    merge(created)
                    rename(localID, to: created.id)
                case .update(let id, let patch):
                    // Below zero: the item was added here and its create was refused.
                    if id > 0 {
                        let known = if let item = items[id] { item } else { try await fetch(id) }
                        try await merge(api.update(id, patch: patch, version: known.version, key: entry.key))
                    }
                case .createNote(let localID, let note):
                    let created = try await api.create(note, key: entry.key)
                    merge(created)
                    renameNote(localID, to: created.id)
                case .updateNote(let id, let patch):
                    if id > 0 {
                        let known = if let note = notesByID[id] { note } else { try await fetchNote(id) }
                        try await merge(api.update(note: id, patch: patch, version: known.version, key: entry.key))
                    }
                case .createProject(let project):
                    try await merge(api.create(project, key: entry.key))
                case .updateProject(let id, let patch):
                    try await merge(api.update(project: id, patch: patch, key: entry.key))
                case .deleteProject(let id):
                    // Its items and notes follow in the changes feed, each without the project.
                    try await merge(api.delete(project: id, key: entry.key))
                case .addFile(let id, var file):
                    // Below zero: the item was added here and its create was refused.
                    if id > 0 {
                        let source = attachments.waitingFile(file)
                        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                            // Without its bytes the entry can never be sent. It must not hold
                            // back the changes behind it.
                            finish(entry)
                            if !file.isUnwanted {
                                rejection = "“\(file.name)” could not be sent, because it is gone from this device. Add it again."
                            }
                            continue
                        }
                        if !file.isSent {
                            // On disk before the request leaves. An answer that gets lost, or
                            // an app that is ended, leaves the server holding a file this
                            // device has no ID for; the mark says that removing it then needs
                            // the server.
                            file.isSent = true
                            if let index = outbox.firstIndex(where: { $0.key == entry.key }) {
                                outbox[index].write = .addFile(itemID: id, file: file)
                                disk.put(outbox[index])
                                if !disk.commit() { reportStorageProblem() }
                            }
                        }
                        let item = try await api.addFile(source, file, to: id, key: entry.key)
                        if isClosed { return }
                        merge(item)
                        // The file this upload became, by the ID it was sent with. Never by its
                        // hash: the same bytes can be on the item twice, and the removal below
                        // must not take the other one.
                        let stored = item.files.last { $0.uploadId == file.id }
                        if isUnwanted(entry) {
                            // Removed here while the server may already have had it. Now it has
                            // an ID there, and the removal takes the upload's place in the same
                            // step: before later changes to the item, since a file of a trashed
                            // item cannot be removed, and with no moment in between where
                            // neither is queued.
                            finish(entry, replacingWith: stored.map { .removeFile(itemID: id, fileID: $0.id) })
                            rebases = 0
                            continue
                        }
                        // The same bytes the server now holds: kept as its copy, so the file is
                        // not fetched again right after it was sent.
                        if let stored { attachments.adopt(file, as: stored) }
                    }
                case .removeFile(let id, let fileID):
                    if id > 0 {
                        try await merge(api.removeFile(fileID, from: id, key: entry.key))
                    }
                case .updateComment(let id, let commentID, let patch):
                    let known = if let comment = commentsByID[commentID] {
                        comment
                    } else {
                        try await fetchComments(of: id).first { $0.id == commentID }
                    }
                    // Gone on the server: there is nothing to change.
                    if let known, !known.deleted {
                        try await merge(api.update(
                            comment: commentID, of: id, patch: patch, version: known.version, key: entry.key,
                        ))
                    }
                case .deleteComment(let id, let commentID):
                    try await merge(api.delete(comment: commentID, of: id, key: entry.key))
                }
                finish(entry)
                rebases = 0
            } catch APIError.outdated(let version, _) {
                // The server is older than this build needs, and most likely does not know the
                // route or a field yet. The change waits for its update; it is not refused.
                hold(entry, for: version)
                rebases = 0
            } catch APIError.status(409, let message?) {
                // The row changed elsewhere. Read it again and send the change on top of it.
                // The request differs then, so it needs a new key.
                // Still changing after three tries: the change stays queued for the next sync.
                guard rebases < 3 else { throw APIError.status(409, message) }
                switch entry.write {
                case .update(let id, _):
                    rebases += 1
                    items[id] = nil
                    _ = try await fetch(id)
                    rekey(entry)
                case .updateNote(let id, _):
                    rebases += 1
                    // The server's row replaces the one here whatever its sequence number:
                    // after a restore from a backup it can be the lower one.
                    let note = try await api.note(id)
                    notesByID[id] = note
                    unsavedNotes[id] = note
                    rekey(entry)
                case .updateComment(let id, let commentID, _):
                    rebases += 1
                    // Missing from the answer: deleted meanwhile. The next try finds it gone.
                    let current = try await fetchComments(of: id)
                    if !current.contains(where: { $0.id == commentID }) { forgetComment(commentID) }
                    rekey(entry)
                case .create, .createNote, .createProject, .updateProject, .deleteProject, .addFile, .removeFile,
                     .deleteComment:
                    finish(entry)
                }
            } catch APIError.status(404, _?) {
                // The row is gone, or hidden from this token. There is nothing to change.
                if case .deleteComment(_, let commentID) = entry.write { forgetComment(commentID) }
                finish(entry)
            } catch APIError.status(let code, let message?) where (400 ..< 500).contains(code) && code != 401 {
                // Refused for good. An answer without the API's own message did not come from
                // the API (a proxy in between, a wrong address), and one with 401 means this
                // device is no longer paired: the change then stays where it is.
                if case .createProject(let project) = entry.write { detach(project.id) }
                // Nobody waits for a file that was removed again.
                let isSilent = isUnwanted(entry)
                finish(entry)
                if !isSilent { rejection = Self.describe(entry, reason: message) }
            }
        }
    }

    // The first waiting change that may go now. A change that waits for a server update holds
    // back every later one that depends on it: one to the same item or note, one that files a
    // new item or note into a project whose change waits, and any change to a project, since
    // their names are unique across projects. The others go on.
    private func nextEntry() -> PendingEntry? {
        let waiting = waitingForUpdate()
        return outbox.first { !waiting.contains($0.key) }
    }

    // The keys of the changes that wait for a server update, held back ones included.
    private func waitingForUpdate() -> Set<String> {
        var keys: Set<String> = []
        var items: Set<Int> = []
        var notes: Set<Int> = []
        var projects: Set<String> = []
        for entry in outbox {
            let rows = entry.write.rows
            let isWaiting = entry.heldFor != nil
                || !items.isDisjoint(with: rows.items)
                || !notes.isDisjoint(with: rows.notes)
                || (rows.project != nil && !projects.isEmpty)
                || rows.filedInto.map(projects.contains) == true
            guard isWaiting else { continue }
            keys.insert(entry.key)
            items.formUnion(rows.items)
            notes.formUnion(rows.notes)
            if let project = rows.project { projects.insert(project) }
        }
        return keys
    }

    private func hold(_ entry: PendingEntry, for version: ServerVersion) {
        guard let index = outbox.firstIndex(where: { $0.key == entry.key }) else { return }
        // The same key: if the server took it after all, a retry gets the same answer.
        outbox[index].heldFor = version.description
        disk.put(outbox[index])
        if !disk.commit() { reportStorageProblem() }
        serverVersion = version
        publish()
    }

    // The server refused a new project. What was queued for it must not reach another project
    // that happens to have its ID: the items and notes go to the inbox, and edits to the
    // project and its deletion are dropped.
    private func detach(_ projectID: String) {
        var dropped: [String] = []
        for index in outbox.indices {
            switch outbox[index].write {
            case .create(let localID, var item) where item.projectId == projectID:
                item.projectId = nil
                outbox[index].write = .create(localID: localID, item: item)
            case .update(let id, var patch) where patch.projectId == .set(projectID):
                patch.projectId = .clear
                outbox[index].write = .update(itemID: id, patch: patch)
            case .createNote(let localID, var note) where note.projectId == projectID:
                note.projectId = nil
                outbox[index].write = .createNote(localID: localID, note: note)
            case .updateNote(let id, var patch) where patch.projectId == .set(projectID):
                patch.projectId = .clear
                outbox[index].write = .updateNote(noteID: id, patch: patch)
            case .updateProject(projectID, _), .deleteProject(projectID):
                dropped.append(outbox[index].key)
                continue
            default:
                continue
            }
            disk.put(outbox[index])
        }
        outbox.removeAll { dropped.contains($0.key) }
        for key in dropped { disk.remove(key: key) }
    }

    private func fetch(_ id: Int) async throws -> Item {
        let item = try await api.item(id)
        merge(item)
        return item
    }

    // A comment the server no longer has. Gone from the disk with the next save, and kept in
    // memory as deleted, so an older answer cannot bring it back.
    private func forgetComment(_ id: Int) {
        guard var comment = commentsByID[id], !comment.deleted else { return }
        comment.deleted = true
        commentsByID[id] = comment
        unsavedComments[id] = comment
    }

    // The server's comments of an item replace the ones here, whatever their sequence numbers.
    private func fetchComments(of id: Int) async throws -> [Comment] {
        let current = try await api.comments(of: id)
        for comment in current {
            commentsByID[comment.id] = comment
            unsavedComments[comment.id] = comment
        }
        return current
    }

    private func fetchNote(_ id: Int) async throws -> Note {
        let note = try await api.note(id)
        merge(note)
        return note
    }

    // Whether a waiting file was removed here after its upload had started. Read from the
    // outbox, not from the entry a request was made with: the removal can come in between.
    private func isUnwanted(_ entry: PendingEntry) -> Bool {
        if case .addFile(_, let file) = outbox.first(where: { $0.key == entry.key })?.write { file.isUnwanted }
        else { false }
    }

    private func finish(_ entry: PendingEntry, replacingWith next: PendingWrite? = nil) {
        if let next, let index = outbox.firstIndex(where: { $0.key == entry.key }) {
            let replacement = PendingEntry(key: UUID().uuidString, order: entry.order, sendAfter: .now, write: next)
            outbox[index] = replacement
            disk.put(replacement)
        } else {
            outbox.removeAll { $0.key == entry.key }
        }
        disk.remove(key: entry.key)
        let isSaved = save()
        // A waiting file goes only once its entry is gone from the disk. An entry that came back
        // after a restart would otherwise find no file.
        if isSaved, case .addFile(_, let file) = entry.write { attachments.discard(file) }
        // The screens follow each confirmed change, not only the end of the sync.
        publish()
    }

    // The row read again goes to the disk with the new key: a retry after a restart sends that
    // key with the version it was made for. With the old row the request would differ, and the
    // server would refuse the key.
    private func rekey(_ entry: PendingEntry) {
        guard let index = outbox.firstIndex(where: { $0.key == entry.key }) else { return }
        disk.remove(key: entry.key)
        outbox[index].key = UUID().uuidString
        disk.put(outbox[index])
        save()
    }

    // The server gave a new item its ID. Later changes to it were queued under the local one.
    private func rename(_ localID: Int, to id: Int) {
        serverIDs[localID] = id
        for index in outbox.indices {
            switch outbox[index].write {
            case .update(localID, let patch): outbox[index].write = .update(itemID: id, patch: patch)
            case .addFile(localID, let file): outbox[index].write = .addFile(itemID: id, file: file)
            case .removeFile(localID, let fileID): outbox[index].write = .removeFile(itemID: id, fileID: fileID)
            default: continue
            }
            disk.put(outbox[index])
        }
        if let until = lingering.removeValue(forKey: localID) {
            lingering[id] = until
        }
    }

    private func renameNote(_ localID: Int, to id: Int) {
        noteServerIDs[localID] = id
        for index in outbox.indices {
            if case .updateNote(localID, let patch) = outbox[index].write {
                outbox[index].write = .updateNote(noteID: id, patch: patch)
                disk.put(outbox[index])
            }
        }
    }

    private func enqueue(_ write: PendingWrite, sendAfter: Date = .now) {
        let entry = PendingEntry(
            key: UUID().uuidString, order: (outbox.last?.order ?? 0) + 1, sendAfter: sendAfter, write: write,
        )
        outbox.append(entry)
        disk.put(entry)
        if !disk.commit() { reportStorageProblem() }
        publish()
        Task { await sync() }
    }

    // One timer for the next moment the outbox needs attention. The earliest request wins.
    private func wake(after seconds: TimeInterval) {
        let at = Date.now.addingTimeInterval(seconds)
        if let wakeAt, wakeAt <= at, wakeAt > .now { return }
        wakeAt = at
        wakeUp?.cancel()
        wakeUp = Task {
            try? await Task.sleep(for: .seconds(max(seconds, 0)))
            guard !Task.isCancelled else { return }
            wakeAt = nil
            await sync()
        }
    }

    private static func describe(_ entry: PendingEntry, reason: String) -> String {
        switch entry.write {
        case .create(_, let item): "“\(item.title)” was not saved. \(reason)"
        case .update: "A change was not saved. \(reason)"
        case .createNote(_, let note): "The note “\(Note.title(of: note.body))” was not saved. \(reason)"
        case .updateNote: "A change to a note was not saved. \(reason)"
        case .createProject(let project):
            "The project “\(project.name)” was not saved. \(reason) What was filed into it is in the inbox."
        case .updateProject: "A change to a project was not saved. \(reason)"
        case .deleteProject: "A project was not deleted. \(reason)"
        case .addFile(_, let file) where file.width != nil: "An image was not saved. \(reason)"
        case .addFile(_, let file): "“\(file.name)” was not saved. \(reason)"
        case .removeFile: "A file was not removed. \(reason)"
        case .updateComment: "A change to a comment was not saved. \(reason)"
        case .deleteComment: "A comment was not deleted. \(reason)"
        }
    }

    // Said at the top of the app and in Settings while the server is older than this build needs.
    var outdatedServerNotice: String? {
        guard let serverVersion, serverVersion < .minimum else { return nil }
        let waiting = switch heldCount {
        case 0: "Some changes cannot be saved until it is updated."
        case 1: "1 change waits until it is updated."
        default: "\(heldCount) changes wait until it is updated."
        }
        return "Your server runs \(serverVersion). This version of the app needs \(ServerVersion.minimum) or newer. \(waiting)"
    }

    // MARK: Changes made on this device

    // Shows the item at once and sends it when the server can be reached. Returns the ID it
    // has until the server gives it one.
    @discardableResult
    func add(_ item: NewItem) -> Int {
        var item = item
        // On top of its list, at a position that is fixed now and sent along. The server's own
        // choice could differ from what the list already shows.
        if item.position == nil {
            item.position = min((visible.values.map(\.position).max() ?? 0) + 1, Self.positionLimit)
        }
        let waiting = outbox.compactMap { entry -> Int? in
            if case .create(let id, _) = entry.write { id } else { nil }
        }
        let id = Self.localID(below: waiting + Array(serverIDs.keys))
        enqueue(.create(localID: id, item: item))
        return id
    }

    // A local ID that was not used since launch. One that the server has already answered
    // still leads to that row, so it cannot name a new one.
    private static func localID(below used: [Int]) -> Int {
        min(used.min() ?? 0, 0) - 1
    }

    // The item behind an ID, also under the local ID it had before the server answered.
    func item(_ id: Int) -> Item? {
        visible[serverIDs[id] ?? id]
    }

    // An edit from the detail. It shows at once and travels through the outbox. Edits made in
    // a row to the same item are sent as one request.
    func update(_ id: Int, _ patch: ItemPatch) {
        guard !patch.isEmpty else { return }
        let id = serverIDs[id] ?? id
        if let last = outbox.indices.last, outbox[last].key != inFlightKey,
           case .update(id, var waiting) = outbox[last].write,
           waiting.status == nil, patch.status == nil
        {
            waiting.merge(patch)
            // The request changes, so it needs a new key: the old one may already have reached
            // the server in an attempt whose answer was lost, and a key cannot be used twice
            // for different requests.
            disk.remove(key: outbox[last].key)
            outbox[last].key = UUID().uuidString
            outbox[last].write = .update(itemID: id, patch: waiting)
            disk.put(outbox[last])
            if !disk.commit() { reportStorageProblem() }
            publish()
            Task { await sync() }
        } else {
            enqueue(.update(itemID: id, patch: patch))
        }
    }

    // MARK: Comments

    // The comments of an item, oldest first, also under the local ID it had before the server
    // answered.
    func comments(of id: Int) -> [Comment] {
        comments[serverIDs[id] ?? id] ?? []
    }

    // The name a comment is shown with: "You" for the owner, an agent by its name.
    func authorName(_ id: String) -> String {
        guard let author = authors[id] else { return id == "owner" ? "You" : id }
        return author.isOwner ? "You" : author.name
    }

    // A new text or the outdated mark. Edits made in a row to the same comment are sent as
    // one request.
    func update(_ comment: Comment, _ patch: CommentPatch) {
        if let last = outbox.indices.last, outbox[last].key != inFlightKey,
           case .updateComment(comment.itemId, comment.id, var waiting) = outbox[last].write
        {
            waiting.merge(patch)
            // A new request needs a new key, as for an item.
            disk.remove(key: outbox[last].key)
            outbox[last].key = UUID().uuidString
            outbox[last].write = .updateComment(itemID: comment.itemId, commentID: comment.id, patch: waiting)
            disk.put(outbox[last])
            if !disk.commit() { reportStorageProblem() }
            publish()
            Task { await sync() }
        } else {
            enqueue(.updateComment(itemID: comment.itemId, commentID: comment.id, patch: patch))
        }
    }

    func delete(_ comment: Comment) {
        enqueue(.deleteComment(itemID: comment.itemId, commentID: comment.id))
    }

    // Completes an item. It stays in its list for a moment, and a second tap in that time
    // takes the completion back before it was ever sent.
    func toggleDone(_ item: Item) {
        var item = item
        item.id = serverIDs[item.id] ?? item.id
        let waiting = outbox.lastIndex { entry in
            if case .update(item.id, let patch) = entry.write { patch.status == .done } else { false }
        }
        if let waiting, outbox[waiting].key != inFlightKey {
            let key = outbox[waiting].key
            outbox.remove(at: waiting)
            disk.remove(key: key)
            disk.commit()
            lingering[item.id] = nil
            publish()
        } else if item.status == .done {
            // Already on its way to the server: send the opposite after it.
            enqueue(.update(itemID: item.id, patch: ItemPatch(status: .todo)))
        } else {
            let until = Date.now.addingTimeInterval(Self.lingerTime)
            lingering[item.id] = until
            completions += 1
            enqueue(.update(itemID: item.id, patch: ItemPatch(status: .done)), sendAfter: until)
            // The row leaves its list when the moment is over, whether or not the server answers.
            Task {
                try? await Task.sleep(for: .seconds(Self.lingerTime + 0.05))
                publish()
            }
        }
    }

    // Completes an item from its notification. Nobody is looking at the row, so there is no
    // moment in which a second tap could take it back.
    func complete(_ id: Int) {
        guard let item = item(id), item.isOpen else { return }
        enqueue(.update(itemID: item.id, patch: ItemPatch(status: .done)))
    }

    // Moves the reminder of an item and leaves its due date alone.
    func remind(_ id: Int, at date: Date) {
        guard let item = item(id), item.isOpen else { return }
        update(item.id, ItemPatch(remindAt: .set(date)))
    }

    // Moves an item to tomorrow from its notification, as the swipe does, and takes a reminder
    // time of its own along. Left where it was, that time would lie in the past and the item
    // would not remind again.
    func remindTomorrow(_ id: Int) {
        guard let item = item(id), item.isOpen else { return }
        // Read from the clock: after a launch in the background `today` may be a day old.
        let tomorrow = Day(.now).adding(days: 1)
        func moved(_ date: Date) -> Date {
            let clock = Day.calendar.dateComponents([.hour, .minute], from: date)
            return tomorrow.date(hour: clock.hour ?? 9, minute: clock.minute ?? 0)
        }
        var patch = ItemPatch()
        switch item.dueAt {
        case .time(let time): patch.dueAt = .set(.time(moved(time)))
        case .day: patch.dueAt = .set(.day(tomorrow))
        // A reminder without a due date stays one.
        case nil: break
        }
        if patch.dueAt != nil { patch.dueTz = TimeZone.current.identifier }
        if let remindAt = item.remindAt { patch.remindAt = .set(moved(remindAt)) }
        update(item.id, patch)
    }

    // MARK: Files

    // The files of an item as its detail shows them: the server's, without those a waiting
    // change removes, then the ones that wait to be sent.
    func files(of item: Item) -> [ShownFile] {
        item.files.map(ShownFile.stored) + (waitingFiles[item.id] ?? []).map(ShownFile.waiting)
    }

    private static let fullItem = "An item can hold at most \(AttachmentFiles.perItem) attachments."

    // Adds a picture to an item from the bytes of any image: a photo, the camera, the clipboard,
    // a drop. What is queued and sent is a scaled JPEG without the original's EXIF data. Nil when
    // it was queued, otherwise what went wrong, to be said next to the attachments.
    func addImage(_ data: Data, to id: Int) async -> String? {
        guard let scaled = await Pictures.scaled(data) else { return "That is not a picture Pendenz can read." }
        // Read after the wait: the server may have answered the item's create in between.
        guard !isClosed, let item = item(id) else { return nil }
        guard files(of: item).count < AttachmentFiles.perItem else { return Self.fullItem }
        let file = PendingFile(
            id: UUID().uuidString, name: Pictures.sentName, mime: "image/jpeg", bytes: scaled.jpeg.count,
            width: scaled.width, height: scaled.height,
        )
        // The file first: an entry in the outbox must never name a file that is not there.
        guard attachments.keep(scaled.jpeg, for: file) else {
            reportStorageProblem()
            return nil
        }
        enqueue(.addFile(itemID: item.id, file: file))
        return nil
    }

    // Adds a file to an item byte for byte: one that was picked, dropped or handed over. It is
    // copied here first, so it can be sent later without a connection. Nil when it was queued,
    // otherwise what went wrong, to be said next to the files.
    func addFile(from source: URL, to id: Int) async -> String? {
        guard !isClosed else { return nil }
        // A file chosen outside the app's own folders is only readable in between.
        let isScoped = source.startAccessingSecurityScopedResource()
        defer { if isScoped { source.stopAccessingSecurityScopedResource() } }
        let name = AttachmentFiles.basename(source.lastPathComponent)
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        // A package, such as a Pages document, is a folder too.
        if values?.isDirectory == true { return "“\(name)” is a folder. Only single files can be added." }
        if let refusal = refusal(forFileOf: Self.size(of: source), named: name) { return refusal }
        guard let item = item(id) else { return nil }
        guard files(of: item).count < AttachmentFiles.perItem else { return Self.fullItem }
        var file = PendingFile(id: UUID().uuidString, name: name, mime: AttachmentFiles.mime(forName: name), bytes: 0)
        let copy = attachments.waitingFile(file)
        // The file first: an entry in the outbox must never name a file that is not there.
        guard await AttachmentFiles.copy(source, to: copy) else { return "“\(name)” could not be copied." }
        // The size of what will be sent, which is the copy.
        file.bytes = Self.size(of: copy) ?? 0
        // Read after the wait: the server may have answered the item's create in between, and
        // another file may have been added.
        guard !isClosed, let item = self.item(id) else {
            attachments.discard(file)
            return nil
        }
        if let refusal = refusal(forFileOf: file.bytes, named: name) ?? (
            files(of: item).count < AttachmentFiles.perItem ? nil : Self.fullItem
        ) {
            attachments.discard(file)
            return refusal
        }
        enqueue(.addFile(itemID: item.id, file: file))
        return nil
    }

    // Said before a file is queued that the server would refuse for its size. Without a limit
    // from the server nothing is said here, and the server decides.
    private func refusal(forFileOf bytes: Int?, named name: String) -> String? {
        guard let bytes, let settings, bytes > settings.fileLimitBytes else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "“\(name)” is \(size). A file can be at most \(settings.fileLimitMb) MB, as set in Settings."
    }

    private static func size(of file: URL) -> Int? {
        (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    func removeFile(_ file: ShownFile, from id: Int) {
        switch file {
        case .stored(let stored):
            guard let item = item(id) else { return }
            enqueue(.removeFile(itemID: item.id, fileID: stored.id))
        case .waiting(let waiting):
            guard let index = outbox.firstIndex(where: { entry in
                if case .addFile(_, let file) = entry.write { file.id == waiting.id } else { false }
            }), case .addFile(let itemID, var file) = outbox[index].write else { return }
            if file.isSent || outbox[index].key == inFlightKey {
                // A request for it has left, so the server may hold it. The entry stays and is
                // sent again with its key, which answers with the item as the first request
                // left it; the removal follows from there.
                file.isUnwanted = true
                outbox[index].write = .addFile(itemID: itemID, file: file)
                disk.put(outbox[index])
                if !disk.commit() { reportStorageProblem() }
                Task { await sync() }
            } else {
                // Never sent: the entry and its copy go.
                let key = outbox.remove(at: index).key
                disk.remove(key: key)
                if disk.commit() { attachments.discard(file) } else { reportStorageProblem() }
            }
            publish()
        }
    }

    // The bytes of a file on this device, to open or share it. A waiting file is read from its
    // own copy. One the server holds is fetched once, checked against its hash and kept.
    // Missing when it cannot be had.
    func file(_ file: ShownFile, of id: Int) async -> URL? {
        switch file {
        case .waiting(let waiting):
            let url = attachments.waitingFile(waiting)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        case .stored(let stored):
            if let url = attachments.file(of: stored) { return url }
            guard !isClosed, let itemID = item(id)?.id, itemID > 0 else { return nil }
            if let running = fileDownloads[stored.sha256] { return await running.value }
            let attachments = attachments
            let task = Task { () -> URL? in
                guard let download = try? await api.file(stored.id, of: itemID) else { return nil }
                // The pairing ended while the request was on its way: nothing is kept.
                if isClosed {
                    try? FileManager.default.removeItem(at: download)
                    return nil
                }
                let kept = await attachments.keep(download: download, as: stored)
                // Ended while the hash was read: the erase has run already, so the copy goes.
                if isClosed, let kept {
                    try? FileManager.default.removeItem(at: kept)
                    return nil
                }
                return kept
            }
            fileDownloads[stored.sha256] = task
            let url = await task.value
            fileDownloads[stored.sha256] = nil
            return url
        }
    }

    // The bytes of a file when they are on this device already, without a request.
    func localFile(_ file: ShownFile) -> URL? {
        switch file {
        case .waiting(let waiting):
            let url = attachments.waitingFile(waiting)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        case .stored(let stored):
            return attachments.file(of: stored)
        }
    }

    // A file under its own name, for the preview and for sharing.
    func namedFile(_ url: URL, _ name: String) -> URL {
        attachments.named(url, name)
    }

    // Moves an item to another day and keeps its time of day. Without a day the date goes,
    // and the repeat with it, because the server accepts no repeat without a date.
    func reschedule(_ item: Item, to day: Day?) {
        guard let day else {
            update(item.id, ItemPatch(dueAt: .clear, repeatRule: item.repeatRule == nil ? nil : .clear))
            return
        }
        var due = Due.day(day)
        if let time = item.dueAt?.time {
            let clock = Day.calendar.dateComponents([.hour, .minute], from: time)
            due = .time(day.date(hour: clock.hour ?? 9, minute: clock.minute ?? 0))
        }
        guard due != item.dueAt else { return }
        update(item.id, ItemPatch(dueAt: .set(due), dueTz: TimeZone.current.identifier))
    }

    // Marks an open item as being worked on, or takes that mark back to todo.
    func toggleDoing(_ item: Item) {
        guard item.isOpen else { return }
        update(item.id, ItemPatch(status: item.status == .doing ? .todo : .doing))
    }

    func move(_ item: Item, toProject id: String?) {
        guard item.projectId != id else { return }
        update(item.id, ItemPatch(projectId: id.map { .set($0) } ?? .clear))
    }

    // What dropping an item on a sidebar entry does.
    func drop(_ item: Item, on place: Place) {
        switch place {
        case .reminders: reschedule(item, to: today)
        case .inbox: move(item, toProject: nil)
        case .project(let id): move(item, toProject: id)
        case .notes, .completed, .trash: break
        }
    }

    // A place in a manual list between two neighbours, top to bottom. Positions fall down
    // the list, so the row above has the higher one.
    static func position(below above: Item?, above below: Item?) -> Double? {
        let position: Double? = switch (above, below) {
        case (let above?, let below?): (above.position + below.position) / 2
        case (let above?, nil): above.position - 1
        case (nil, let below?): below.position + 1
        case (nil, nil): nil
        }
        // The server accepts nothing beyond these. At the edge two rows share a position and
        // fall back to the order of their IDs.
        return position.map { min(max($0, -positionLimit), positionLimit) }
    }

    private static let positionLimit = 1e15

    // The rows of a manual list after a drag. Each moved row gets a position between its
    // new neighbours.
    func reorder(_ rows: [Item], moved: Set<Int>) {
        var rows = rows
        for index in rows.indices where moved.contains(rows[index].id) {
            let above = index > 0 ? rows[index - 1] : nil
            let below = rows[(index + 1)...].first { !moved.contains($0.id) }
            guard let position = Self.position(below: above, above: below),
                  position != rows[index].position else { continue }
            rows[index].position = position
            update(rows[index].id, ItemPatch(position: position))
        }
    }

    // A row dropped between two rows of the inbox or a project: it joins that list and takes
    // the place it was dropped on.
    func place(_ item: Item, in place: Place, below above: Item?, above below: Item?) {
        guard above?.id != item.id, below?.id != item.id else { return }
        drop(item, on: place)
        if let position = Self.position(below: above, above: below), position != item.position {
            update(item.id, ItemPatch(position: position))
        }
    }

    // Text or links dropped from another app: one item per line, in the list they were dropped
    // on, and between the rows they were dropped between.
    func addDropped(
        _ texts: [String],
        links: [URL] = [],
        in place: Place,
        below above: Item? = nil,
        above below: Item? = nil,
    ) {
        var drafts: [NewItem] = []
        for link in links where ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
            // A link cut to fit would point somewhere else.
            guard link.absoluteString.count <= 2000 else {
                rejection = "The link is too long to keep. A link can have up to 2,000 characters."
                continue
            }
            let parsed = QuickAddParser.Result(title: link.host() ?? link.absoluteString)
            var item = newItem(parsed, hidden: false, in: place)
            item.sourceUrl = link.absoluteString
            drafts.append(item)
        }
        let lines = texts.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.prefix(Self.dropLimit) {
            drafts.append(newItem(QuickAddParser.parse(line, now: .now, projects: projects), hidden: false, in: place))
        }
        // First line on top: spread between the two neighbours, or stacked above everything
        // when the drop named no place.
        let top = visible.values.map(\.position).max() ?? 0
        var upper = above
        for (index, var draft) in drafts.enumerated() {
            if let position = Self.position(below: upper, above: below) {
                draft.position = position
                upper = Item(local: draft, id: 0, position: position)
            } else {
                draft.position = min(top + Double(drafts.count - index), Self.positionLimit)
            }
            add(draft)
        }
    }

    // A dropped text with more lines than this is most likely not a list of tasks.
    private static let dropLimit = 25

    // A new item lands in the list it was added from unless its text says otherwise: today's
    // date in Reminders, the project in a project list, the inbox everywhere else.
    func newItem(_ parsed: QuickAddParser.Result, hidden: Bool, in place: Place) -> NewItem {
        var item = NewItem(
            title: parsed.title.cut(to: Item.titleLimit), projectId: parsed.projectId, dueAt: parsed.due,
            repeatRule: parsed.repeatRule, hiddenFromAgents: hidden,
        )
        switch place {
        case .reminders where item.dueAt == nil:
            item.dueAt = .day(today)
        case .project(let id) where item.projectId == nil:
            item.projectId = id
        default:
            break
        }
        if item.dueAt != nil {
            item.dueTz = TimeZone.current.identifier
        }
        return item
    }

    // MARK: Projects

    // Shows the project at once and sends it when the server can be reached. Returns its ID.
    @discardableResult
    func addProject(name: String, icon: String?) -> String {
        // Not the ID of a deleted project either: the server keeps it, so that a change another
        // device still has queued for the old project cannot reach the new one.
        let id = Project.makeID(for: name, taken: usedProjectIDs)
        enqueue(.createProject(NewProject(id: id, name: name, icon: icon)))
        return id
    }

    func updateProject(_ id: String, _ patch: ProjectPatch) {
        guard !patch.isEmpty else { return }
        enqueue(.updateProject(projectID: id, patch: patch))
    }

    // Deletes a project. Its items go to the inbox and its notes lose the project; the server
    // moves them, and the lists show it at once.
    func deleteProject(_ id: String) {
        guard project(id) != nil else { return }
        enqueue(.deleteProject(projectID: id))
    }

    func project(_ id: String) -> Project? {
        projects.first { $0.id == id }
    }

    // Names are told apart without case, as on the server.
    func isProjectNameTaken(_ name: String, except id: String?) -> Bool {
        projects.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Trash

    // Reads the trash from disk, once per launch. Memory only holds the rows that were open at
    // launch or changed since, and a row found there is at least as new as its copy on disk.
    func loadTrash() {
        guard !hasLoadedTrash, !isClosed else { return }
        hasLoadedTrash = true
        let stored = disk.trashed()
        for item in stored.items where items[item.id] == nil {
            items[item.id] = item
        }
        for note in stored.notes where notesByID[note.id] == nil {
            notesByID[note.id] = note
        }
        publish()
    }

    // Reads the finished items from disk, once per launch, as `loadTrash` reads the trash.
    func loadCompleted() {
        guard !hasLoadedCompleted, !isClosed else { return }
        hasLoadedCompleted = true
        for item in disk.completed() where items[item.id] == nil {
            items[item.id] = item
        }
        publish()
    }

    func restore(_ item: Item) {
        update(item.id, ItemPatch(trashed: false))
    }

    func restore(_ note: Note) {
        updateNote(note.id, NotePatch(trashed: false))
    }

    // MARK: Notes

    // The note behind an ID, also under the local ID it had before the server answered.
    func note(_ id: Int) -> Note? {
        visibleNotes[noteServerIDs[id] ?? id]
    }

    // The ID a note has now: the server's, once it has answered for a note written here.
    func noteID(_ id: Int) -> Int {
        noteServerIDs[id] ?? id
    }

    // Shows the note at once and sends it when the server can be reached. Returns the ID it
    // has until the server gives it one.
    func addNote(_ note: NewNote) -> Int {
        let waiting = outbox.compactMap { entry -> Int? in
            if case .createNote(let id, _) = entry.write { id } else { nil }
        }
        let id = Self.localID(below: waiting + Array(noteServerIDs.keys))
        enqueue(.createNote(localID: id, note: note))
        return id
    }

    // An edit to a note. Edits made in a row to the same note are sent as one request, which
    // is what keeps typing from becoming a request per pause.
    func updateNote(_ id: Int, _ patch: NotePatch) {
        guard !patch.isEmpty else { return }
        let id = noteServerIDs[id] ?? id
        if let last = outbox.indices.last, outbox[last].key != inFlightKey,
           case .updateNote(id, var waiting) = outbox[last].write
        {
            waiting.merge(patch)
            // A changed request needs a new key, as for items.
            disk.remove(key: outbox[last].key)
            outbox[last].key = UUID().uuidString
            outbox[last].write = .updateNote(noteID: id, patch: waiting)
            disk.put(outbox[last])
            if !disk.commit() { reportStorageProblem() }
            publish()
            Task { await sync() }
        } else {
            enqueue(.updateNote(noteID: id, patch: patch))
        }
    }

    // A note, or a piece of one, as an item: the first line is read like quick add and becomes
    // the title, the rest becomes the description. The item keeps the note's project and stays
    // hidden from the agent when the note is.
    @discardableResult
    func addItem(from text: String, of note: Note) -> Int? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }) else { return nil }
        let head = Note.title(of: Self.withoutListMark(lines[first]))
        guard !head.isEmpty else { return nil }
        let parsed = QuickAddParser.parse(head, now: .now, projects: projects)
        var item = newItem(parsed, hidden: note.hiddenFromAgents, in: note.projectId.map { .project($0) } ?? .inbox)
        var rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A first line too long for a title is kept whole in the description.
        if parsed.title.serverLength > Item.titleLimit {
            rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !rest.isEmpty {
            item.description = rest.cut(to: Item.descriptionLimit)
        }
        return add(item)
    }

    // "- Call the dentist" and "- [ ] Call the dentist" are the task without their mark.
    private static func withoutListMark(_ line: String) -> String {
        for mark in ["- [ ] ", "- [x] ", "* [ ] ", "- ", "* ", "+ "] where line.hasPrefix(mark) {
            return String(line.dropFirst(mark.count))
        }
        return line
    }

    // A locked note is found by its title alone while the lock is closed: a hit in its text
    // would tell what the text holds.
    func searchNotes(_ query: String, readsLocked: Bool) -> [Note] {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            let text = note.locked && !readsLocked ? note.title : note.body
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private static func byPinThenEdit(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        return lhs.updatedAt == rhs.updatedAt ? lhs.id > rhs.id : lhs.updatedAt > rhs.updatedAt
    }

    // MARK: What the screens see

    // The server's rows with the waiting changes laid over them.
    private func publish() {
        var view = items
        var noteView = notesByID
        var projectView = projectsByID
        var commentView = commentsByID
        // Nothing stays filed under a deleted project. The server moves the rows itself; this
        // shows it before its answer and its changes have arrived.
        func unfile(_ gone: Set<String>) {
            guard !gone.isEmpty else { return }
            for (id, item) in view where item.projectId.map(gone.contains) ?? false {
                view[id]?.projectId = nil
            }
            for (id, note) in noteView where note.projectId.map(gone.contains) ?? false {
                noteView[id]?.projectId = nil
            }
        }
        unfile(Set(projectView.values.filter(\.deleted).map(\.id)))
        // The rows a waiting change moves to the trash, by the order of that change: they are
        // the last ones moved there, whatever their sequence number says.
        var trashedHere: [Int: Int] = [:]
        var notesTrashedHere: [Int: Int] = [:]
        var waitingAttachments: [Int: [PendingFile]] = [:]
        for entry in outbox {
            switch entry.write {
            case .create(let localID, let new):
                // The position was fixed when the item was added. Entries from an older build
                // carry none and go on top.
                view[localID] = Item(local: new, id: localID, position: Self.positionLimit)
            case .update(let id, let patch):
                if var item = view[id] {
                    patch.apply(to: &item)
                    view[id] = item
                }
                if let trashed = patch.trashed { trashedHere[id] = trashed ? entry.order : nil }
            case .createNote(let localID, let new):
                noteView[localID] = Note(local: new, id: localID, updatedAt: Note.stamp(entry.sendAfter))
            case .updateNote(let id, let patch):
                if var note = noteView[id] {
                    patch.apply(to: &note)
                    // An edit made here is the latest one, so the note moves up at once.
                    note.updatedAt = max(note.updatedAt, Note.stamp(entry.sendAfter))
                    noteView[id] = note
                }
                if let trashed = patch.trashed { notesTrashedHere[id] = trashed ? entry.order : nil }
            case .createProject(let new):
                // Missing only until the server has answered.
                if projectView[new.id] == nil {
                    projectView[new.id] = Project(id: new.id, name: new.name, icon: new.icon, seq: 0)
                }
            case .updateProject(let id, let patch):
                if var project = projectView[id], !project.deleted {
                    patch.apply(to: &project)
                    projectView[id] = project
                }
            case .deleteProject(let id):
                projectView[id]?.deleted = true
                unfile([id])
            case .addFile(let id, let file):
                if !file.isUnwanted { waitingAttachments[id, default: []].append(file) }
            case .removeFile(let id, let fileID):
                view[id]?.files.removeAll { $0.id == fileID }
            case .updateComment(_, let commentID, let patch):
                if var comment = commentView[commentID] {
                    patch.apply(to: &comment)
                    commentView[commentID] = comment
                }
            case .deleteComment(_, let commentID):
                commentView[commentID]?.deleted = true
            }
        }
        let listed = noteView.values.filter { !$0.trashed }.sorted(by: Self.byPinThenEdit)
        let binned = view.values.filter(\.trashed).sorted { lhs, rhs in
            let (left, right) = (trashedHere[lhs.id] ?? 0, trashedHere[rhs.id] ?? 0)
            if left != right { return left > right }
            return lhs.seq == rhs.seq ? lhs.id > rhs.id : lhs.seq > rhs.seq
        }
        let binnedNotes = noteView.values.filter(\.trashed).sorted { lhs, rhs in
            let (left, right) = (notesTrashedHere[lhs.id] ?? 0, notesTrashedHere[rhs.id] ?? 0)
            if left != right { return left > right }
            return lhs.seq == rhs.seq ? lhs.id > rhs.id : lhs.seq > rhs.seq
        }
        // A completion that still waits for the server has no date yet and is the latest.
        let finished = view.values.filter { $0.status == .done && !$0.trashed && !$0.archived }.sorted { lhs, rhs in
            let (left, right) = (lhs.completedAt ?? "~", rhs.completedAt ?? "~")
            return left == right ? lhs.seq > rhs.seq : left > right
        }
        let now = Date.now
        lingering = lingering.filter { $0.value > now }
        let open = view.values
            .filter { $0.isOpen || lingering[$0.id] != nil }
            .sorted { $0.id < $1.id }
        let sorted = projectView.values.filter { !$0.deleted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Assigned only when different, so a sync without news redraws nothing.
        if view != visible { visible = view }
        if open != openItems { openItems = open }
        if sorted != projects { projects = sorted }
        usedProjectIDs = Set(projectView.keys)
        if noteView != visibleNotes { visibleNotes = noteView }
        if listed != notes { notes = listed }
        if finished != completedItems { completedItems = finished }
        if binned != trashedItems { trashedItems = binned }
        if binnedNotes != trashedNotes { trashedNotes = binnedNotes }
        if waitingAttachments != waitingFiles { waitingFiles = waitingAttachments }
        let shownComments = Dictionary(grouping: commentView.values.filter { !$0.deleted }, by: \.itemId)
            .mapValues { $0.sorted { $0.id < $1.id } }
        if shownComments != comments { comments = shownComments }
        if outbox.count != pendingCount { pendingCount = outbox.count }
        let held = outbox.contains(where: { $0.heldFor != nil }) ? waitingForUpdate().count : 0
        if held != heldCount { heldCount = held }
        feedWidgets()
        if !isClosed { SpotlightFeed.shared.changed(self) }
    }

    // The widgets' copy of what is open: the inbox and each project in the order this device
    // shows them in, with the waiting changes laid over the rows. Called wherever the rows or
    // one of those orders change.
    private func feedWidgets() {
        guard !isClosed else { return }
        let lists = [Place.inbox] + orderedProjects.map { Place.project($0.id) }
        var rows = lists.flatMap { sections(for: $0).flatMap(\.items) }
        // Filed under a project this device has not heard of yet.
        let listed = Set(rows.map(\.id))
        rows += openItems.filter { !listed.contains($0.id) }
        WidgetFeed.shared.put(WidgetSnapshot(
            server: api.baseURL.absoluteString,
            hasLoaded: hasLoaded,
            // Without the rows that only linger after their tick.
            items: rows.filter(\.isOpen).map { item in
                WidgetItem(
                    id: item.id, title: item.title, projectID: item.projectId, due: item.dueAt,
                    isStarted: item.status == .doing, priority: item.priority,
                )
            },
            projects: orderedProjects.map { WidgetProject(id: $0.id, name: $0.name, symbol: $0.symbol) },
        ))
    }
}

// What each list shows, worked out from the open items.
extension Store {
    func projectName(_ id: String?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    // The projects as the sidebar and the Tasks tab list them.
    var orderedProjects: [Project] {
        switch projectOrder {
        case .name:
            return projects
        case .added:
            // A project the server has not answered for yet is the newest.
            return Self.ranked(projects) { $0.createdAt ?? "~" }
        case .edited:
            // Every change gets the next number of one sequence, so the highest number among
            // a project's rows is its last change. Only the rows in memory count: the open
            // items and those touched since launch.
            var latest: [String: Int] = [:]
            for item in visible.values {
                if let id = item.projectId { latest[id] = max(latest[id] ?? 0, item.seq) }
            }
            for note in visibleNotes.values {
                if let id = note.projectId { latest[id] = max(latest[id] ?? 0, note.seq) }
            }
            return Self.ranked(projects) { $0.seq == 0 ? Int.max : max($0.seq, latest[$0.id] ?? 0) }
        }
    }

    // The highest rank first. Projects of the same rank stay in the order they came in, by name.
    private static func ranked(_ projects: [Project], by rank: (Project) -> some Comparable) -> [Project] {
        let ranks = projects.map(rank)
        let order = projects.indices.sorted { lhs, rhs in
            ranks[lhs] == ranks[rhs] ? lhs < rhs : ranks[lhs] > ranks[rhs]
        }
        return order.map { projects[$0] }
    }

    // The symbol of a list. A project shows the icon it was given.
    func symbol(for place: Place) -> String {
        if case .project(let id) = place, let project = project(id) { project.symbol } else { place.systemImage }
    }

    func title(for place: Place) -> String {
        switch place {
        case .reminders: "Reminders"
        case .inbox: "Inbox"
        case .notes: "Notes"
        case .project(let id): projectName(id) ?? "Project"
        case .completed: "Completed"
        case .trash: "Trash"
        }
    }

    // The number next to a list. Reminders counts what is due by today, not every dated item.
    func count(for place: Place) -> Int {
        switch place {
        case .reminders: openItems.count { $0.isOpen && ($0.dueAt.map { $0.day <= today } ?? false) }
        case .inbox: openItems.count { $0.isOpen && $0.projectId == nil }
        case .notes, .completed, .trash: 0
        case .project(let id): openItems.count { $0.isOpen && $0.projectId == id }
        }
    }

    func sections(for place: Place) -> [ItemSection] {
        switch place {
        case .reminders:
            // Overdue in one section, then one section per day from today on.
            let dated = openItems.filter { $0.dueAt != nil }
            let overdue = dated.filter { $0.dueAt.map { $0.day < today } ?? false }.sorted(by: Self.byDue)
            let days = Dictionary(grouping: dated.filter { $0.dueAt.map { $0.day >= today } ?? false }) {
                $0.dueAt?.day ?? today
            }
            .sorted { $0.key < $1.key }
            .map { day, items in
                ItemSection(
                    id: day.text,
                    title: DueText.heading(for: day, today: today),
                    items: items.sorted(by: Self.byDue),
                )
            }
            return (overdue.isEmpty ? [] : [ItemSection(id: Self.overdueSection, title: "Overdue", items: overdue)]) +
                days
        case .inbox:
            return Self.single(openItems.filter { $0.projectId == nil }.sorted(by: Self.sorting(itemOrder(for: place))))
        case .project(let id):
            return Self.single(openItems.filter { $0.projectId == id }.sorted(by: Self.sorting(itemOrder(for: place))))
        case .completed:
            // One section per day, the latest first. The rows arrive in that order.
            var sections: [ItemSection] = []
            for item in completedItems {
                let day = item.completedDay ?? today
                if sections.last?.id == day.text {
                    sections[sections.count - 1].items.append(item)
                } else {
                    sections.append(ItemSection(
                        id: day.text,
                        title: DueText.heading(for: day, today: today),
                        items: [item],
                    ))
                }
            }
            return sections
        case .notes, .trash:
            return []
        }
    }

    // The order of the inbox or of a project. Every other list has one order of its own.
    func itemOrder(for place: Place) -> ItemOrder {
        Self.orderKey(for: place).flatMap { itemOrders[$0] }.flatMap(ItemOrder.init(rawValue:)) ?? .manual
    }

    func setItemOrder(_ order: ItemOrder, for place: Place) {
        guard let key = Self.orderKey(for: place) else { return }
        itemOrders[key] = order == .manual ? nil : order.rawValue
    }

    // Missing for the lists that cannot be sorted.
    static func orderKey(for place: Place) -> String? {
        switch place {
        case .inbox: "inbox"
        case .project(let id): "project:\(id)"
        case .reminders, .notes, .completed, .trash: nil
        }
    }

    private static func sorting(_ order: ItemOrder) -> (Item, Item) -> Bool {
        switch order {
        case .manual:
            byPosition
        case .due:
            { lhs, rhs in
                let (left, right) = (lhs.dueAt?.sortDate ?? .distantFuture, rhs.dueAt?.sortDate ?? .distantFuture)
                return left == right ? byPosition(lhs, rhs) : left < right
            }
        case .added:
            // IDs grow with every new item. One added here has an ID below zero until the
            // server answers, and the lower of those is the newer.
            { lhs, rhs in
                if (lhs.id < 0) != (rhs.id < 0) { return lhs.id < 0 }
                return lhs.id < 0 ? lhs.id < rhs.id : lhs.id > rhs.id
            }
        case .edited:
            // An item added here has no sequence number yet and is the newest.
            { lhs, rhs in
                let (left, right) = (lhs.seq == 0 ? Int.max : lhs.seq, rhs.seq == 0 ? Int.max : rhs.seq)
                return left == right ? byPosition(lhs, rhs) : left > right
            }
        case .title:
            { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? byPosition(lhs, rhs) : order == .orderedAscending
            }
        }
    }

    func search(_ query: String) -> [Item] {
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return [] }
        let matches = openItems
            .filter { item in
                words.allSatisfy { word in
                    item.title.localizedStandardContains(word)
                        || item.description.localizedStandardContains(word)
                        || item.tags.contains { $0.localizedStandardContains(word) }
                }
            }
            .sorted(by: Self.byPosition)
        // "P-36" or "36" also finds item 36, ahead of the rows whose text holds the number.
        guard let id = Self.itemNumber(query), let item = openItems.first(where: { $0.id == id }) else {
            return matches
        }
        return [item] + matches.filter { $0.id != id }
    }

    // The item number in a query that is nothing else: "P-36", "p-36" or "36", as the agent
    // tools take it. A local ID is below zero and never matches.
    static func itemNumber(_ query: String) -> Int? {
        var text = Substring(query.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("P-") || text.hasPrefix("p-") { text = text.dropFirst(2) }
        guard let first = text.first, first != "0", text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(text)
    }

    // The one section of Reminders that mixes days, so its rows name their day.
    static let overdueSection = "overdue"

    private static func single(_ items: [Item]) -> [ItemSection] {
        items.isEmpty ? [] : [ItemSection(id: "all", title: nil, items: items)]
    }

    private static func byDue(_ lhs: Item, _ rhs: Item) -> Bool {
        let (left, right) = (lhs.dueAt?.sortDate ?? .distantFuture, rhs.dueAt?.sortDate ?? .distantFuture)
        return left == right ? lhs.id < rhs.id : left < right
    }

    // The manual order of a list: highest position first, which puts new items on top.
    private static func byPosition(_ lhs: Item, _ rhs: Item) -> Bool {
        lhs.position == rhs.position ? lhs.id > rhs.id : lhs.position > rhs.position
    }
}

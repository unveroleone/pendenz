import AppIntents
import Foundation

// The items, notes, projects and lists of Pendenz as Siri, Shortcuts and Spotlight see them.
// Each is read from the store when it is asked for, never kept: an entity is a copy of a row at
// that moment, and its ID is what an intent acts on.

// MARK: Items

nonisolated struct ItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Item", numericFormat: "\(placeholder: .int) items")
    }

    static var defaultQuery: ItemQuery { ItemQuery() }

    let id: Int
    private let itemTitle: String
    private let itemDetails: String
    private let itemDue: Date?
    private let projectName: String?
    // The due date and the project in words, as a row shows them.
    let subtitle: String

    @ComputedProperty(title: "Title")
    var title: String { itemTitle }
    @ComputedProperty(title: "Description")
    var details: String { itemDetails }
    // The start of the day for an item due on a day without a time.
    @ComputedProperty(title: "Due Date")
    var dueDate: Date? { itemDue }
    @ComputedProperty(title: "Project")
    var project: String? { projectName }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)",
            image: .init(systemName: "circle"),
        )
    }

    @MainActor
    init(_ item: Item, in store: Store) {
        id = item.id
        let project = store.projectName(item.projectId)
        let due = item.dueAt.flatMap { DueText.label(for: $0, today: store.today, showsDay: true) }
        subtitle = [due, project].compactMap(\.self).joined(separator: " · ")
        itemTitle = item.title
        itemDetails = item.description
        itemDue = item.dueAt?.sortDate
        projectName = project
    }
}

// What Shortcuts' "Find Items" can ask for. Only open items are found.
nonisolated enum ItemFilter: Sendable {
    case titleContains(String)
    case titleIs(String)
    case dueBefore(Date)
    case dueAfter(Date)
    case dueBetween(Date, Date)
    case projectIs(String?)
    case projectContains(String)

    func matches(_ item: ItemEntity) -> Bool {
        switch self {
        case .titleContains(let text): item.title.localizedStandardContains(text)
        case .titleIs(let text): item.title.localizedCaseInsensitiveCompare(text) == .orderedSame
        case .dueBefore(let date): item.dueDate.map { $0 < date } ?? false
        case .dueAfter(let date): item.dueDate.map { $0 > date } ?? false
        case .dueBetween(let start, let end): item.dueDate.map { $0 >= start && $0 <= end } ?? false
        case .projectIs(let name):
            switch (item.project, name) {
            case (nil, nil): true
            case (let project?, let name?): project.localizedCaseInsensitiveCompare(name) == .orderedSame
            default: false
            }
        case .projectContains(let text): item.project?.localizedStandardContains(text) ?? false
        }
    }
}

nonisolated struct ItemQuery: EntityPropertyQuery, EntityStringQuery {
    static var findIntentDescription: IntentDescription? {
        IntentDescription("Finds open items in Pendenz by their title, due date or project.")
    }

    static var properties: EntityQueryProperties<ItemEntity, ItemFilter> {
        EntityQueryProperties<ItemEntity, ItemFilter> {
            Property(\ItemEntity.$title) {
                ContainsComparator { ItemFilter.titleContains($0) }
                EqualToComparator { ItemFilter.titleIs($0) }
            }
            Property(\ItemEntity.$dueDate) {
                LessThanComparator { ItemFilter.dueBefore($0) }
                GreaterThanComparator { ItemFilter.dueAfter($0) }
                IsBetweenComparator { ItemFilter.dueBetween($0, $1) }
            }
            Property(\ItemEntity.$project) {
                EqualToComparator { ItemFilter.projectIs($0) }
                ContainsComparator { ItemFilter.projectContains($0) }
            }
        }
    }

    static var sortingOptions: EntityQuerySortingOptions<ItemEntity> {
        EntityQuerySortingOptions<ItemEntity> {
            SortableBy(\ItemEntity.$dueDate)
            SortableBy(\ItemEntity.$title)
        }
    }

    // Also a finished item, so a saved shortcut or a Spotlight result can still open it. An ID
    // below zero is the item's until the next launch, and the server's ID after the item has
    // reached it.
    func entities(for identifiers: [Int]) async throws -> [ItemEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run {
            if identifiers.contains(where: { store.item($0) == nil }) { store.loadCompleted() }
            return identifiers.compactMap { store.item($0) }.map { ItemEntity($0, in: store) }
        }
    }

    // What Siri and the pickers offer first: the open items, the soonest due first.
    func suggestedEntities() async throws -> [ItemEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run { Self.open(in: store).sorted(by: Self.bySoonest) }
    }

    func entities(matching string: String) async throws -> [ItemEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run {
            store.search(string).filter { $0.isOpen && $0.id > 0 }.map { ItemEntity($0, in: store) }
        }
    }

    func entities(
        matching comparators: [ItemFilter], mode: EntityQueryComparatorMode, sortedBy: [EntityQuerySort<ItemEntity>],
        limit: Int?,
    ) async throws -> [ItemEntity] {
        // Read here: a sort is not sendable, and the rows are gathered on the main actor.
        let sorts = sortedBy.compactMap { sort -> (byTitle: Bool, ascending: Bool)? in
            let ascending = sort.order == .ascending
            if sort.by == \ItemEntity.$title as PartialKeyPath<ItemEntity> { return (true, ascending) }
            if sort.by == \ItemEntity.$dueDate as PartialKeyPath<ItemEntity> { return (false, ascending) }
            return nil
        }
        let store = try await Session.freshIntentStore()
        var found = await MainActor.run { Self.open(in: store) }
        if !comparators.isEmpty {
            found = found.filter { item in
                mode == .and ? comparators.allSatisfy { $0.matches(item) } : comparators.contains { $0.matches(item) }
            }
        }
        found.sort(by: Self.bySoonest)
        // The last sort named is applied first, so the first one decides.
        for sort in sorts.reversed() {
            found = Self.stable(found) { lhs, rhs in
                if sort.byTitle {
                    let order = lhs.title.localizedStandardCompare(rhs.title)
                    return order != .orderedSame && (order == .orderedAscending) == sort.ascending
                }
                let (left, right) = (lhs.dueDate ?? .distantFuture, rhs.dueDate ?? .distantFuture)
                return left != right && (left < right) == sort.ascending
            }
        }
        if let limit { found = Array(found.prefix(limit)) }
        return found
    }

    // Without the items the server has not given a number yet: a shortcut may keep what it
    // finds, and such a number means another item after the next launch.
    @MainActor
    private static func open(in store: Store) -> [ItemEntity] {
        store.openItems.filter { $0.isOpen && $0.id > 0 }.map { ItemEntity($0, in: store) }
    }

    // Dated items first, the soonest on top, then the rest by title.
    private static func bySoonest(_ lhs: ItemEntity, _ rhs: ItemEntity) -> Bool {
        let (left, right) = (lhs.dueDate ?? .distantFuture, rhs.dueDate ?? .distantFuture)
        if left != right { return left < right }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    // A sort that keeps the order of equal rows, so an earlier sort decides among them.
    private static func stable(_ items: [ItemEntity], by before: (ItemEntity, ItemEntity) -> Bool) -> [ItemEntity] {
        items.enumerated().sorted { lhs, rhs in
            if before(lhs.element, rhs.element) { return true }
            if before(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

// MARK: Notes

// A note by its title. Its text is not offered to Shortcuts: a locked note shows it only after
// Face ID, and a shortcut must not be a way around that. Spotlight gets the text of a note
// without a lock, on this device.
nonisolated struct NoteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note", numericFormat: "\(placeholder: .int) notes")
    }

    static var defaultQuery: NoteQuery { NoteQuery() }

    let id: Int
    private let noteTitle: String
    let isLocked: Bool
    // What follows the title, for Spotlight. Empty for a locked note.
    let text: String

    @ComputedProperty(title: "Title")
    var title: String { noteTitle }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: isLocked ? "lock" : "note.text"))
    }

    @MainActor
    init(_ note: Note) {
        id = note.id
        noteTitle = note.title.isEmpty ? "New Note" : note.title
        isLocked = note.locked
        text = note.locked ? "" : Self.text(after: note.title, in: note.body)
    }

    // The body without its first line with text, cut to a length Spotlight does well with.
    private static func text(after _: String, in body: String) -> String {
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.remove(at: first)
        }
        return String(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(10000))
    }
}

nonisolated struct NoteQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [NoteEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run {
            identifiers.compactMap { store.note($0) }.filter { !$0.trashed }.map(NoteEntity.init)
        }
    }

    // Without the notes the server has not given a number yet, as for items.
    func suggestedEntities() async throws -> [NoteEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run { store.notes.filter { $0.id > 0 }.map(NoteEntity.init) }
    }

    // A locked note is found by its title alone, as in the app's search while the lock is closed.
    func entities(matching string: String) async throws -> [NoteEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run {
            store.searchNotes(string, readsLocked: false).filter { $0.id > 0 }.map(NoteEntity.init)
        }
    }
}

// MARK: Projects

nonisolated struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Project" }
    static var defaultQuery: ProjectQuery { ProjectQuery() }

    let id: String
    private let projectName: String
    let symbol: String

    @ComputedProperty(title: "Name")
    var name: String { projectName }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    @MainActor
    init(_ project: Project) {
        id = project.id
        projectName = project.name
        symbol = project.symbol
    }
}

nonisolated struct ProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run { identifiers.compactMap(store.project).map(ProjectEntity.init) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run { store.orderedProjects.map(ProjectEntity.init) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

// MARK: Lists

// A list the app can open: Reminders, the inbox, Notes, Completed, the trash or a project.
nonisolated struct ListEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "List" }
    static var defaultQuery: ListQuery { ListQuery() }

    // "reminders", "inbox", "notes", "completed", "trash" or "project:<id>".
    var id: String
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    @MainActor
    init(_ place: Place, in store: Store) {
        id = Self.id(of: place)
        name = store.title(for: place)
        symbol = store.symbol(for: place)
    }

    static func id(of place: Place) -> String {
        switch place {
        case .reminders: "reminders"
        case .inbox: "inbox"
        case .notes: "notes"
        case .completed: "completed"
        case .trash: "trash"
        case .project(let id): "project:\(id)"
        }
    }

    static func place(of id: String) -> Place? {
        switch id {
        case "reminders": .reminders
        case "inbox": .inbox
        case "notes": .notes
        case "completed": .completed
        case "trash": .trash
        default:
            id.hasPrefix("project:") && id.count > "project:".count
                ? .project(String(id.dropFirst("project:".count))) : nil
        }
    }
}

nonisolated struct ListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ListEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run {
            identifiers.compactMap(ListEntity.place).filter { place in
                if case .project(let id) = place { store.project(id) != nil } else { true }
            }.map { ListEntity($0, in: store) }
        }
    }

    // In the order of the sidebar.
    func suggestedEntities() async throws -> [ListEntity] {
        let store = try await Session.freshIntentStore()
        return await MainActor.run { Self.lists(in: store).map { ListEntity($0, in: store) } }
    }

    func entities(matching string: String) async throws -> [ListEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor
    private static func lists(in store: Store) -> [Place] {
        [.inbox, .reminders, .notes] + store.orderedProjects.map { .project($0.id) } + [.completed, .trash]
    }
}

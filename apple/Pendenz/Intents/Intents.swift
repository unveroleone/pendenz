import AppIntents
import Foundation

// The actions Pendenz offers Siri, Shortcuts, Spotlight and the Action button. They run in the
// app, which the system starts in the background where an action needs no window. Every change
// goes through the outbox like a change made on screen, so it also holds without a connection.

struct AddItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Item"
    static let description = IntentDescription(
        "Adds an item to Pendenz. A date, a repeat or a #project in the title are read as in quick add.",
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Title", requestValueDialog: "What should I add?")
    var title: String
    // Replaces a date read from the title.
    @Parameter(title: "Due Date")
    var dueDate: Date?
    @Parameter(title: "All Day", default: false)
    var isAllDay: Bool
    // Replaces a #project in the title. Without either, the item goes to the inbox.
    @Parameter(title: "Project")
    var project: ProjectEntity?
    @Parameter(title: "Hide from Agents", default: false)
    var isHidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to \(\.$project)") {
            \.$dueDate
            \.$isAllDay
            \.$isHidden
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity> & ProvidesDialog {
        // Fresh, so a #project made on another device is known.
        let store = try await Session.freshIntentStore()
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentError.emptyTitle }
        if let project, store.project(project.id) == nil { throw IntentError.missingProject }
        var parsed = QuickAddParser.parse(text, now: .now, projects: store.projects)
        // "Tomorrow" alone is a title, not an empty item due tomorrow.
        if parsed.title.isEmpty { parsed = QuickAddParser.Result(title: text) }
        var item = store.newItem(parsed, hidden: isHidden, in: .inbox)
        item.createdVia = "shortcut"
        if let project { item.projectId = project.id }
        if let dueDate {
            item.dueAt = isAllDay ? .day(Day(dueDate)) : .time(dueDate)
            item.dueTz = TimeZone.current.identifier
        }
        let id = store.add(item)
        await Session.settleIntent(store)
        // Under the server's number once it has answered. Missing only when the server refused
        // the item: the outbox then dropped it.
        guard let added = store.item(id) else { throw IntentError.rejected(store.rejection ?? "") }
        let entity = ItemEntity(added, in: store)
        return .result(value: entity, dialog: "Added \u{201C}\(entity.title)\u{201D}.")
    }
}

struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Note"
    static let description = IntentDescription("Adds a note to Pendenz. The first line is its title.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Text", inputOptions: .init(multiline: true), requestValueDialog: "What should the note say?")
    var text: String
    @Parameter(title: "Project")
    var project: ProjectEntity?
    @Parameter(title: "Hide from Agents", default: false)
    var isHidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add a note with \(\.$text) to \(\.$project)") {
            \.$isHidden
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NoteEntity> & ProvidesDialog {
        let store = try Session.intentStore()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IntentError.emptyNote }
        guard body.serverLength <= Note.bodyLimit else { throw IntentError.longNote }
        if let project, store.project(project.id) == nil { throw IntentError.missingProject }
        let id = store.addNote(NewNote(body: body, projectId: project?.id, hiddenFromAgents: isHidden))
        await Session.settleIntent(store)
        guard let added = store.note(id) else { throw IntentError.rejected(store.rejection ?? "") }
        let entity = NoteEntity(added)
        return .result(value: entity, dialog: "Added the note \u{201C}\(entity.title)\u{201D}.")
    }
}

// Shown as "Complete Item". The widget's tick has an intent of its own, `CompleteItemIntent`,
// which Shortcuts does not list.
struct CompleteItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Item"
    static let description = IntentDescription(
        "Completes an item in Pendenz. A repeating item moves on to its next date.",
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Item", requestValueDialog: "Which item?")
    var item: ItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$item)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // What this device knows may be behind: another device may have completed the item, or
        // moved a repeating one on. Completing that one again would complete its next date.
        let store = try await Session.freshIntentStore()
        guard let found = store.item(item.id), found.isOpen else { throw IntentError.missingItem }
        if found.repeatRule != nil, !Self.isSame(found.dueAt?.sortDate, item.dueDate) {
            throw IntentError.missingItem
        }
        store.complete(found.id)
        await Session.settleIntent(store)
        return .result(dialog: "Completed \u{201C}\(found.title)\u{201D}.")
    }

    // The date the entity was made with, against the item's date now, to the second.
    private static func isSame(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let left?, let right?): abs(left.timeIntervalSince(right)) < 1
        default: false
        }
    }
}

struct OpenListIntent: AppIntent {
    static let title: LocalizedStringResource = "Open List"
    static let description = IntentDescription("Opens Reminders, the inbox, Notes or a project in Pendenz.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "List", requestValueDialog: "Which list?")
    var list: ListEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await Session.freshIntentStore()
        guard let place = ListEntity.place(of: list.id) else { throw IntentError.missingProject }
        if case .project(let id) = place, store.project(id) == nil { throw IntentError.missingProject }
        OpenRequest.shared.place = place
        return .result()
    }
}

// Also what Spotlight runs when an item found there is opened.
struct OpenItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Item"
    static let description = IntentDescription("Opens an item in Pendenz.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Item")
    var target: ItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await Session.freshIntentStore()
        guard store.item(target.id) != nil else { throw IntentError.missingItem }
        OpenRequest.shared.itemID = target.id
        return .result()
    }
}

// Also what Spotlight runs when a note found there is opened. A locked note asks for Face ID
// in the app, as it does when it is opened there.
struct OpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Note"
    static let description = IntentDescription("Opens a note in Pendenz.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Note")
    var target: NoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await Session.freshIntentStore()
        guard let note = store.note(target.id), !note.trashed else { throw IntentError.missingNote }
        OpenRequest.shared.noteID = target.id
        return .result()
    }
}

// The phrases Siri knows without any setup, and the actions offered for the Action button and
// in Spotlight. Each phrase has to name the app.
struct PendenzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddItemIntent(),
            phrases: [
                "Add an item to \(.applicationName)",
                "Add to \(.applicationName)",
                "New \(.applicationName) item",
                "Remind me in \(.applicationName)",
            ],
            shortTitle: "Add Item",
            systemImageName: "plus.circle",
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: [
                "Add a note to \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil",
        )
        AppShortcut(
            intent: CompleteItemsIntent(),
            phrases: [
                "Complete an item in \(.applicationName)",
                "Tick off an item in \(.applicationName)",
            ],
            shortTitle: "Complete Item",
            systemImageName: "checkmark.circle",
        )
        AppShortcut(
            intent: OpenListIntent(),
            phrases: [
                "Open \(\.$list) in \(.applicationName)",
                "Show \(\.$list) in \(.applicationName)",
                "Open a list in \(.applicationName)",
            ],
            shortTitle: "Open List",
            systemImageName: "list.bullet",
        )
    }
}

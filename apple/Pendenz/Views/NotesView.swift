import SwiftUI

// The notes: pinned ones first, then by the last edit. On the iPhone a note opens over the
// list, on Mac and iPad next to it. The locked notes are not among them: they are in Locked
// Notes, the same view once more, which opens over this one after one question.
struct NotesView: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    // What the search field holds. Empty shows every note.
    var query = ""
    // True for Locked Notes.
    var showsLocked = false
    // The search field of Locked Notes on the iPhone, where the tab's field stays with Notes.
    @State private var lockedQuery = ""
    private var lock: NoteLock { .shared }

    // The editor of the iPhone opens over the list it was opened from. Both lists watch the
    // same note, so each one only while the window is on it.
    private var isEditing: Binding<Bool> {
        Binding {
            (navigation.noteID != nil || navigation.isWritingNote) && navigation.isInLockedNotes == showsLocked
        } set: { isShown in
            if !isShown, navigation.isInLockedNotes == showsLocked {
                navigation.noteID = nil
                navigation.isWritingNote = false
            }
        }
    }

    private var isInLockedNotes: Binding<Bool> {
        Binding {
            navigation.isInLockedNotes
        } set: { isShown in
            if !isShown, navigation.isInLockedNotes { navigation.leaveLockedNotes() }
        }
    }

    private var isPhone: Bool {
        sizeClass == .compact
    }

    private var searchText: String {
        showsLocked && isPhone ? lockedQuery : query
    }

    // The row that leads to Locked Notes, while there is a locked note and no search.
    private var showsLockedRow: Bool {
        !showsLocked && query.trimmingCharacters(in: .whitespaces).isEmpty && store.notes.contains(where: \.locked)
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                list
                    .navigationDestination(isPresented: isEditing) {
                        NoteEditorView(showsTitle: true)
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                    }
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        list
                            // A good third for the list, within what a row needs and what
                            // would take room from the text.
                            .frame(width: min(300, max(220, proxy.size.width * 0.38)))
                        Divider()
                        if isEditing.wrappedValue {
                            NoteEditorView(showsTitle: false)
                        } else {
                            ContentUnavailableView(
                                "No note selected",
                                systemImage: Place.notes.systemImage,
                                // A new note is written in Notes.
                                description: Text(showsLocked ? "Choose a note." :
                                    "Choose a note, or write a new one."),
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .navigationTitle(showsLocked ? "Locked Notes" : "Notes")
        .toolbar {
            // A new note is not locked, so it is written in Notes.
            if !showsLocked {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Note", systemImage: "square.and.pencil", action: write)
                }
            }
            SyncStatus()
        }
        .modifier(LockedSearch(isOn: showsLocked && isPhone, text: $lockedQuery))
        .modifier(LockedNotesDestination(isOn: !showsLocked, isPresented: isInLockedNotes, query: query))
    }

    // Locked Notes shows nothing while the lock is closed, whatever the navigation does in
    // the same moment. Notes never lists a locked note, also while the lock is open.
    private var notes: [Note] {
        if showsLocked, !lock.isOpen { return [] }
        return store.searchNotes(searchText, readsLocked: showsLocked).filter { $0.locked == showsLocked }
    }

    private var list: some View {
        let notes = notes
        return rows(notes)
            .listStyle(.plain)
            .animation(.default, value: notes.map(\.id))
            .overlay {
                if notes.isEmpty, !showsLockedRow { emptyState }
            }
            .refreshable { await store.sync() }
    }

    @ViewBuilder
    private func rows(_ notes: [Note]) -> some View {
        @Bindable var navigation = navigation
        if sizeClass == .compact {
            // A row is a button here, so none stays highlighted after its note was closed.
            List {
                if showsLockedRow { lockedRow }
                ForEach(notes) { note in
                    Button {
                        navigation.noteID = note.id
                    } label: {
                        NoteRow(note: note, showsLockedPreview: showsLocked)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the note")
                    .modifier(NoteActions(note: note))
                }
            }
        } else {
            List(selection: $navigation.noteID) {
                if showsLockedRow { lockedRow }
                ForEach(notes) { note in
                    NoteRow(note: note, showsLockedPreview: showsLocked)
                        .tag(note.id)
                        .modifier(NoteActions(note: note))
                }
            }
            #if os(macOS)
            // The Delete key, only while the list itself has the focus.
            .onDeleteCommand {
                if let id = navigation.noteID { store.updateNote(id, NotePatch(trashed: true)) }
            }
            #endif
        }
    }

    // First in the list, above the pinned notes.
    private var lockedRow: some View {
        Section {
            Button {
                Task { await navigation.openLockedNotes() }
            } label: {
                HStack {
                    Label("Locked Notes", systemImage: "lock")
                    Spacer()
                    #if os(iOS)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    #endif
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(lock.isAsking)
            .accessibilityHint("Asks for \(NoteLock.method), then shows the locked notes")
            if let failure = lock.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search
        } else if showsLocked {
            ContentUnavailableView {
                Label("No locked notes", systemImage: "lock")
            } description: {
                Text("A note locked from its menu is kept here.")
            }
        } else if store.hasLoaded {
            ContentUnavailableView {
                Label("No notes yet", systemImage: Place.notes.systemImage)
            } description: {
                Text("A note holds what is not a task yet.")
            } actions: {
                Button("New Note", action: write)
            }
        } else if case .failed(let message) = store.phase {
            ContentUnavailableView {
                Label("Cannot reach the server", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await store.sync() }
                }
            }
        } else {
            ProgressView()
        }
    }

    private func write() {
        navigation.writeNote()
    }
}

// The swipes and the menu of a row in the notes list.
private struct NoteActions: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    let note: Note

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin", action: togglePin)
                    .tint(Color(.selection))
            }
            .swipeActions(edge: .trailing) {
                Button("Trash", systemImage: "trash", action: trash)
                    .tint(.red)
            }
            .contextMenu {
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin", action: togglePin)
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive, action: trash)
            }
    }

    // Nothing asks first: the trash gives the note back.
    private func trash() {
        store.updateNote(note.id, NotePatch(trashed: true))
    }

    private func togglePin() {
        store.updateNote(note.id, NotePatch(pinned: !note.pinned))
    }
}

struct NoteRow: View {
    @Environment(Store.self) private var store
    let note: Note
    // True in Locked Notes, which is behind the question already. Everywhere else a locked
    // note shows its title alone.
    var showsLockedPreview = false
    private var lock: NoteLock { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                Text(note.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            // Outside Locked Notes a locked note shows its title and nothing of what follows,
            // also while the lock is open.
            if !note.locked || showsLockedPreview && lock.isOpen, !note.preview.isEmpty {
                Text(note.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                if let edited = note.edited {
                    Text(Self.label(for: edited))
                }
                // In Locked Notes every row is locked, so none says it.
                if note.locked, !showsLockedPreview {
                    Image(systemName: lock.isOpen ? "lock.open.fill" : "lock.fill")
                        .accessibilityLabel("Locked")
                }
                if note.hiddenFromAgents {
                    Image(systemName: "eye.slash")
                        .accessibilityLabel("Hidden from agent")
                }
                if let project = note.projectId.flatMap(store.project) {
                    HStack(spacing: 3) {
                        Image(systemName: project.symbol)
                        Text(project.name)
                    }
                    .layoutPriority(-1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Project \(project.name)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // The time for an edit made today, the day for an older one.
    static func label(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// The note that is open, as plain text. It is saved a moment after the typing stops, when
// another note is opened and when the editor closes.
struct NoteEditorView: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    // Over the list on the iPhone the editor names its note in the bar. Next to the list the
    // bar keeps saying "Notes".
    let showsTitle: Bool

    @State private var text = ""
    // False while the note that was asked for is not in the store yet, right after launch.
    // Its text is then not on screen, and nothing may be saved or trashed in its name.
    @State private var isLoaded = false
    @State private var selection: TextSelection?
    // The note being edited. Missing for a new note until its first character is typed.
    @State private var currentID: Int?
    // Why a note could not be locked, said in an alert.
    @State private var lockFailure: String?
    @FocusState private var isFocused: Bool
    private var lock: NoteLock { .shared }

    private static let pause: Duration = .milliseconds(1500)

    private var note: Note? {
        currentID.flatMap(store.note)
    }

    // True while the open note is locked and the lock is closed. Its text is then not on
    // screen, and nothing in the menu may act on it.
    private var isGated: Bool {
        note?.locked == true && !lock.isOpen
    }

    private var isShowingLockFailure: Binding<Bool> {
        Binding {
            lockFailure != nil
        } set: { isShown in
            if !isShown { lockFailure = nil }
        }
    }

    var body: some View {
        let note = note
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                status(note)
            }
            if isGated {
                lockedPlaceholder
            } else {
                TextEditor(text: $text, selection: $selection)
                    .disabled(!isLoaded)
                    .focused($isFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    // The editor insets its text by five points itself, and on iOS by eight
                    // from the top.
                    .padding(.horizontal, 11)
                    #if os(macOS)
                    .padding(.top, 8)
                    #endif
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty, isLoaded {
                            Text("Write a note. The first line is its title.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Note text")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("This note was not locked", isPresented: isShowingLockFailure) {
            Button("OK") {}
        } message: {
            Text(lockFailure ?? "")
        }
        .modifier(NoteTitle(title: showsTitle ? note.map(\.title) ?? "New Note" : nil))
        .toolbar { toolbar(note) }
        .onChange(of: navigation.noteID, initial: true) { _, id in open(id) }
        .onChange(of: navigation.isWritingNote, initial: true) { _, isWriting in
            if isWriting { isFocused = true }
        }
        .onChange(of: text) { createIfNeeded() }
        .task(id: text) {
            try? await Task.sleep(for: Self.pause)
            if !Task.isCancelled { save() }
        }
        .onChange(of: note?.body) { old, new in
            // An edit from another device shows up, unless something was typed here since
            // the last save. Then the text here is the later edit and stays.
            if !isLoaded, let new {
                // The note arrived with the first sync.
                text = new
                isLoaded = true
            } else if let old, let new, text == old {
                text = new
            }
        }
        .onChange(of: currentID.map(store.noteID)) {
            // The server gave the note its ID. The list selects it under that one. Worked out
            // from the note that is open now: another one may have been opened in the same
            // moment.
            guard let current = currentID else { return }
            let id = store.noteID(current)
            guard id != current else { return }
            currentID = id
            if navigation.noteID == current { navigation.noteID = id }
        }
        .onChange(of: note?.trashed) { _, isTrashed in
            // Trashed here or on another device: there is nothing left to edit. What was typed
            // since the last save still goes to the note, so it can be found in the trash.
            if isTrashed == true {
                save(evenIfTrashed: true)
                close()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onChange(of: lock.isOpen) { _, isOpen in
            // The text leaves the screen. What was typed since the last save goes with it.
            if !isOpen { save() }
        }
        .onDisappear(perform: leave)
    }

    // In place of the text while the lock is closed.
    private var lockedPlaceholder: some View {
        ContentUnavailableView {
            Label("This note is locked", systemImage: "lock.fill")
        } description: {
            if let failure = lock.failure {
                Text(failure)
            }
        } actions: {
            Button("Unlock with \(NoteLock.method)", action: unlock)
                .buttonStyle(.bordered)
                // The one thing to do on this screen, so it gets the height of a finger.
                .controlSize(.large)
                .padding(.top, 8)
                .disabled(lock.isAsking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // What the row in the list says about the note, in words here: nothing of it shows in
    // the text itself.
    @ViewBuilder
    private func status(_ note: Note) -> some View {
        let project = store.projectName(note.projectId)
        if note.locked || note.hiddenFromAgents || project != nil {
            // Side by side, or one under the other where the text column is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { statusLabels(note, project) }
                VStack(alignment: .leading, spacing: 4) { statusLabels(note, project) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func statusLabels(_ note: Note, _ project: String?) -> some View {
        if note.locked {
            Label("Locked", systemImage: lock.isOpen ? "lock.open" : "lock")
        }
        if note.hiddenFromAgents {
            Label("Hidden from agent", systemImage: "eye.slash")
        }
        if let project {
            Label(project, systemImage: note.projectId.flatMap(store.project)?.symbol ?? Project.defaultSymbol)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ note: Note?) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(
                note?.pinned == true ? "Unpin" : "Pin",
                systemImage: note?.pinned == true ? "pin.fill" : "pin",
            ) {
                if let note { store.updateNote(note.id, NotePatch(pinned: !note.pinned)) }
            }
            .disabled(note == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: Self.moreSymbol) { actions(note) }
        }
    }

    // The glass of an iOS toolbar is the circle already.
    #if os(iOS)
    private static let moreSymbol = "ellipsis"
    #else
    private static let moreSymbol = "ellipsis.circle"
    #endif

    @ViewBuilder
    private func actions(_ note: Note?) -> some View {
        if isGated {
            Button("Unlock with \(NoteLock.method)", systemImage: "lock.open", action: unlock)
        } else {
            openActions(note)
        }
    }

    private func openActions(_ note: Note?) -> some View {
        Group {
            if let piece = selectedText {
                Button("Turn Selection into Item", systemImage: "checkmark.circle") { turnIntoItem(piece) }
            }
            Button("Turn Note into Item", systemImage: "arrow.turn.down.right", action: turnNoteIntoItem)
            Divider()
            Menu("Project", systemImage: Place.project("").systemImage) {
                Picker("Project", selection: project) {
                    Text("None").tag(String?.none)
                    ForEach(store.projects) { project in
                        Text(project.name).tag(String?.some(project.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Button(
                note?.hiddenFromAgents == true ? "Show to Agent" : "Hide from Agent",
                systemImage: note?.hiddenFromAgents == true ? "eye" : "eye.slash",
            ) {
                if let note { store.updateNote(note.id, NotePatch(hiddenFromAgents: !note.hiddenFromAgents)) }
            }
            Button(
                note?.locked == true ? "Remove Lock" : "Lock Note",
                systemImage: note?.locked == true ? "lock.slash" : "lock",
                action: toggleLock,
            )
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive, action: trash)
        }
        // A note that has no text yet has nothing to file or trash.
        .disabled(note == nil)
    }

    private var project: Binding<String?> {
        Binding {
            note?.projectId
        } set: { id in
            if let currentID { store.updateNote(currentID, NotePatch(projectId: id.map { .set($0) } ?? .clear)) }
        }
    }

    private func unlock() {
        Task { await lock.open() }
    }

    // The lock comes off without a question: the menu only offers it while the lock is open.
    // Putting it on asks first, so a device that cannot open a lock does not close one.
    private func toggleLock() {
        guard let note else { return }
        if note.locked {
            store.updateNote(note.id, NotePatch(locked: false))
            return
        }
        save()
        Task {
            if await lock.open() {
                store.updateNote(note.id, NotePatch(locked: true))
            } else {
                lockFailure = lock.failure
            }
        }
    }

    // The marked part of the text, when there is one.
    private var selectedText: String? {
        guard let selection, case .selection(let range) = selection.indices, !range.isEmpty,
              range.upperBound <= text.endIndex else { return nil }
        let piece = String(text[range])
        return piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : piece
    }

    // MARK: Opening and saving

    private func open(_ id: Int?) {
        if let id, let currentID, store.noteID(currentID) == store.noteID(id) { return }
        if id == nil, currentID == nil {
            // A new note, or still the one that was just started.
            isLoaded = true
            return
        }
        leave()
        currentID = id
        let note = id.flatMap(store.note)
        text = note?.body ?? ""
        // A new note has nothing to load.
        isLoaded = id == nil || note != nil
        selection = nil
        if id != nil { navigation.isWritingNote = false }
        // Opening a locked note is the wish to read it, so the question comes by itself.
        if note?.locked == true, !lock.isOpen { unlock() }
    }

    // A new note exists from its first character on, so it is in the list while it is written.
    private func createIfNeeded() {
        guard currentID == nil, isLoaded, !isBlank else { return }
        let id = store.addNote(NewNote(body: text.cut(to: Note.bodyLimit)))
        currentID = id
        navigation.noteID = id
        navigation.isWritingNote = false
    }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // An emptied note is not sent: the server keeps the last text it had.
    private func save(evenIfTrashed: Bool = false) {
        guard isLoaded, let currentID, let note = store.note(currentID), !isBlank,
              !note.trashed || evenIfTrashed else { return }
        let body = text.cut(to: Note.bodyLimit)
        if body != note.body {
            store.updateNote(currentID, NotePatch(body: body))
        }
    }

    // The note is left for another one, or the editor closes. A note without text goes to the
    // trash, like a sheet of paper nobody wrote on.
    private func leave() {
        guard isLoaded, let currentID, let note = store.note(currentID), !note.trashed else { return }
        if isBlank {
            store.updateNote(currentID, NotePatch(trashed: true))
        } else {
            save()
        }
    }

    private func close() {
        currentID = nil
        isLoaded = false
        navigation.noteID = nil
        navigation.isWritingNote = false
    }

    // MARK: Turn into item

    private func turnIntoItem(_ piece: String) {
        guard let note, !isGated else { return }
        save()
        if let id = store.addItem(from: piece, of: note) {
            navigation.itemID = id
        }
    }

    // The question may still be on screen when the note is locked from somewhere else. Its
    // answer must not carry the text into an item then.
    // Nothing asks first: the trash gives the note back.
    private func trash() {
        save()
        if let currentID { store.updateNote(currentID, NotePatch(trashed: true)) }
    }

    // Asks nothing either: the note only moves to the trash.
    private func turnNoteIntoItem() {
        guard let note, let currentID, !isGated, let id = store.addItem(from: text, of: note) else { return }
        save()
        store.updateNote(currentID, NotePatch(trashed: true))
        navigation.itemID = id
    }
}

// The search field of Locked Notes on the iPhone.
private struct LockedSearch: ViewModifier {
    let isOn: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isOn {
            content.searchable(text: $text, prompt: "Search locked notes")
        } else {
            content
        }
    }
}

// Locked Notes, over Notes. On the iPhone the editor of a locked note opens over it in turn.
private struct LockedNotesDestination: ViewModifier {
    let isOn: Bool
    @Binding var isPresented: Bool
    let query: String

    func body(content: Content) -> some View {
        if isOn {
            content.navigationDestination(isPresented: $isPresented) {
                NotesView(query: query, showsLocked: true)
            }
        } else {
            content
        }
    }
}

// The title of the bar, where the editor is the screen.
private struct NoteTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

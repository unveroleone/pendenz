import SwiftUI

// What was moved to the trash: items, then notes, the last one moved there on top. Nothing
// opens from here. A row is put back where it was and opened there.
struct TrashView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let items = store.trashedItems
        let notes = store.trashedNotes
        List {
            Group {
                if !items.isEmpty {
                    ListSection("Items") {
                        ForEach(items) { item in
                            TrashedItemRow(item: item)
                        }
                    }
                }
                if !notes.isEmpty {
                    ListSection("Notes") {
                        ForEach(notes) { note in
                            TrashedNoteRow(note: note)
                        }
                    }
                }
            }
            .macListRows()
        }
        .macListLook()
        .animation(.default, value: items.map(\.id))
        .animation(.default, value: notes.map(\.id))
        .overlay {
            if items.isEmpty, notes.isEmpty {
                EmptyState(place: .trash)
            }
        }
        .navigationTitle("Trash")
        .refreshable { await store.sync() }
        .toolbar { SyncStatus() }
        // The trash is read from disk when it is first opened, not at launch.
        .task { store.loadTrash() }
    }
}

private struct TrashedItemRow: View {
    @Environment(Store.self) private var store
    let item: Item

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(2)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            PutBackButton(name: item.title) { store.restore(item) }
        }
        .padding(.vertical, 4)
        .modifier(PutBackActions { store.restore(item) })
    }

    // Where the item returns to, so putting it back holds no surprise.
    private var details: some View {
        let project = item.projectId.flatMap(store.project)
        let due = item.dueAt.flatMap { DueText.label(for: $0, today: store.today, showsDay: true) }
        return HStack(spacing: 10) {
            Label(project?.name ?? "Inbox", systemImage: project?.symbol ?? Place.inbox.systemImage)
            if item.status == .done {
                Label("Completed", systemImage: "checkmark.circle")
            }
            if let due {
                Label(due, systemImage: "calendar")
                    .accessibilityLabel("Due \(due)")
            }
        }
        .labelStyle(.compact)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct TrashedNoteRow: View {
    @Environment(Store.self) private var store
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            NoteRow(note: note)
            PutBackButton(name: note.title) { store.restore(note) }
        }
        .modifier(PutBackActions { store.restore(note) })
    }
}

// The visible way back. The words say what it does; an arrow alone would not.
private struct PutBackButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button("Put Back", action: action)
            .buttonStyle(.bordered)
            // VoiceOver reads the buttons of a list one after the other, so each names its row.
            .accessibilityLabel("Put back \(name)")
    }
}

// The same action on a swipe and in the row's menu, as the other lists offer theirs.
private struct PutBackActions: ViewModifier {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button("Put Back", systemImage: "arrow.uturn.backward", action: action)
                    .tint(Color(.selection))
            }
            .contextMenu {
                Button("Put Back", systemImage: "arrow.uturn.backward", action: action)
            }
    }
}

import SwiftUI

// What can be done to an item without opening it. Shown on a long press or a right click.
struct ItemMenu: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    let item: Item

    var body: some View {
        Button(item.status == .done ? "Mark as Open" : "Complete", systemImage: "checkmark.circle") {
            store.toggleDone(item)
        }
        if item.isOpen {
            Button(
                item.status == .doing ? "Mark as To Do" : "Mark as Doing",
                systemImage: item.status == .doing ? "circle" : "smallcircle.filled.circle",
            ) {
                store.toggleDoing(item)
            }
        }
        Divider()
        Menu("Due", systemImage: "calendar") {
            Button("Today") { store.reschedule(item, to: store.today) }
            Button("Tomorrow") { store.reschedule(item, to: store.today.adding(days: 1)) }
            Button("In a Week") { store.reschedule(item, to: store.today.adding(days: 7)) }
            if item.dueAt != nil {
                Divider()
                Button("No Date") { store.reschedule(item, to: nil) }
            }
        }
        Menu("Project", systemImage: Place.project("").systemImage) {
            Picker("Project", selection: project) {
                Text("Inbox").tag(String?.none)
                ForEach(store.projects) { project in
                    Text(project.name).tag(String?.some(project.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            navigation.trash(item.id, in: store)
        }
    }

    private var project: Binding<String?> {
        Binding {
            item.projectId
        } set: { id in
            store.move(item, toProject: id)
        }
    }
}

// The swipes and the menu of a row: right completes or marks as doing, left reschedules or
// trashes.
struct ItemActions: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    let item: Item

    func body(content: Content) -> some View {
        content
            .contextMenu {
                ItemMenu(item: item)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    store.toggleDone(item)
                } label: {
                    Label(item.status == .done ? "Open" : "Complete", systemImage: "checkmark")
                }
                .tint(Color(.selection))
                if item.isOpen {
                    Button {
                        store.toggleDoing(item)
                    } label: {
                        Label(
                            item.status == .doing ? "To Do" : "Doing",
                            // A swipe draws its symbol filled, so a plain circle would read as a dot.
                            systemImage: item.status == .doing ? "arrow.uturn.backward" : "smallcircle.filled.circle",
                        )
                    }
                    .tint(.gray)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    navigation.trash(item.id, in: store)
                } label: {
                    Label("Trash", systemImage: "trash")
                }
                .tint(.red)
                Button {
                    store.reschedule(item, to: store.today.adding(days: 1))
                } label: {
                    Label("Tomorrow", systemImage: "sunrise")
                }
                .tint(Color(.selection))
                if item.dueAt?.day != store.today {
                    Button {
                        store.reschedule(item, to: store.today)
                    } label: {
                        Label("Today", systemImage: "sun.max")
                    }
                    .tint(.gray)
                }
            }
    }
}

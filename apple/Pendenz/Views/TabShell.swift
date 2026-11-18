import SwiftUI

struct TabShell: View {
    private enum AppTab: String, Hashable {
        case reminders, tasks, notes, agents, search
    }

    // Remembered per window, so two windows on an iPad do not switch each other's tab.
    @SceneStorage("tab") private var savedTab = AppTab.tasks
    // The list that was open in Tasks, so the tab comes back to it after a relaunch. Empty for
    // the list of lists.
    @SceneStorage("tasksPlace") private var savedTasksPlace = ""
    // The tab named by the launch argument `-tab`. A window launched with it starts there and
    // leaves the remembered tab alone: what the scene restores arrives later and would win.
    @State private var launchTab = Settings.openedTab.flatMap(AppTab.init(rawValue:))
    @State private var query = ""
    // `-place trash` or `-place completed` next to `-tab tasks` opens that list, which has no
    // tab of its own.
    @State private var tasksPath: [Place] = Settings.openedPlace
        .map { [.completed, .trash].contains($0) ? [$0] : [] } ?? []
    @State private var isAdding = false
    // Quick add was asked for from the home screen. Nobody saw which list was on screen then,
    // so the item goes to the inbox.
    @State private var addsToInbox = false
    // How tall quick add is with the text size in use. Its sheet takes this height.
    @State private var quickAddHeight: CGFloat = 124
    @Environment(Navigation.self) private var navigation
    @Environment(Store.self) private var store
    @Environment(AgentBoard.self) private var agents
    @AppStorage(AgentsVisibility.key) private var agentsVisibility = AgentsVisibility.automatic

    private var isShowingItem: Binding<Bool> {
        Binding {
            navigation.itemID != nil
        } set: { isShown in
            if !isShown { navigation.itemID = nil }
        }
    }

    private var tab: AppTab {
        get { launchTab ?? savedTab }
        nonmutating set {
            if launchTab == nil { savedTab = newValue } else { launchTab = newValue }
        }
    }

    // Where a new item goes: the list on screen, or the inbox when that is not a single list.
    private var addPlace: Place {
        switch tab {
        case .reminders: .reminders
        case .tasks: tasksPath.last ?? .inbox
        case .notes, .agents, .search: .inbox
        }
    }

    var body: some View {
        TabView(selection: Binding { tab } set: { tab = $0 }) {
            Tab("Tasks", systemImage: "tray.full", value: AppTab.tasks) {
                NavigationStack(path: $tasksPath) { TasksView() }
                    .contentMargins(.bottom, QuickAddButton.clearance, for: .scrollContent)
                    .overlay(alignment: .bottomTrailing) {
                        // Nothing is added to the finished items or to the trash.
                        if tasksPath.last != .trash, tasksPath.last != .completed { addButton }
                    }
            }
            Tab("Reminders", systemImage: Place.reminders.systemImage, value: AppTab.reminders) {
                NavigationStack {
                    ItemListView(place: .reminders)
                        .toolbar { SettingsItem() }
                }
                .contentMargins(.bottom, QuickAddButton.clearance, for: .scrollContent)
                .overlay(alignment: .bottomTrailing) { addButton }
            }
            Tab("Notes", systemImage: Place.notes.systemImage, value: AppTab.notes) {
                NotesTab()
            }
            if agentsVisibility.isShown(agents) {
                Tab("Agents", systemImage: Place.agents.systemImage, value: AppTab.agents) {
                    NavigationStack {
                        AgentsView()
                            .toolbar { SettingsItem() }
                    }
                }
                .badge(store.count(for: .agents))
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack {
                    SearchResultsView(query: query)
                        .navigationTitle("Search")
                }
                .searchable(text: $query, prompt: "Items")
            }
        }
        .sheet(isPresented: $isAdding) {
            quickAdd
        }
        .sheet(isPresented: isShowingItem) {
            if let id = navigation.itemID {
                NavigationStack {
                    ItemDetailView(itemID: id) { navigation.itemID = nil }
                        // A new view per item, so the text of one never lands in another.
                        .id(id)
                        .navigationTitle("Item")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { navigation.itemID = nil }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .focusedSceneValue(\.isAddingItem, $isAdding)
        // The list commands of the menu name a place. Here a place is a tab.
        .onChange(of: navigation.place) { _, place in
            switch place {
            case .reminders: tab = .reminders
            case .notes: tab = .notes
            case .inbox:
                tab = .tasks
                // The list of lists stands for the inbox too, so coming back to the tab names
                // this place. The inbox stays open then; from a project it goes back up.
                if tasksPath.last != .inbox { tasksPath = [] }
            case .project(let id):
                tab = .tasks
                tasksPath = [.project(id)]
            case .completed:
                tab = .tasks
                tasksPath = [.completed]
            case .trash:
                tab = .tasks
                tasksPath = [.trash]
            case .agents: tab = .agents
            case nil: break
            }
        }
        // A list asked for from outside, by a widget, the home screen menu or Siri: it opens as
        // that list, the inbox included. Also when it was asked for before this view existed.
        // Not through `navigation.place`, which stays on Completed after a step back from it,
        // so asking for Completed again would change nothing.
        .onChange(of: navigation.requestedPlace, initial: true) { _, place in
            guard let place else { return }
            navigation.requestedPlace = nil
            switch place {
            case .reminders:
                tab = .reminders
            case .notes:
                tab = .notes
            case .agents:
                tab = .agents
            case .inbox, .project, .completed, .trash:
                tab = .tasks
                if tasksPath != [place] { tasksPath = [place] }
            }
        }
        .onChange(of: store.projects.map(\.id)) { _, ids in
            // A deleted project leaves the stack, also when another device deleted it.
            tasksPath.removeAll { place in
                if case .project(let id) = place { !ids.contains(id) } else { false }
            }
        }
        .onChange(of: tab, initial: true) { _, tab in
            // Kept in step, so a command for the place already named still switches back.
            switch tab {
            case .reminders: navigation.place = .reminders
            case .notes: navigation.place = .notes
            case .agents: navigation.place = .agents
            case .tasks: navigation.place = tasksPath.last ?? .inbox
            case .search: navigation.place = nil
            }
        }
        // Also when it was asked for before this view existed, by the home screen menu.
        .onChange(of: navigation.isSearchFocused, initial: true) { _, wanted in
            if wanted {
                tab = .search
                navigation.isSearchFocused = false
            }
        }
        .onChange(of: navigation.wantsNewItem, initial: true) { _, wanted in
            if wanted {
                navigation.wantsNewItem = false
                addsToInbox = true
                isAdding = true
            }
        }
        .onChange(of: isAdding) { _, isShown in
            if !isShown { addsToInbox = false }
        }
        // What the scene remembers arrives after the first draw, so this waits for the value.
        .onChange(of: savedTasksPlace, initial: true) { restoreTasksPlace() }
        .onChange(of: tasksPath) { _, path in
            // A window launched on a named tab leaves what is remembered alone, as for the tab.
            if launchTab == nil { savedTasksPlace = Self.name(of: path.last) }
        }
        .task {
            if Settings.opensQuickAdd { isAdding = true }
        }
    }

    // Tasks opens on the list it was left on. Without a move: the list is where the tab
    // starts, not somewhere it goes.
    private func restoreTasksPlace() {
        guard launchTab == nil, Settings.openedPlace == nil, tasksPath.isEmpty,
              let place = Self.place(named: savedTasksPlace) else { return }
        // A project that was deleted in the meantime has no list to come back to.
        if case .project(let id) = place, store.project(id) == nil { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { tasksPath = [place] }
    }

    private static func name(of place: Place?) -> String {
        switch place {
        case .inbox: "inbox"
        case .completed: "completed"
        case .trash: "trash"
        case .project(let id): "project:\(id)"
        case .reminders, .notes, .agents, nil: ""
        }
    }

    private static func place(named name: String) -> Place? {
        switch name {
        case "inbox": .inbox
        case "completed": .completed
        case "trash": .trash
        default: name.hasPrefix("project:") ? .project(String(name.dropFirst("project:".count))) : nil
        }
    }

    // The sheet is as tall as its content, so it ends where the keyboard begins, also with a
    // larger text size.
    private var quickAdd: some View {
        QuickAddView(place: addsToInbox ? .inbox : addPlace)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                quickAddHeight = height
            }
            .presentationDetents([.height(quickAddHeight)])
            .presentationDragIndicator(.visible)
            #if os(iOS)
            // Not the glass of a low sheet: the list behind it showed through the field.
            .presentationBackground(Color(.secondarySystemBackground))
            #endif
    }

    private var addButton: some View {
        QuickAddButton { isAdding = true }
            // Out of the way while its sheet is open: with no keyboard on screen it showed
            // behind the sheet's corner.
            .opacity(isAdding ? 0 : 1)
    }
}

// The Notes tab, with a search field of its own that filters the notes.
private struct NotesTab: View {
    @State private var query = ""

    var body: some View {
        NavigationStack {
            NotesView(query: query)
                .searchable(text: $query, prompt: "Search notes")
                .toolbar { SettingsItem() }
        }
    }
}

// The Tasks tab: the inbox and every project.
struct TasksView: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation

    var body: some View {
        List {
            OutdatedServerSection()
            PlaceLink(place: .inbox)
            Section("Projects") {
                ForEach(store.orderedProjects) { project in
                    PlaceLink(place: .project(project.id))
                }
                // A quiet last row. Editing a project is behind a long press on its row.
                Button("New Project", systemImage: "plus") { navigation.projectEditor = .new }
                    .foregroundStyle(.secondary)
            }
            // Last and without a number: places to look into, not lists to work through.
            Section {
                PlaceLink(place: .completed)
                PlaceLink(place: .trash)
            }
        }
        .navigationTitle("Tasks")
        .navigationDestination(for: Place.self) { place in
            if place == .trash {
                TrashView()
            } else if place == .completed {
                CompletedView()
            } else {
                ItemListView(place: place)
            }
        }
        .refreshable { await store.sync() }
        .toolbar {
            SettingsItem()
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { ProjectOrderMenu() }
            #endif
            SyncStatus()
        }
    }
}

// The gear on the first screen of each tab, always in the same corner. The Mac has the
// settings in its app menu.
private struct SettingsItem: ToolbarContent {
    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) { SettingsButton() }
        #endif
    }
}

// A row that leads to a list and shows how many open items it holds.
struct PlaceLink: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    let place: Place
    @State private var isConfirmingDelete = false

    // A dropped item gets today's date, the inbox or the project. The other entries have
    // nothing to set.
    private var takesItems: Bool {
        switch place {
        case .reminders, .inbox, .project: true
        case .notes, .completed, .trash, .agents: false
        }
    }

    var body: some View {
        NavigationLink(value: place) {
            Label(store.title(for: place), systemImage: store.symbol(for: place))
                .badge(store.count(for: place))
        }
        .contextMenu {
            if case .project(let id) = place {
                Button("Edit", systemImage: "pencil") { navigation.projectEditor = .edit(id) }
                Divider()
                Button("Delete Project", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            }
        }
        .modifier(ProjectDeleteQuestion(place: place, isPresented: $isConfirmingDelete))
        .dropDestination(for: ItemRef.self) { refs, _ in
            let items = refs.compactMap { store.item($0.id) }
            guard takesItems, !items.isEmpty else { return false }
            for item in items { store.drop(item, on: place) }
            return true
        }
    }
}

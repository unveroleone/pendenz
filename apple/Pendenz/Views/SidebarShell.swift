import SwiftUI

struct SidebarShell: View {
    @Environment(Store.self) private var store
    @Environment(AgentBoard.self) private var agents
    @AppStorage(AgentsVisibility.key) private var agentsVisibility = AgentsVisibility.automatic
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @State private var isAdding = false
    // Quick add was asked for from the home screen. Nobody saw which list was on screen then,
    // so the item goes to the inbox.
    @State private var addsToInbox = false
    // Kept on this device, so the projects stay folded over a relaunch.
    @AppStorage("projectsExpanded") private var isProjectsExpanded = true
    @Environment(Navigation.self) private var navigation

    private var isShowingItem: Binding<Bool> {
        Binding {
            navigation.itemID != nil
        } set: { isShown in
            if !isShown { navigation.itemID = nil }
        }
    }

    private var searchPrompt: String {
        if navigation.place == .notes {
            navigation.isInLockedNotes ? "Search locked notes" : "Search notes"
        } else {
            "Search items"
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        @Bindable var navigation = navigation
        let place = navigation.place
        NavigationSplitView {
            List(selection: $navigation.place) {
                OutdatedServerSection()
                Section {
                    PlaceLink(place: .inbox)
                    PlaceLink(place: .reminders)
                    PlaceLink(place: .notes)
                    if agentsVisibility.isShown(agents) {
                        PlaceLink(place: .agents)
                    }
                }
                Section("Projects", isExpanded: $isProjectsExpanded) {
                    ForEach(store.orderedProjects) { project in
                        PlaceLink(place: .project(project.id))
                    }
                }
                // Last and without a number: places to look into, not lists to work through.
                Section {
                    PlaceLink(place: .completed)
                    PlaceLink(place: .trash)
                }
            }
            .safeAreaBar(edge: .bottom) {
                SidebarFooter()
            }
            // A hard edge: with the soft one the rows of a long list showed through the foot.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // The system draws the selected row in white on the tint. The app tint is the label
            // color, which is white in dark mode, so the sidebar gets a gray that carries white.
            // macOS ignores a tint here and takes the same gray as its accent color, set in the
            // build settings.
            .tint(Color(.selection))
            .navigationTitle("Pendenz")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
            }
            #endif
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
            #endif
        } detail: {
            NavigationStack {
                Group {
                    if place == .notes {
                        // In Notes the search field filters the notes. One view with and
                        // without a search, so Locked Notes stays open over it.
                        NotesView(query: query)
                    } else if isSearching {
                        SearchResultsView(query: query)
                            .navigationTitle("Search")
                    } else {
                        switch place {
                        case .completed: CompletedView()
                        case .trash: TrashView()
                        case .agents: AgentsView()
                        case let place?: ItemListView(place: place)
                        case nil: ContentUnavailableView("Choose a list", systemImage: "sidebar.left")
                        }
                    }
                }
                // Inside the detail column: the iPad shows no toolbar items set on the split view.
                .toolbar {
                    if navigation.itemID != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Hide Details", systemImage: "sidebar.trailing") { navigation.itemID = nil }
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Item", systemImage: "plus") { isAdding = true }
                            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                                QuickAddView(place: isSearching || addsToInbox ? .inbox : place ?? .inbox)
                                    .frame(width: 380)
                            }
                    }
                }
            }
            // On the stack, not inside it: inside, the iPad drops the list's title.
            .inspector(isPresented: isShowingItem) {
                if let id = navigation.itemID {
                    ItemDetailView(itemID: id) { navigation.itemID = nil }
                        // A new view per item, so the text of one never lands in another.
                        .id(id)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
            }
        }
        .searchable(text: $query, prompt: searchPrompt)
        .searchFocused($isSearchFocused)
        .onChange(of: agentsVisibility.isShown(agents), initial: true) { _, isShown in
            // The entry was taken away while it was open.
            if !isShown, navigation.place == .agents { navigation.place = .inbox }
        }
        .onChange(of: navigation.place) { _, place in
            // A list chosen while a search is on screen ends the search.
            query = ""
            // Notes has a list and an editor of its own, and no room for the detail of an item
            // that was open in another list. An item made from a note still opens there.
            if place == .notes { navigation.itemID = nil }
            // Locked Notes closes with Notes, so another list never leads back into it.
            if place != .notes, navigation.isInLockedNotes { navigation.leaveLockedNotes() }
            // A project that opens from somewhere else, such as a new one, is not left hidden
            // in the folded group.
            if case .project = place { isProjectsExpanded = true }
        }
        .onChange(of: navigation.isInLockedNotes) {
            // A search does not carry over between Notes and Locked Notes.
            query = ""
        }
        .onChange(of: navigation.isSearchFocused, initial: true) { _, wanted in
            // The Search command asks for the field through the window's navigation. Also when
            // it was asked for before this view existed, by the home screen menu.
            if wanted {
                isSearchFocused = true
                navigation.isSearchFocused = false
            }
        }
        .task(id: navigation.wantsNewItem) {
            guard navigation.wantsNewItem else { return }
            // Not at once: a popover that opens before its toolbar button exists crashes, and
            // the action may have started the app. The request is cleared after the wait:
            // clearing it changes this task's ID, which would cut the wait short.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            navigation.wantsNewItem = false
            addsToInbox = true
            isAdding = true
        }
        .onChange(of: isAdding) { _, isShown in
            if !isShown { addsToInbox = false }
        }
        .focusedSceneValue(\.isAddingItem, $isAdding)
        #if os(macOS)
        // Escape closes the detail. Not a menu shortcut: that would take the key from every
        // text field and popover. Here it arrives only when nothing nearer wanted it, so a
        // popover or the search field closes first.
        .onExitCommand {
            if navigation.itemID != nil { navigation.itemID = nil }
        }
        #endif
    }
}

// The foot of the sidebar, for what is not a list: a new project, the order of the projects
// and, on the Mac, the settings.
private struct SidebarFooter: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        HStack(spacing: 0) {
            Button {
                navigation.projectEditor = .new
            } label: {
                // The plus under the icons of the rows and the words under their titles.
                HStack(spacing: Self.titleGap) {
                    Image(systemName: "plus")
                        .frame(width: Self.iconWidth)
                    Text("New Project")
                        .lineLimit(1)
                }
                .frame(minHeight: Self.target)
                .contentShape(Rectangle())
            }
            Spacer(minLength: 8)
            ProjectOrderMenu(isQuiet: true)
                .labelStyle(.iconOnly)
                .frame(minWidth: Self.target, minHeight: Self.target)
                .help("Sort Projects")
            #if os(macOS)
            // The iPad has its gear in the toolbar, in the same corner as the iPhone.
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: Self.target, minHeight: Self.target)
                    .contentShape(Rectangle())
            }
            .help("Settings")
            #endif
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // The gray of the list is for its selected row. The menu of the order takes the tint
        // into its choices, which have to read in black or white.
        .tint(Color.accentColor)
        .padding(.leading, Self.leading)
        .padding(.trailing, Self.trailing)
        .padding(.vertical, 4)
    }

    // The measures of a sidebar row on each system, so the foot lines up with the list.
    #if os(macOS)
    private static let leading: CGFloat = 18
    private static let trailing: CGFloat = 10
    private static let iconWidth: CGFloat = 22
    private static let titleGap: CGFloat = 6
    private static let target: CGFloat = 28
    #else
    private static let leading: CGFloat = 28
    private static let trailing: CGFloat = 12
    private static let iconWidth: CGFloat = 32
    private static let titleGap: CGFloat = 7
    private static let target: CGFloat = 44
    #endif
}

// The menu that chooses how the projects are ordered.
struct ProjectOrderMenu: View {
    // Gray, as the controls next to it in the foot of the sidebar. A menu takes no color from
    // the views around it, so its label carries it.
    var isQuiet = false
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Sort Projects By", selection: $store.projectOrder) {
                ForEach(ProjectOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            if isQuiet {
                Label("Sort Projects", systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(.secondary)
            } else {
                Label("Sort Projects", systemImage: "arrow.up.arrow.down")
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

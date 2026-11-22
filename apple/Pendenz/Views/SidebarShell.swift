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
            // The controls of the foot are glass of their own, so rows may pass under them.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
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
            // The lists of this layout without lines (`Look.swift`). The iPhone layout keeps them.
            .environment(\.usesSidebarLook, true)
            #if os(macOS)
            // No bar behind the toolbar and no line under it: the list runs up under the
            // controls and softens there.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            #endif
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
// and, on the Mac, the settings. Two floating capsules of glass, as the controls in a toolbar: a
// new project on the left, the rest on the right. The iPad has its gear in the toolbar, in the
// same corner as the iPhone.
private struct SidebarFooter: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    navigation.projectEditor = .new
                } label: {
                    // In a narrow sidebar the plus alone.
                    ViewThatFits(in: .horizontal) {
                        Label("New Project", systemImage: "plus")
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, Self.inset)
                        Label("New Project", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: Self.target)
                    }
                    .frame(minHeight: Self.target)
                    .contentShape(Capsule())
                }
                .help("New Project")
                .glassEffect(.regular.interactive(), in: .capsule)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    ProjectOrderMenu(isQuiet: true, target: Self.target)
                        .labelStyle(.iconOnly)
                        .help("Sort Projects")
                    #if os(macOS)
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: Self.target, minHeight: Self.target)
                            .contentShape(Capsule())
                    }
                    .help("Settings")
                    #endif
                }
                #if os(macOS)
                .padding(.horizontal, 4)
                #endif
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // The gray of the list is for its selected row. The menu of the order takes the tint
        // into its choices, which have to read in black or white.
        .tint(Color.accentColor)
        .padding(.horizontal, Self.edge)
        .padding(.vertical, 8)
    }

    // The smallest target for a control on each system, and the room around the capsules.
    #if os(macOS)
    private static let target: CGFloat = 28
    private static let inset: CGFloat = 12
    private static let edge: CGFloat = 10
    #else
    private static let target: CGFloat = 44
    private static let inset: CGFloat = 16
    private static let edge: CGFloat = 16
    #endif
}

// The menu that chooses how the projects are ordered.
struct ProjectOrderMenu: View {
    // Gray, as the controls next to it in the foot of the sidebar. A menu takes no color from
    // the views around it, so its label carries it.
    var isQuiet = false
    // The smallest size that takes a tap. Inside the label, since the menu itself is fixed to
    // its label's size and a frame around it does not take taps.
    var target: CGFloat = 0
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
            Group {
                if isQuiet {
                    Label("Sort Projects", systemImage: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Sort Projects", systemImage: "arrow.up.arrow.down")
                }
            }
            .frame(minWidth: target, minHeight: target)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

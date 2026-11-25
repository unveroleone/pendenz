import SwiftUI

private struct OpenNoteLock: Equatable {
    let id: Int?
    let isLocked: Bool?
}

private struct ReminderInput: Equatable {
    let items: [Item]
    let access: Reminders.Access
}

// Tabs where the window is narrow (iPhone, a slim iPad window), a sidebar everywhere else.
struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(AgentBoard.self) private var agents
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif
    @State private var navigation = Navigation()
    private var reminders: Reminders { .shared }
    private var quickActions: QuickActions { .shared }
    private var openRequest: OpenRequest { .shared }

    private var isShowingRejection: Binding<Bool> {
        Binding {
            store.rejection != nil
        } set: { isShown in
            if !isShown { store.rejection = nil }
        }
    }

    // Shows a list that a widget, the home screen menu or Siri asked for. The sidebar selects
    // it; the tabs have to be told, because there the inbox is not always a list of its own.
    private func open(_ place: Place) {
        if sizeClass == .compact {
            navigation.requestedPlace = place
        } else {
            navigation.place = place
        }
    }

    // Every window watches the requests from outside. On the Mac the one in front carries them
    // out; elsewhere there is one window in front anyway.
    private var isInFront: Bool {
        #if os(macOS)
        appearsActive
        #else
        true
        #endif
    }

    private func takeRequests() {
        guard isInFront else { return }
        if let action = quickActions.chosen {
            quickActions.chosen = nil
            switch action {
            case .newItem: navigation.wantsNewItem = true
            case .newNote: navigation.writeNote()
            case .reminders: open(.reminders)
            case .search: navigation.isSearchFocused = true
            }
        }
        if let place = openRequest.place {
            openRequest.place = nil
            let isGone = if case .project(let id) = place { store.project(id) == nil } else { false }
            if !isGone { open(place) }
        }
        if let id = openRequest.itemID {
            openRequest.itemID = nil
            if store.item(id) != nil { navigation.itemID = id }
        }
        if let id = openRequest.noteID {
            if let note = store.note(id) {
                openRequest.noteID = nil
                let id = store.noteID(id)
                if note.locked {
                    // Into Locked Notes, after the one question.
                    Task {
                        if await navigation.openLockedNotes(note: id) { open(.notes) }
                    }
                } else {
                    open(.notes)
                    navigation.leaveLockedNotes()
                    navigation.noteID = id
                }
            } else if store.isCurrent || store.phase != .idle && store.phase != .syncing {
                // Gone from the server too, or the sync failed: it is not waited for longer,
                // so it cannot pull the window away later.
                openRequest.noteID = nil
            }
            // Otherwise it waits for the first sync, which may bring the note.
        }
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                TabShell()
            } else {
                SidebarShell()
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
        .sheet(item: $navigation.projectEditor) { target in
            ProjectEditorView(target: target)
                .environment(navigation)
                // Half height on the iPhone for a new project. An edit opens in full, so the
                // delete button under the icons is on screen. A wide window shows the sheet
                // in its middle.
                .presentationDetents(sizeClass == .compact && target == .new ? [.medium, .large] : [.large])
        }
        .onChange(of: store.projects.map(\.id)) { _, ids in
            // A project that is gone, deleted here or on another device, cannot stay open.
            if case .project(let id) = navigation.place, !ids.contains(id) {
                navigation.place = .inbox
            }
        }
        .environment(navigation)
        .focusedSceneValue(\.navigation, navigation)
        .task { await store.sync() }
        // Once per launch and on each return to the front, so the Agents screen is offered as
        // soon as an agent has sent a report.
        .task { await agents.refresh() }
        .task { await reminders.refreshAccess() }
        // The waiting notifications follow the items, and start when access is given.
        .task(id: ReminderInput(items: store.openItems, access: reminders.access)) {
            guard !store.isClosed else { return }
            await reminders.schedule(store.openItems, isCurrent: store.isCurrent, projectName: store.projectName)
        }
        .onChange(of: reminders.openedItemID, initial: true) { _, id in
            // A tapped notification opens its item in this window, also when the tap came
            // before the window existed.
            if let id {
                navigation.itemID = id
                reminders.openedItemID = nil
            }
        }
        // A tap on a widget: a row opens its item, everything else the list the widget shows.
        .onOpenURL { url in
            switch WidgetLink(url: url) {
            case .item(let id):
                if store.item(id) != nil { navigation.itemID = id }
            case .list(.reminders):
                open(.reminders)
            case .list(.inbox):
                open(.inbox)
            case .list(.project(let id)):
                if store.project(id) != nil { open(.project(id)) }
            // The app has no list of everything, so it opens where it was.
            case .list(.all), nil:
                break
            }
        }
        // An action from the menu of the app's icon or from the control, also when it started
        // the app. A list, an item or a note that Siri, a shortcut or Spotlight asked for, the
        // same way.
        .onChange(of: quickActions.chosen, initial: true) { takeRequests() }
        .onChange(of: openRequest.place, initial: true) { takeRequests() }
        .onChange(of: openRequest.itemID, initial: true) { takeRequests() }
        .onChange(of: openRequest.noteID, initial: true) { takeRequests() }
        // A note asked for before the store had it.
        .onChange(of: store.phase) { takeRequests() }
        .onChange(of: OpenNoteLock(
            id: navigation.noteID,
            isLocked: navigation.noteID.flatMap { store.note($0)?.locked },
        )) { old, new in
            // The same note, locked or unlocked: not another note that was opened.
            if old.id == new.id, let isLocked = new.isLocked, old.isLocked != nil, old.isLocked != isLocked {
                navigation.openNoteLockChanged(isLocked: isLocked)
            }
        }
        .onChange(of: NoteLock.shared.isOpen) { _, isOpen in
            if !isOpen { navigation.lockClosed(in: store) }
        }
        #if os(macOS)
        // A request that came while no window was in front waits for the next one.
        .onChange(of: appearsActive) { takeRequests() }
        #endif
        // Siri learns the names of the lists for "Open <list> in Pendenz".
        .onChange(of: store.projects, initial: true) {
            PendenzShortcuts.updateAppShortcutParameters()
        }
        .sensoryFeedback(.success, trigger: store.completions)
        .alert("Not saved", isPresented: isShowingRejection) {
            Button("OK") {}
        } message: {
            Text(store.rejection ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                SharedDropsIntake.shared.start()
                Task { await agents.refresh() }
                Task {
                    await store.sync()
                    // The sync may have found the device revoked. Its reminders were removed
                    // then and must not come back.
                    guard !store.isClosed else { return }
                    // Also without news from the server: reminders that fired made room for
                    // the next ones.
                    await reminders.schedule(
                        store.openItems,
                        isCurrent: store.isCurrent,
                        projectName: store.projectName,
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            store.refreshToday()
        }
    }
}

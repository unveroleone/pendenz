import SwiftUI

@main
struct PendenzApp: App {
    // Only for the push token and the pushes, which the system hands to an app delegate.
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    @State private var session = Session()

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if let store = session.store, let agents = session.agents {
                    RootView()
                        .environment(store)
                        .environment(agents)
                } else {
                    PairingView()
                        // An action of the home screen menu or the control has nothing to act
                        // on here, and must not wait for the pairing to be carried out after
                        // it. Also when it comes while this screen is open.
                        .onChange(of: QuickActions.shared.chosen, initial: true) {
                            QuickActions.shared.chosen = nil
                        }
                }
            }
            .environment(session)
        }
        #if os(macOS)
        .defaultSize(width: 920, height: 640)
        #endif
        .commands {
            AppCommands(session: session)
        }
        #if os(macOS)
        SwiftUI.Settings {
            MacSettingsView()
                .environment(session)
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}

struct AppCommands: Commands {
    let session: Session
    @FocusedBinding(\.isAddingItem) private var isAddingItem
    @FocusedValue(\.navigation) private var navigation

    // Missing while the device is not paired. The commands are then switched off.
    private var store: Store? {
        session.store
    }

    // The item the commands act on: the one open in the front window.
    private var item: Item? {
        guard let store else { return nil }
        return navigation?.itemID.flatMap(store.item)
    }

    // The list of the front window, when it is one that can be sorted.
    private var sortedPlace: Place? {
        navigation?.place.flatMap { Store.orderKey(for: $0) == nil ? nil : $0 }
    }

    private var itemOrder: Binding<ItemOrder> {
        Binding {
            sortedPlace.flatMap { store?.itemOrder(for: $0) } ?? .manual
        } set: { order in
            if let sortedPlace { store?.setItemOrder(order, for: sortedPlace) }
        }
    }

    private var projectOrder: Binding<ProjectOrder> {
        Binding {
            store?.projectOrder ?? .name
        } set: { order in
            store?.projectOrder = order
        }
    }

    var body: some Commands {
        #if SPARKLE
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.check() }
                .disabled(!Updater.shared.canCheck)
        }
        #endif
        CommandGroup(after: .newItem) {
            Button("New Item") { isAddingItem = true }
                .keyboardShortcut("t")
                .disabled(isAddingItem == nil)
            Button("New Note") { navigation?.writeNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(navigation == nil)
            Button("New Project") { navigation?.projectEditor = .new }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(navigation == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Sync Now") {
                Task { await store?.sync() }
            }
            .keyboardShortcut("r")
            .disabled(store == nil)
            Button("Search") { navigation?.isSearchFocused = true }
                .keyboardShortcut("f")
                .disabled(navigation == nil)
            Divider()
            // The lists of the sidebar, in its order.
            Button("Inbox") { navigation?.place = .inbox }
                .keyboardShortcut("1")
                .disabled(navigation == nil)
            Button("Reminders") { navigation?.place = .reminders }
                .keyboardShortcut("2")
                .disabled(navigation == nil)
            Button("Notes") { navigation?.place = .notes }
                .keyboardShortcut("3")
                .disabled(navigation == nil)
            Button("Completed") { navigation?.place = .completed }
                .disabled(navigation == nil)
            Button("Trash") { navigation?.place = .trash }
                .disabled(navigation == nil)
            Divider()
            // For the list in the front window. Only the inbox and the projects can be sorted.
            Picker("Sort Items By", selection: itemOrder) {
                ForEach(ItemOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .disabled(store == nil || sortedPlace == nil)
            Picker("Sort Projects By", selection: projectOrder) {
                ForEach(ProjectOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .disabled(store == nil)
            Divider()
        }
        CommandMenu("Item") {
            Group {
                Button(item?.status == .done ? "Mark as Open" : "Complete") {
                    if let item { store?.toggleDone(item) }
                }
                .keyboardShortcut("d")
                Divider()
                Button("Due Today") {
                    if let item, let store { store.reschedule(item, to: store.today) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Due Tomorrow") {
                    if let item, let store { store.reschedule(item, to: store.today.adding(days: 1)) }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("No Date") {
                    if let item { store?.reschedule(item, to: nil) }
                }
                .disabled(item?.dueAt == nil)
                Divider()
                // Not Escape: as a menu shortcut it would be taken from every text field and
                // popover in the window.
                Button("Hide Details") { navigation?.itemID = nil }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                // No shortcut here: Command-Delete belongs to the text being edited. On the
                // Mac the Delete key works on the selected row while the list has the focus.
                Button("Move to Trash") {
                    if let item, let store { navigation?.trash(item.id, in: store) }
                }
            }
            // Without an open item there is nothing for these to act on.
            .disabled(item == nil)
        }
    }
}

enum Settings {
    // For development: the launch argument `-apiURL http://127.0.0.1:8080` points the app at a
    // server in local mode, which asks for no token, and skips pairing. Without it the app
    // uses the server it is paired with. A release build ignores it: on the Mac any process
    // can launch the app with arguments, and this one would empty the store and the outbox.
    static var apiURL: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "apiURL").flatMap(URL.init(string:))
        #else
        nil
        #endif
    }

    // The launch argument `-item 12` opens the app with that item's detail on screen.
    static var openedItem: Int? {
        UserDefaults.standard.object(forKey: "item") as? Int ?? Int(UserDefaults.standard.string(forKey: "item") ?? "")
    }

    // The launch argument `-place notes` opens the sidebar layout on that list, where `-tab`
    // does the same for the iPhone layout. `-place trash` also works there, next to `-tab tasks`.
    static var openedPlace: Place? {
        switch UserDefaults.standard.string(forKey: "place") {
        case "reminders": .reminders
        case "inbox": .inbox
        case "notes": .notes
        case "completed": .completed
        case "trash": .trash
        case "agents": .agents
        default: nil
        }
    }

    // The launch argument `-tab tasks` opens the iPhone layout on that tab. Read from the
    // arguments alone: the tab a window was left on is kept by the scene, not in the defaults.
    static var openedTab: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["tab"] as? String
    }

    // The launch argument `-note 3` opens that note once Notes is on screen.
    static var openedNote: Int? {
        Int(UserDefaults.standard.string(forKey: "note") ?? "")
    }

    // The launch argument `-quickAdd YES` opens the iPhone layout with quick add on screen. The
    // sidebar layout ignores it: a popover that opens before its toolbar button exists crashes.
    static var opensQuickAdd: Bool {
        UserDefaults.standard.bool(forKey: "quickAdd")
    }
}

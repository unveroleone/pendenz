import SwiftUI
import UniformTypeIdentifiers

// One list of items: Reminders, the inbox or a project.
struct ItemListView: View {
    @Environment(Store.self) private var store
    let place: Place

    var body: some View {
        let sections = store.sections(for: place)
        ItemsList {
            if place == .reminders, ReminderBanner.isNeeded(in: store) {
                ReminderBanner()
            }
            ForEach(sections) { section in
                ListSection(section.title) {
                    if isManual {
                        // The inbox and the projects keep the order they are dragged into, and
                        // take text dropped from another app at the place it is dropped.
                        ForEach(section.items) { item in
                            ItemRow(item: item, style: rowStyle(in: section))
                                .tag(item.id)
                        }
                        .onMove { source, destination in
                            var rows = section.items
                            rows.move(fromOffsets: source, toOffset: destination)
                            store.reorder(rows, moved: Set(source.map { section.items[$0].id }))
                        }
                        // Also a row of this app: if the drag of a row is not taken as a move
                        // by the list, it arrives here and is placed the same way.
                        .onInsert(of: [.pendenzItem, .url, .plainText]) { index, providers in
                            let rows = section.items
                            drop(
                                providers,
                                below: index > 0 ? rows[index - 1] : nil,
                                above: index < rows.count ? rows[index] : nil,
                            )
                        }
                    } else {
                        // Sorted, so the place of the drop does not matter. Dropped text
                        // becomes an item of this list, for today in Reminders.
                        ForEach(section.items) { item in
                            ItemRow(item: item, style: rowStyle(in: section))
                                .tag(item.id)
                        }
                        .onInsert(of: [.url, .plainText]) { _, providers in
                            drop(providers, below: nil, above: nil)
                        }
                    }
                }
            }
        }
        .animation(.default, value: sections.flatMap { $0.items.map(\.id) })
        #if os(macOS)
        // The banner arrives after the list is on screen, once the answer about notifications
        // is known. The Mac gives a row that joins a visible list the height of a plain row,
        // which cut the banner in half. A list that is built anew measures it.
        .id(place == .reminders && ReminderBanner.isNeeded(in: store))
        #endif
        #if os(macOS)
        .navigationSubtitle(subtitle(sections))
        #endif
        .overlay {
            if sections.isEmpty {
                // An empty list has no rows to drop between, so the empty state takes the text.
                EmptyState(place: place)
                    .modifier(TextDrop(isOn: place != .notes) { texts in
                        store.addDropped(texts, in: place)
                    })
            }
        }
        .navigationTitle(store.title(for: place))
        .refreshable { await store.sync() }
        .toolbar {
            if Store.orderKey(for: place) != nil {
                ToolbarItem(placement: .primaryAction) { ItemOrderMenu(place: place) }
            }
            SyncStatus()
            DetailsEdge()
        }
    }

    // The inbox and the projects, while they are in the order they were dragged into.
    private var isManual: Bool {
        Store.orderKey(for: place) != nil && store.itemOrder(for: place) == .manual
    }

    // Reminders also lists the days ahead, so it says how much is due by today.
    private func subtitle(_ sections: [ItemSection]) -> String {
        guard !sections.isEmpty else { return "" }
        let count = store.count(for: place)
        return place == .reminders ? "\(count) due" : "\(count) open"
    }

    private func drop(_ providers: [NSItemProvider], below above: Item?, above below: Item?) {
        Task {
            var texts: [String] = []
            var links: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.pendenzItem.identifier) {
                    if let item = await provider.itemRef().flatMap({ store.item($0.id) }) {
                        store.place(item, in: place, below: above, above: below)
                    }
                } else if provider.canLoadObject(ofClass: URL.self), let link = await provider.link() {
                    links.append(link)
                } else if let text = await provider.text() {
                    texts.append(text)
                }
            }
            store.addDropped(texts, links: links, in: place, below: above, above: below)
        }
    }

    private func rowStyle(in section: ItemSection) -> ItemRow.Style {
        switch place {
        // A section names its day, so a row only adds the time. Overdue mixes days. The
        // shorter date leaves room to say how an item repeats.
        case .reminders:
            ItemRow.Style(showsDay: section.id == Store.overdueSection, showsProject: true, namesRepeat: true)
        case .inbox, .project, .notes, .completed, .trash, .agents:
            ItemRow.Style(showsDay: true, showsProject: false)
        }
    }
}

struct SearchResultsView: View {
    @Environment(Store.self) private var store
    let query: String

    var body: some View {
        let results = store.search(query)
        ItemsList {
            ForEach(results) { item in
                ItemRow(item: item, style: ItemRow.Style(showsDay: true, showsProject: true))
                    .tag(item.id)
            }
        }
        .overlay {
            if results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search
            }
        }
        .toolbar { DetailsEdge() }
    }
}

// The menu that chooses how one list orders its items.
struct ItemOrderMenu: View {
    @Environment(Store.self) private var store
    let place: Place

    var body: some View {
        Menu("Sort Items", systemImage: "arrow.up.arrow.down") {
            Picker("Sort Items By", selection: order) {
                ForEach(ItemOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        }
        .help("Sort Items")
    }

    private var order: Binding<ItemOrder> {
        Binding {
            store.itemOrder(for: place)
        } set: { order in
            store.setItemOrder(order, for: place)
        }
    }
}

// Takes text dragged in from another app, where a list has no order to drop it into.
private struct TextDrop: ViewModifier {
    let isOn: Bool
    let add: ([String]) -> Void

    func body(content: Content) -> some View {
        if isOn {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { texts, _ in
                    add(texts)
                    return !texts.isEmpty
                }
        } else {
            content
        }
    }
}

private extension NSItemProvider {
    func text() async -> String? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    // A row of this app, as `ItemRef` writes itself.
    func itemRef() async -> ItemRef? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: UTType.pendenzItem.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(ItemRef.self, from: $0) })
            }
        }
    }

    func link() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { link, _ in continuation.resume(returning: link) }
        }
    }
}

// A list of items. On Mac and iPad a row is selected and the inspector shows it. On the iPhone
// a row is a button that opens the detail as a sheet, so no row stays highlighted.
struct ItemsList<Content: View>: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder let content: Content

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if sizeClass == .compact {
                List { content }
            } else {
                List(selection: $navigation.itemID) { content.macListRows() }
                    #if os(macOS)
                    // The Delete key, only while the list itself has the focus.
                    .onDeleteCommand {
                        if let id = navigation.itemID { navigation.trash(id, in: store) }
                    }
                    #endif
            }
        }
        .macListLook()
    }
}

// Shown in Reminders until the person has decided about notifications on this device, and only
// when there is a reminder to send.
private struct ReminderBanner: View {
    private var reminders: Reminders { .shared }

    static func isNeeded(in store: Store) -> Bool {
        Reminders.shared.access == .undecided
            && store.openItems.contains { $0.reminderDate.map { $0 > .now } ?? false }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reminders are off")
                Text("Turn on notifications to be reminded at the time you set.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Turn On") {
                Task { await reminders.askForAccess() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}

// What a list shows instead of rows: loading, the reason a first sync failed, or why it is empty.
struct EmptyState: View {
    @Environment(Store.self) private var store
    let place: Place

    var body: some View {
        if store.hasLoaded {
            switch place {
            case .reminders:
                ContentUnavailableView(
                    "No reminders", systemImage: Place.reminders.systemImage,
                    description: Text("Items with a date show up here."),
                )
            case .inbox:
                ContentUnavailableView("Inbox is empty", systemImage: Place.inbox.systemImage)
            case .project, .notes, .agents:
                ContentUnavailableView("No open items", systemImage: store.symbol(for: place))
            case .completed:
                ContentUnavailableView(
                    "Nothing completed yet", systemImage: Place.completed.systemImage,
                    description: Text("Items you complete show up here."),
                )
            case .trash:
                ContentUnavailableView(
                    "Trash is empty", systemImage: Place.trash.systemImage,
                    description: Text("Items and notes you move to the trash show up here."),
                )
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
}

// Shown in the toolbar only when the last sync failed while older data is on screen.
struct SyncStatus: ToolbarContent {
    @Environment(Store.self) private var store

    var body: some ToolbarContent {
        if store.hasLoaded, case .failed(let message) = store.phase {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.sync() }
                } label: {
                    Label(
                        "Sync failed. Try again.",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                    )
                }
                .help(store
                    .pendingCount == 0 ? message : "\(message) \(store.pendingCount) changes wait on this device.")
            }
        }
    }
}

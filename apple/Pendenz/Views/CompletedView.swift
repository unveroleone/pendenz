import SwiftUI

// Every finished item, the last one completed on top, a section per day. A row opens the item
// as in any list, and its circle opens the item again.
struct CompletedView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let sections = store.sections(for: .completed)
        ItemsList {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        ItemRow(item: item, style: ItemRow.Style(showsDay: true, showsProject: true))
                            .tag(item.id)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .animation(.default, value: sections.flatMap { $0.items.map(\.id) })
        .overlay {
            if sections.isEmpty {
                EmptyState(place: .completed)
            }
        }
        .navigationTitle("Completed")
        .refreshable { await store.sync() }
        .toolbar { SyncStatus() }
        // Read from disk when the list is first opened, not at launch.
        .task { store.loadCompleted() }
    }
}

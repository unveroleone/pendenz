import Foundation

// A list the app can show. On the iPhone these sit behind tabs, on iPad and Mac in the sidebar.
enum Place: Hashable {
    // Every item with a date, by day.
    case reminders
    case inbox
    case notes
    case project(String)
    // Every finished item, to look at and to open again.
    case completed
    // What was moved to the trash, items and notes, to look at and to put back.
    case trash

    var systemImage: String {
        switch self {
        case .reminders: "bell"
        case .inbox: "tray"
        case .notes: "note.text"
        case .project: "number"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        }
    }
}

// How the inbox or a project orders its items. Reminders is always by day.
nonisolated enum ItemOrder: String, CaseIterable, Identifiable, Sendable {
    // The order the rows were dragged into. The only one in which a row can be dragged.
    case manual
    // The soonest date first, then the items without one.
    case due
    // The item added last comes first.
    case added
    // The item changed last comes first.
    case edited
    case title

    var id: Self { self }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .due: "Due Date"
        case .added: "Date Added"
        case .edited: "Last Edited"
        case .title: "Title"
        }
    }
}

struct ItemSection: Identifiable {
    let id: String
    var title: String?
    var items: [Item]
}

import Foundation

extension WidgetList {
    nonisolated func title(in snapshot: WidgetSnapshot?) -> String {
        switch self {
        case .reminders: "Reminders"
        case .inbox: "Inbox"
        case .all: "All Items"
        case .project(let id): snapshot?.projects.first { $0.id == id }?.name ?? "Project"
        }
    }

    // The symbols the app draws these lists with.
    nonisolated func symbol(in snapshot: WidgetSnapshot?) -> String {
        switch self {
        case .reminders: "bell"
        case .inbox: "tray"
        case .all: "tray.full"
        case .project(let id): snapshot?.projects.first { $0.id == id }?.symbol ?? "number"
        }
    }
}

// What one widget draws at one moment: its list, worked out from the snapshot for that day.
nonisolated struct ListContent: Sendable {
    enum State: Sendable {
        // No snapshot: the device is not paired, or the app has not run since it was installed.
        case unpaired
        // Paired, and the first sync has not come through.
        case loading
        // The project this widget was set to was deleted.
        case missing
        case rows
    }

    var list: WidgetList
    var title: String
    var symbol: String
    var state: State
    // Every row of the list, in its order. The widget draws as many as fit.
    var rows: [WidgetItem]
    var today: Day
    var server: String

    init(list: WidgetList, snapshot: WidgetSnapshot?, at date: Date) {
        self.list = list
        title = list.title(in: snapshot)
        symbol = list.symbol(in: snapshot)
        today = Day(date)
        server = snapshot?.server ?? ""
        guard let snapshot else {
            state = .unpaired
            rows = []
            return
        }
        let today = today
        switch list {
        case .reminders:
            // What is due by today, the longest overdue first. The app's Reminders list goes on
            // with the days ahead; a widget that always has rows would never look done.
            rows = snapshot.items
                .filter { $0.due.map { $0.day <= today } ?? false }
                .sorted(by: Self.byDue)
        case .inbox:
            rows = snapshot.items.filter { $0.projectID == nil }
        case .project(let id):
            rows = snapshot.items.filter { $0.projectID == id }
        case .all:
            // The dated ones by their date, then the rest with the newest first.
            rows = snapshot.items.filter { $0.due != nil }.sorted(by: Self.byDue)
                + snapshot.items.filter { $0.due == nil }.sorted(by: Self.byAdded)
        }
        if case .project(let id) = list, !snapshot.projects.contains(where: { $0.id == id }) {
            state = snapshot.hasLoaded ? .missing : .loading
        } else {
            state = snapshot.hasLoaded || !rows.isEmpty ? .rows : .loading
        }
    }

    // What a widget says when the list is loaded and has no rows.
    var emptyText: String {
        switch list {
        case .reminders: "Nothing due today."
        case .inbox: "The inbox is empty."
        case .all, .project: "Nothing open."
        }
    }

    // For the widget gallery on a device that is not paired, and behind the placeholder.
    static func sample(_ list: WidgetList, at date: Date) -> ListContent {
        let today = Day(date)
        let snapshot = WidgetSnapshot(
            server: "", hasLoaded: true,
            items: [
                WidgetItem(id: 1, title: "Call the dentist", due: .day(today), isStarted: false, priority: 0),
                WidgetItem(id: 2, title: "Renew the passport", due: .day(today), isStarted: false, priority: 0),
                WidgetItem(id: 3, title: "Water the plants", due: .day(today), isStarted: false, priority: 0),
                WidgetItem(id: 4, title: "Book the train", due: .day(today), isStarted: false, priority: 0),
            ],
            projects: [],
        )
        var content = ListContent(list: list, snapshot: snapshot, at: date)
        content.rows = snapshot.items
        content.state = .rows
        return content
    }

    private static func byDue(_ lhs: WidgetItem, _ rhs: WidgetItem) -> Bool {
        let (left, right) = (lhs.due?.sortDate ?? .distantFuture, rhs.due?.sortDate ?? .distantFuture)
        return left == right ? lhs.id < rhs.id : left < right
    }

    // IDs grow with every new item. One the server has not answered for yet has an ID below
    // zero, and the lower of those is the newer.
    private static func byAdded(_ lhs: WidgetItem, _ rhs: WidgetItem) -> Bool {
        if (lhs.id < 0) != (rhs.id < 0) { return lhs.id < 0 }
        return lhs.id < 0 ? lhs.id < rhs.id : lhs.id > rhs.id
    }
}

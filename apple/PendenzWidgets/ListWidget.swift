import SwiftUI
import WidgetKit

// One list of open items, with a tick on every row. Which list is the widget's one setting.
struct ListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "List", intent: ListWidgetIntent.self, provider: ListProvider()) { entry in
            ListWidgetView(content: entry.content)
        }
        .configurationDisplayName("List")
        .description("The open items of a list, with a tick on every row.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

nonisolated struct ListEntry: TimelineEntry {
    let date: Date
    let content: ListContent
}

nonisolated struct ListProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> ListEntry {
        ListEntry(date: .now, content: .sample(.reminders, at: .now))
    }

    func snapshot(for configuration: ListWidgetIntent, in context: Context) async -> ListEntry {
        let list = Self.list(of: configuration)
        let content = ListContent(list: list, snapshot: WidgetFile.read(), at: .now)
        // The gallery shows what the widget is for, also before the device is paired.
        if context.isPreview, content.state != .rows || content.rows.isEmpty {
            return ListEntry(date: .now, content: .sample(list, at: .now))
        }
        return ListEntry(date: .now, content: content)
    }

    // The app asks for a new timeline whenever the rows change. In between only the day can
    // change what is due and what is overdue, so the second entry is the next midnight.
    func timeline(for configuration: ListWidgetIntent, in _: Context) async -> Timeline<ListEntry> {
        let list = Self.list(of: configuration)
        let snapshot = WidgetFile.read()
        let now = Date.now
        let midnight = Day(now).adding(days: 1).date()
        let entries = [now, midnight].map { ListEntry(
            date: $0,
            content: ListContent(list: list, snapshot: snapshot, at: $0),
        ) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private static func list(of configuration: ListWidgetIntent) -> WidgetList {
        configuration.list.flatMap { WidgetList(id: $0.id) } ?? .reminders
    }
}

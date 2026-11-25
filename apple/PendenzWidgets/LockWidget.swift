#if os(iOS)
import SwiftUI
import WidgetKit

// How many items a list has and the next one, for the lock screen. It shares the list
// widget's setting and timeline, so both read the same rows. The lock screen is for a
// glance: a tap opens the list, and the tick stays on the home screen.
struct LockWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Lock", intent: ListWidgetIntent.self, provider: ListProvider()) { entry in
            LockWidgetView(content: entry.content)
        }
        .configurationDisplayName("List")
        .description("How many items a list has, and the next one.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let content: ListContent

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(for: .widget) {
            if family == .accessoryCircular { AccessoryWidgetBackground() }
        }
        .widgetURL(WidgetLink.list(content.list).url)
    }

    private var hasRows: Bool {
        content.state == .rows && !content.rows.isEmpty
    }

    // MARK: The count

    // The list's symbol over the count, or a check mark once the list is done. It is the
    // whole circular widget and the left edge of the rectangular one. The list's name is
    // left out to give the room to the items; VoiceOver still says it.
    private var countMark: some View {
        VStack(spacing: 0) {
            Image(systemName: content.symbol)
                .font(.caption)
                .widgetAccentable()
            switch content.state {
            case .rows where hasRows:
                Text(countText)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            case .rows:
                Image(systemName: "checkmark")
                    .font(.title3.weight(.semibold))
            case .loading, .unpaired, .missing:
                Text(verbatim: "–")
                    .font(.title2.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(content.title), \(spokenState)")
    }

    // MARK: Circular

    private var circular: some View {
        countMark
    }

    // MARK: Rectangular

    // The count on the left, the next items beside it, as many as fit.
    private var rectangular: some View {
        HStack(alignment: .center, spacing: 8) {
            countMark
                .frame(minWidth: 24)
            Group {
                if hasRows {
                    ViewThatFits(in: .vertical) {
                        rows(3)
                        rows(2)
                        rows(1)
                    }
                    .privacySensitive()
                } else {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rows(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(content.rows.prefix(count)) { item in
                LockWidgetRow(item: item, content: content)
            }
        }
    }

    // MARK: Inline

    // One line beside the date: the count and the next title.
    private var inline: some View {
        Label {
            if hasRows, let next = content.rows.first {
                Text("\(countText) · \(next.title)")
                    .privacySensitive()
            } else {
                Text(message)
            }
        } icon: {
            Image(systemName: content.symbol)
        }
    }

    // MARK: Texts

    private var countText: String {
        content.rows.count > 99 ? "99+" : content.rows.count.formatted()
    }

    private var spokenCount: String {
        let count = content.rows.count
        if content.list == .reminders {
            return count == 1 ? "1 item due" : "\(count) items due"
        }
        return count == 1 ? "1 open item" : "\(count) open items"
    }

    private var spokenState: String {
        content.state == .rows ? spokenCount : message
    }

    private var message: String {
        switch content.state {
        case .rows: content.emptyText
        case .loading, .unpaired: "Open Pendenz to load your items."
        case .missing: "This project was deleted. Edit the widget."
        }
    }
}

// One item: its title, and its date where the list does not already say it.
private struct LockWidgetRow: View {
    let item: WidgetItem
    let content: ListContent

    private var isOverdue: Bool {
        item.due.map { $0.day < content.today } ?? false
    }

    // The date goes first when the title does not fit beside it: the overdue icon still
    // says what matters, and a title cut to a few letters says nothing.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(showsDue: true)
            line(showsDue: false)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private func line(showsDue: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            // Overdue is said by the icon, since the lock screen draws in one color.
            if isOverdue {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .accessibilityLabel("Overdue")
            }
            if item.priority >= 3 {
                Text(item.priority == 4 ? "!!" : "!")
                    .bold()
                    .accessibilityLabel(item.priority == 4 ? "Urgent" : "High priority")
            }
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsDue, let due {
                Text(due)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // Reminders holds what is due by today, so a row there names only its time, or its
    // day when it is overdue.
    private var due: String? {
        let showsDay = content.list != .reminders || isOverdue
        return item.due.flatMap { DueText.label(for: $0, today: content.today, showsDay: showsDay) }
    }
}

#Preview("Circular", as: .accessoryCircular) {
    LockWidget()
} timeline: {
    ListEntry(date: .now, content: .sample(.reminders, at: .now))
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LockWidget()
} timeline: {
    ListEntry(date: .now, content: .sample(.reminders, at: .now))
}

#Preview("Inline", as: .accessoryInline) {
    LockWidget()
} timeline: {
    ListEntry(date: .now, content: .sample(.reminders, at: .now))
}
#endif

import AppIntents
import SwiftUI
import WidgetKit

struct ListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let content: ListContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch content.state {
            case .rows where !content.rows.isEmpty:
                rows
            case .rows:
                message(content.emptyText)
            case .loading:
                message("Open Pendenz to load your items.")
            case .unpaired:
                message("Open Pendenz to set it up.")
            case .missing:
                message("This project was deleted. Edit the widget to choose a list.")
            }
        }
        .containerBackground(.background, for: .widget)
        // A tap next to the rows opens the list.
        .widgetURL(WidgetLink.list(content.list).url)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: content.symbol)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text(content.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if content.state == .rows {
                Text(content.rows.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(content.rows.count == 1 ? "1 item" : "\(content.rows.count) items")
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // As many rows as the widget has room for, at the text size in use: the first candidate
    // that fits is drawn. A long title gets a second line only where that costs no row. The
    // count in the header says how many items there are in all.
    private var rows: some View {
        let counts = (1 ... min(content.rows.count, mostRows)).reversed()
        let candidates = counts.flatMap { count in [2, 1].map { Candidate(count: count, lines: $0) } }
        return ViewThatFits(in: .vertical) {
            ForEach(candidates) { candidate in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(content.rows.prefix(candidate.count)) { item in
                        ListWidgetRow(item: item, content: content, layout: layout, lines: candidate.lines)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Candidate: Identifiable {
        let count: Int
        let lines: Int

        var id: Int { count * 2 + lines }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var layout: ListWidgetRow.Layout {
        switch family {
        case .systemSmall: .narrow
        case .systemLarge: .tall
        default: .wide
        }
    }

    // More than any size shows, so the room decides and not this number.
    private var mostRows: Int {
        family == .systemLarge ? 16 : 6
    }
}

struct ListWidgetRow: View {
    enum Layout {
        // The small widget: the title alone, and a mark when the item is overdue.
        case narrow
        // The date behind the title.
        case wide
        // As wide, with more room between the rows.
        case tall
    }

    let item: WidgetItem
    let content: ListContent
    let layout: Layout
    // How many lines a title may take.
    let lines: Int

    private var isNarrow: Bool {
        layout == .narrow
    }

    // The room above and below a line of text. With it a row of one line is 24 points tall in
    // the small and the medium widget, which then hold four of them, and 28 in the large one.
    private var inset: CGFloat {
        switch layout {
        case .narrow: 3
        case .wide: 2
        case .tall: 4
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if item.isSynced {
                Button(intent: CompleteItemIntent(item: item, server: content.server)) {
                    circle
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(item.title)")
                Link(destination: WidgetLink.item(item.id).url) {
                    text
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the item")
            } else {
                // Added a moment ago and not on the server yet. The row gets its tick and its
                // link with the number the server gives the item.
                circle
                    .opacity(0.5)
                    .accessibilityHidden(true)
                text
                    .accessibilityElement(children: .combine)
            }
        }
        // The circle lines up with the header's symbol, not with its own tap area.
        .padding(.leading, isNarrow ? -3 : -4)
    }

    private var circle: some View {
        Image(systemName: item.isStarted ? "smallcircle.filled.circle" : "circle")
            .font(isNarrow ? .callout : .body)
            .foregroundStyle(.secondary)
            .widgetAccentable()
            // The height of a line and some width around the circle take the tap.
            .frame(width: isNarrow ? 24 : 28)
            .padding(.vertical, inset)
            .contentShape(Rectangle())
    }

    private var text: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            title
            Spacer(minLength: 0)
            due
        }
        .padding(.vertical, inset)
        .contentShape(Rectangle())
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if item.priority >= 3 {
                Text(item.priority == 4 ? "!!" : "!")
                    .bold()
                    .accessibilityLabel(item.priority == 4 ? "Urgent" : "High priority")
            }
            Text(item.title)
                .lineLimit(lines)
        }
        .font(isNarrow ? .footnote : .subheadline)
    }

    private var isOverdue: Bool {
        item.due.map { $0.day < content.today } ?? false
    }

    @ViewBuilder
    private var due: some View {
        // Reminders holds what is due today, so only an overdue row names its day there.
        let showsDay = content.list != .reminders || isOverdue
        let text = item.due.flatMap { DueText.label(for: $0, today: content.today, showsDay: showsDay) }
        if isNarrow {
            if isOverdue {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Overdue")
            }
        } else if let text {
            // Overdue is said by the icon and the label too, not by the red alone.
            Label(text, systemImage: "exclamationmark.circle")
                .labelStyle(DueLabelStyle(showsIcon: isOverdue))
                .font(.caption)
                .foregroundStyle(isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .layoutPriority(1)
                .accessibilityLabel(isOverdue ? "Overdue, \(text)" : "Due \(text)")
        }
    }
}

// The date of a row, with its icon only where the icon says something.
private struct DueLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

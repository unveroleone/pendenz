import SwiftUI

struct ItemRow: View {
    struct Style {
        var showsDay: Bool
        var showsProject: Bool
        // Says how an item repeats in words. Without it the repeat is an icon.
        var namesRepeat = false
    }

    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    let item: Item
    let style: Style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                store.toggleDone(item)
            } label: {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isDone ? .primary : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    // A 44 point target around the circle without making the row taller.
                    .padding(11)
                    .contentShape(Rectangle())
                    .padding(-11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Completed. Undo" : "Complete")
            if sizeClass == .compact {
                Button {
                    navigation.itemID = item.id
                } label: {
                    text
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the item")
            } else {
                text
            }
        }
        .padding(.vertical, 4)
        .modifier(ItemActions(item: item))
        // Onto a sidebar entry: Reminders sets today's date, the inbox and the projects file it.
        .draggable(ItemRef(id: item.id))
    }

    private var text: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                title
                details
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }

    private var isDone: Bool {
        item.status == .done
    }

    private var symbol: String {
        switch item.status {
        case .done: "checkmark.circle.fill"
        case .doing: "smallcircle.filled.circle"
        case .todo: "circle"
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if item.priority >= 3 {
                Text(item.priority == 4 ? "!!" : "!")
                    .bold()
                    .accessibilityLabel(item.priority == 4 ? "Urgent" : "High priority")
            }
            Text(item.title)
                .lineLimit(2)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var details: some View {
        let due: (Due, String)? = item.dueAt.flatMap { due in
            DueText.label(for: due, today: store.today, showsDay: style.showsDay).map { (due, $0) }
        }
        let project = style.showsProject ? store.projectName(item.projectId) : nil
        let ticked = item.checklist.count { $0.done }
        let images = item.images.count + (store.waitingImages[item.id]?.count ?? 0)
        let hasDetails = due != nil || project != nil || item.repeatRule != nil
            || !item.checklist.isEmpty || !item.description.isEmpty || item.hiddenFromAgents || images > 0
        if hasDetails {
            HStack(spacing: 10) {
                if let (due, text) = due {
                    let overdue = due.day < store.today
                    // Overdue is marked by the icon and the label too, not by the red alone.
                    Label(text, systemImage: overdue ? "exclamationmark.circle" : "calendar")
                        .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(overdue ? "Overdue, \(text)" : "Due \(text)")
                }
                if let rule = item.repeatRule {
                    let words = RepeatText.describe(rule)
                    if style.namesRepeat {
                        Label(words, systemImage: "repeat")
                            .accessibilityLabel("Repeats \(words.lowercased())")
                    } else {
                        Label(words, systemImage: "repeat")
                            .labelStyle(.iconOnly)
                    }
                }
                if !item.checklist.isEmpty {
                    Label("\(ticked)/\(item.checklist.count)", systemImage: "checklist")
                        .accessibilityLabel("\(ticked) of \(item.checklist.count) steps done")
                }
                if !item.description.isEmpty {
                    Label("Has notes", systemImage: "text.alignleft")
                        .labelStyle(.iconOnly)
                }
                if images > 0 {
                    Label(images == 1 ? "1 image" : "\(images) images", systemImage: "photo")
                        .labelStyle(.iconOnly)
                }
                if item.hiddenFromAgents {
                    Label("Hidden from agents", systemImage: "eye.slash")
                        .labelStyle(.iconOnly)
                }
                if let project {
                    Label(project, systemImage: item.projectId.flatMap(store.project)?.symbol ?? Project.defaultSymbol)
                        .layoutPriority(-1)
                }
            }
            .labelStyle(.compact)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// An icon and its text closer together than the default label, for the line under a title.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

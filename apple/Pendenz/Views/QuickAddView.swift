import SwiftUI

// One field to capture an item. Return adds it and leaves the field ready for the next one.
// Dates, repeats and a #project in the text are understood and shown as chips before saving.
struct QuickAddView: View {
    @Environment(Store.self) private var store
    let place: Place
    // Called after an item was added, which here means queued in the outbox.
    var onAdd: (() -> Void)?

    @State private var title = ""
    // Kinds the person switched off by tapping their chip, because the word was meant literally.
    @State private var ignored: Set<QuickAddParser.Kind> = []
    @FocusState private var isFocused: Bool

    private var parsed: QuickAddParser.Result {
        QuickAddParser.parse(title, now: .now, projects: store.projects, ignoring: ignored)
    }

    private var prompt: String {
        switch place {
        case .reminders: "New reminder for today"
        case .project: "New item in \(store.title(for: place))"
        case .inbox, .notes, .completed, .trash, .agents: "New item in Inbox"
        }
    }

    var body: some View {
        let parsed = parsed
        // Two rows and nothing below them: the field with its button, then what was understood.
        // On the iPhone the sheet is as tall as this, so it ends where the keyboard begins.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField(prompt, text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { save(parsed) }
                addButton(parsed)
            }
            chips(parsed)
        }
        .padding(.horizontal, 20)
        // Room for the sheet's grabber above the field.
        .padding(.top, 24)
        .padding(.bottom, 12)
        .onAppear { isFocused = true }
        .onChange(of: title) { _, text in
            // A cleared field starts over, also with what was switched off.
            if text.isEmpty { ignored = [] }
        }
    }

    // Drawn here, not by a system style: a prominent button that is switched off came out as a
    // black shape on the sheet. Filled with the label color when there is something to add,
    // so its text takes the background color to stay readable in light and dark.
    private func addButton(_ parsed: QuickAddParser.Result) -> some View {
        let canAdd = !parsed.title.isEmpty
        return Button {
            save(parsed)
        } label: {
            Text("Add")
                .fontWeight(.semibold)
                .foregroundStyle(canAdd ? AnyShapeStyle(.background) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(canAdd ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: .capsule)
                // A 44 point target around the shape.
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .animation(.default, value: canAdd)
    }

    // What was understood from the text. Tapping a chip puts its words back into the title.
    @ViewBuilder
    private func chips(_ parsed: QuickAddParser.Result) -> some View {
        if parsed.kinds.isEmpty {
            Text("Try “tomorrow 9”, “every Monday” or #project")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(minHeight: 28)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(parsed.kinds, id: \.self) { kind in
                        Button {
                            ignored.insert(kind)
                        } label: {
                            HStack(spacing: 4) {
                                Label(label(for: kind, in: parsed), systemImage: icon(for: kind))
                                Image(systemName: "xmark")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityHint("Keeps these words in the title instead")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 28)
        }
    }

    private func label(for kind: QuickAddParser.Kind, in parsed: QuickAddParser.Result) -> String {
        switch kind {
        case .due: parsed.due.flatMap { DueText.label(for: $0, today: store.today, showsDay: true) } ?? ""
        case .repeats: parsed.repeatRule.map(RepeatText.describe) ?? ""
        case .project: store.projectName(parsed.projectId) ?? ""
        }
    }

    private func icon(for kind: QuickAddParser.Kind) -> String {
        switch kind {
        case .due: "calendar"
        case .repeats: "repeat"
        case .project: Place.project("").systemImage
        }
    }

    private func save(_ parsed: QuickAddParser.Result) {
        guard !parsed.title.isEmpty else { return }
        store.add(store.newItem(parsed, hidden: false, in: place))
        title = ""
        ignored = []
        isFocused = true
        onAdd?()
    }
}

// The floating button on the iPhone. This is the one place the app draws its own glass.
struct QuickAddButton: View {
    let action: () -> Void
    // The room a list leaves below its last row, so that row scrolls out from under the button.
    static let clearance: CGFloat = 72

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("New item")
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}

extension FocusedValues {
    // Whether quick add is open in the front window. The New Item menu command sets it.
    @Entry var isAddingItem: Binding<Bool>?
    // The front window's navigation, for the commands that act on its list and its item.
    @Entry var navigation: Navigation?
}

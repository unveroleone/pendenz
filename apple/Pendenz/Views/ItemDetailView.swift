import SwiftUI

// Everything about one item, and the place where it is edited. Text is saved when its field is
// left, every other control saves at once.
struct ItemDetailView: View {
    private enum Field: Hashable {
        case title, notes, line(String), newLine
    }

    @Environment(Store.self) private var store
    let itemID: Int
    let onClose: () -> Void

    @FocusState private var focus: Field?
    @State private var title = ""
    @State private var notes = ""
    @State private var lines: [ChecklistLine] = []
    @State private var newLine = ""
    // The question behind the detail's own trash button.

    var body: some View {
        if let item = store.item(itemID), !item.trashed {
            form(item)
        } else {
            ContentUnavailableView("This item is gone", systemImage: "tray")
        }
    }

    private func form(_ item: Item) -> some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        store.toggleDone(item)
                    } label: {
                        Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(item.status == .done ? .primary : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.status == .done ? "Completed. Undo" : "Complete")
                    TextField("Title", text: $title, prompt: Text("Title"), axis: .vertical)
                        .font(.title3.weight(.semibold))
                        .focused($focus, equals: .title)
                        .labelsHidden()
                }
                TextField("Notes", text: $notes, prompt: Text("Notes"), axis: .vertical)
                    .lineLimit(2 ... 12)
                    .focused($focus, equals: .notes)
                    .labelsHidden()
            }
            Section("Steps") {
                ForEach($lines) { $line in
                    HStack(spacing: 10) {
                        Button {
                            line.done.toggle()
                            saveLines()
                        } label: {
                            Image(systemName: line.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(line.done ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(line.done ? "Done. Undo" : "Mark step as done")
                        TextField("Step", text: $line.text, prompt: Text("Step"))
                            .focused($focus, equals: .line(line.id))
                            .labelsHidden()
                            .strikethrough(line.done)
                            .foregroundStyle(line.done ? .secondary : .primary)
                            .onSubmit { focus = .newLine }
                    }
                }
                .onDelete { offsets in
                    lines.remove(atOffsets: offsets)
                    saveLines()
                }
                if lines.count < Item.stepCount {
                    TextField("Add a step", text: $newLine, prompt: Text("Add a step"))
                        .focused($focus, equals: .newLine)
                        .labelsHidden()
                        .onSubmit(addLine)
                }
            }
            ItemAttachmentsSection(item: item)
            Section {
                Toggle("Date", isOn: hasDate(item))
                if let due = item.dueAt {
                    DatePicker("Day", selection: day(item, due), displayedComponents: .date)
                    Toggle("Time", isOn: hasTime(item, due))
                    if due.time != nil {
                        DatePicker("At", selection: time(item, due), displayedComponents: .hourAndMinute)
                    }
                    Picker("Repeat", selection: repeatRule(item)) {
                        ForEach(repeatChoices(item), id: \.self) { rule in
                            Text(rule.isEmpty ? "Never" : RepeatText.describe(rule)).tag(rule)
                        }
                    }
                }
            }
            Section {
                // The due time is when the item is due and when it reminds. This moves the
                // reminder, usually to before: the item then says nothing at its due time.
                Toggle(item.dueAt?.time == nil ? "Reminder" : "Remind me earlier", isOn: hasReminder(item))
                if let remindAt = item.remindAt {
                    DatePicker("Remind me", selection: reminder(remindAt))
                }
            } footer: {
                if let due = item.dueAt?.time {
                    if item.remindAt == nil {
                        Text("You are reminded at the due time, \(due.formatted(date: .omitted, time: .shortened)).")
                    } else {
                        Text("You are reminded then, not at the due time.")
                    }
                }
            }
            Section {
                Picker("Project", selection: project(item)) {
                    Text("Inbox").tag(String?.none)
                    ForEach(store.projects) { project in
                        Text(project.name).tag(String?.some(project.id))
                    }
                }
                Picker("Priority", selection: priority(item)) {
                    ForEach(
                        Array(["None", "Low", "Medium", "High", "Urgent"].enumerated()),
                        id: \.offset,
                    ) { level, name in
                        Text(name).tag(level)
                    }
                }
            }
            Section {
                if let link = item.sourceUrl.flatMap(URL.init(string:)) {
                    Link(destination: link) {
                        Label(link.host() ?? "Open link", systemImage: "link")
                    }
                }
                if item.id > 0 {
                    LabeledContent("Number", value: "P-\(item.id)")
                } else {
                    LabeledContent("Number", value: "Not sent yet")
                }
                Toggle("Hide from agent", isOn: hidden(item))
                Button("Move to Trash", systemImage: "trash", role: .destructive, action: trash)
                    .formAction(.red)
            }
        }
        .formStyle(.grouped)
        // The app tint is black or white, which hides the knob of a switch that is on.
        .tint(Color(.selection))
        .modifier(ItemAttachmentDrop(itemID: itemID))
        .onAppear { load(item) }
        .onDisappear(perform: saveText)
        .onChange(of: focus) { old, _ in save(old) }
        .onChange(of: title) { _, text in
            // Return ends the title instead of starting a second line.
            if text.contains("\n") {
                title = text.replacingOccurrences(of: "\n", with: " ")
                focus = nil
            }
        }
        // A change that arrives from elsewhere shows up, unless that field is being typed in.
        .onChange(of: item.title) { _, text in
            if focus != .title { title = text }
        }
        .onChange(of: item.description) { _, text in
            if focus != .notes { notes = text }
        }
        .onChange(of: item.checklist) { _, checklist in
            if !isEditingLines { lines = checklist }
        }
    }

    private func trash() {
        store.update(itemID, ItemPatch(trashed: true))
        onClose()
    }

    // MARK: Text

    private var isEditingLines: Bool {
        switch focus {
        case .line, .newLine: true
        default: false
        }
    }

    private func load(_ item: Item) {
        title = item.title
        notes = item.description
        lines = item.checklist
    }

    private func save(_ field: Field?) {
        guard let item = store.item(itemID) else { return }
        switch field {
        case .title:
            let text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").cut(to: Item.titleLimit)
            // An item needs a title. An emptied field goes back to what it was.
            if text.isEmpty {
                title = item.title
            } else if text != item.title {
                store.update(itemID, ItemPatch(title: text))
            }
        case .notes:
            let text = notes.trimmingCharacters(in: .whitespacesAndNewlines).cut(to: Item.descriptionLimit)
            if text != item.description {
                store.update(itemID, ItemPatch(description: text))
            }
        case .line, .newLine:
            if !isEditingLines { saveLines() }
        case nil:
            break
        }
    }

    private func saveText() {
        save(.title)
        save(.notes)
        saveLines()
    }

    // The checklist is saved as a whole. Lines without text are left out, and a step that was
    // typed into "Add a step" without Return is taken along.
    private func saveLines() {
        guard let item = store.item(itemID) else { return }
        takeNewLine()
        var kept: [ChecklistLine] = []
        for var line in lines.prefix(Item.stepCount) {
            line.text = line.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").cut(to: Item.stepLimit)
            if !line.text.isEmpty { kept.append(line) }
        }
        if kept != item.checklist {
            store.update(itemID, ItemPatch(checklist: kept))
        }
    }

    private func takeNewLine() {
        let text = newLine.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, lines.count < Item.stepCount else { return }
        lines.append(ChecklistLine(id: String(UUID().uuidString.prefix(8)).lowercased(), text: text, done: false))
        newLine = ""
    }

    private func addLine() {
        guard !newLine.trimmingCharacters(in: .whitespaces).isEmpty else {
            focus = nil
            return
        }
        saveLines()
        focus = .newLine
    }

    // MARK: Date, reminder, repeat

    private func setDue(_ due: Due) {
        store.update(itemID, ItemPatch(dueAt: .set(due), dueTz: TimeZone.current.identifier))
    }

    private func hasDate(_ item: Item) -> Binding<Bool> {
        Binding {
            item.dueAt != nil
        } set: { isOn in
            if isOn {
                setDue(.day(store.today))
            } else {
                // A repeat cannot stay without a date.
                store.update(itemID, ItemPatch(dueAt: .clear, repeatRule: item.repeatRule == nil ? nil : .clear))
            }
        }
    }

    private func day(_: Item, _ due: Due) -> Binding<Date> {
        Binding {
            due.day.date()
        } set: { date in
            let day = Day(date)
            if let time = due.time {
                let clock = Day.calendar.dateComponents([.hour, .minute], from: time)
                setDue(.time(day.date(hour: clock.hour ?? 9, minute: clock.minute ?? 0)))
            } else {
                setDue(.day(day))
            }
        }
    }

    private func hasTime(_: Item, _ due: Due) -> Binding<Bool> {
        Binding {
            due.time != nil
        } set: { isOn in
            setDue(isOn ? .time(due.day.date(hour: 9, minute: 0)) : .day(due.day))
        }
    }

    private func time(_: Item, _ due: Due) -> Binding<Date> {
        Binding {
            due.time ?? due.day.date(hour: 9, minute: 0)
        } set: { date in
            let clock = Day.calendar.dateComponents([.hour, .minute], from: date)
            setDue(.time(due.day.date(hour: clock.hour ?? 9, minute: clock.minute ?? 0)))
        }
    }

    // The usual rules, and the item's own rule when it is another one.
    private func repeatChoices(_ item: Item) -> [String] {
        var rules = ["", "FREQ=DAILY", "FREQ=WEEKLY", "FREQ=WEEKLY;INTERVAL=2", "FREQ=MONTHLY", "FREQ=YEARLY"]
        if let rule = item.repeatRule, !rules.contains(rule) {
            rules.append(rule)
        }
        return rules
    }

    private func repeatRule(_ item: Item) -> Binding<String> {
        Binding {
            item.repeatRule ?? ""
        } set: { rule in
            store.update(itemID, ItemPatch(repeatRule: rule.isEmpty ? .clear : .set(rule)))
        }
    }

    private func hasReminder(_ item: Item) -> Binding<Bool> {
        Binding {
            item.remindAt != nil
        } set: { isOn in
            guard isOn else {
                store.update(itemID, ItemPatch(remindAt: .clear))
                return
            }
            // Starts an hour before a due time, at nine on a due day, or tomorrow at nine.
            let start = item.dueAt?.time?.addingTimeInterval(-3600)
                ?? (item.dueAt?.day ?? store.today.adding(days: 1)).date(hour: 9, minute: 0)
            store.update(itemID, ItemPatch(remindAt: .set(max(start, Date.now.addingTimeInterval(300)))))
        }
    }

    private func reminder(_ remindAt: Date) -> Binding<Date> {
        Binding {
            remindAt
        } set: { date in
            store.update(itemID, ItemPatch(remindAt: .set(date)))
        }
    }

    // MARK: Project, priority, hidden

    private func project(_ item: Item) -> Binding<String?> {
        Binding {
            item.projectId
        } set: { id in
            store.update(itemID, ItemPatch(projectId: id.map { .set($0) } ?? .clear))
        }
    }

    private func priority(_ item: Item) -> Binding<Int> {
        Binding {
            item.priority
        } set: { level in
            store.update(itemID, ItemPatch(priority: level))
        }
    }

    private func hidden(_ item: Item) -> Binding<Bool> {
        Binding {
            item.hiddenFromAgents
        } set: { isHidden in
            store.update(itemID, ItemPatch(hiddenFromAgents: isHidden))
        }
    }
}

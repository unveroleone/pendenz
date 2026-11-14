import SwiftUI

// The sheet for a new project, and for the name and icon of an existing one.
struct ProjectEditorView: View {
    @Environment(Store.self) private var store
    @Environment(Navigation.self) private var navigation
    let target: ProjectEditor

    @State private var name = ""
    @State private var symbol = Project.defaultSymbol
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool

    private var projectID: String? {
        if case .edit(let id) = target { id } else { nil }
    }

    private var trimmedName: String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var isNameTaken: Bool {
        store.isProjectNameTaken(trimmedName, except: projectID)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isNameTaken && trimmedName.unicodeScalars.count <= Project.nameLimit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("project-name")
                } footer: {
                    if isNameTaken {
                        // Said in words and with an icon, not by a color.
                        Label("A project with this name already exists.", systemImage: "exclamationmark.circle")
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(Project.symbols, id: \.name) { choice in
                            ProjectSymbolButton(
                                symbol: choice.name, label: choice.label, isSelected: choice.name == symbol,
                            ) {
                                symbol = choice.name
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let projectID {
                    Section {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Text("Delete Project")
                                .frame(maxWidth: .infinity)
                        }
                        .formAction(.red)
                        .accessibilityIdentifier("project-delete")
                        .modifier(ProjectDeleteQuestion(
                            place: .project(projectID), isPresented: $isConfirmingDelete, onDelete: close,
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(projectID == nil ? "New Project" : "Edit Project")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(projectID == nil ? "Add" : "Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(width: 400, height: projectID == nil ? 440 : 500)
        #endif
        .onAppear(perform: load)
        .onChange(of: name) { _, text in
            // The server counts Unicode scalars, and one emoji can be several of them.
            var kept = text
            while kept.unicodeScalars.count > Project.nameLimit { kept.removeLast() }
            if kept != text { name = kept }
        }
    }

    private func load() {
        if let project = projectID.flatMap(store.project) {
            name = project.name
            symbol = project.symbol
        } else {
            isNameFocused = true
        }
    }

    private func save() {
        guard canSave else { return }
        if let projectID {
            guard let project = store.project(projectID) else { return close() }
            store.updateProject(
                projectID,
                ProjectPatch(
                    name: trimmedName == project.name ? nil : trimmedName,
                    icon: symbol == project.symbol ? nil : symbol,
                ),
            )
        } else {
            let id = store.addProject(name: trimmedName, icon: symbol == Project.defaultSymbol ? nil : symbol)
            // The new project opens, ready for its first item.
            navigation.place = .project(id)
        }
        close()
    }

    private func close() {
        navigation.projectEditor = nil
    }
}

// The question before a project is deleted, which cannot be taken back. It says where the
// project's items and notes go.
struct ProjectDeleteQuestion: ViewModifier {
    @Environment(Store.self) private var store
    // Only a project is asked about. On any other list the question never shows.
    let place: Place
    @Binding var isPresented: Bool
    var onDelete: () -> Void = {}

    private var projectID: String? {
        if case .project(let id) = place { id } else { nil }
    }

    private var title: String {
        "Delete \u{201C}\(store.title(for: place))\u{201D}?"
    }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            Button("Delete Project", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    private func delete() {
        guard let projectID else { return }
        // The window leaves the project by itself: see `RootView`.
        store.deleteProject(projectID)
        onDelete()
    }

    private var message: String {
        guard let projectID else { return "" }
        let items = store.count(for: place)
        let notes = store.notes.count { $0.projectId == projectID }
        var parts: [String] = []
        if items > 0 {
            parts
                .append(items == 1 ? "Its open item moves to the inbox." : "Its \(items) open items move to the inbox.")
        }
        if notes > 0 {
            parts
                .append(notes == 1 ? "Its note stays in Notes, without a project." :
                    "Its \(notes) notes stay in Notes, without a project.")
        }
        return parts.isEmpty ? "It has no open items and no notes." : parts.joined(separator: " ")
    }
}

// One icon of the grid. The chosen one is filled with the label color and drawn in its
// opposite, which reads in light and dark without a color of its own. The opposite is named
// here: inside a form the background style is not the one behind the row.
private struct ProjectSymbolButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(isSelected ? AnyShapeStyle(colorScheme == .dark ? Color.black : Color.white) :
                    AnyShapeStyle(.primary))
                .background(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

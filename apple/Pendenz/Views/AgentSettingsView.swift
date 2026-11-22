import SwiftUI

// Settings, Agents: whether the Agents screen shows, the agents with a working token, and a
// one-time code to connect a new one. Asked from the server directly, like the devices.
struct AgentSettingsView: View {
    @Environment(Session.self) private var session
    @AppStorage(AgentsVisibility.key) private var visibility = AgentsVisibility.automatic
    @State private var isConnecting = false
    // The agent the question is about. It stays after the answer, so the title keeps its name
    // while the alert fades.
    @State private var revokeCandidate: AgentEntry?
    @State private var isConfirmingRevoke = false
    @State private var failure: String?

    private var connected: [AgentEntry] {
        session.agents?.connected ?? []
    }

    private var reportingCount: Int {
        session.agents?.reporting.count ?? 0
    }

    var body: some View {
        Form {
            Section {
                Picker("Show Agents", selection: $visibility) {
                    ForEach(AgentsVisibility.allCases) { Text($0.title).tag($0) }
                }
                if reportingCount > 1 {
                    NavigationLink("Order") { AgentOrderView() }
                }
            } footer: {
                Text("Agents shows what your agents do and cost. Automatic shows it once an agent has sent a report.")
            }
            Section {
                ForEach(connected) { agent in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name)
                            Text(detail(for: agent))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        Button("Revoke", role: .destructive) {
                            revokeCandidate = agent
                            isConfirmingRevoke = true
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
                if connected.isEmpty {
                    Text("No agent is connected.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connected agents")
            } footer: {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            if session.store?.settings?.hasEnergyPrice == true {
                EnergyPriceSection()
            }
            Section {
                Button("Connect an Agent") { isConnecting = true }
            } footer: {
                Text(
                    "Makes a one-time code and shows the commands to run on the agent's machine. They install Pendenz there, connect it and send a report every two minutes.",
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .settingsPage()
        // Asked again while open, so the Order row shows once a second agent reports.
        .task {
            // Whether the server has the price, and its value, as it holds them now.
            _ = try? await session.serverSettings()
            await session.agents?.refresh()
            await session.agents?.watch()
        }
        .sheet(isPresented: $isConnecting) {
            NavigationStack {
                ConnectAgentView()
            }
            #if os(macOS)
            .frame(width: 520, height: 520)
            #endif
        }
        .alert(
            "Revoke \u{201C}\(revokeCandidate?.name ?? "")\u{201D}?", isPresented: $isConfirmingRevoke,
            presenting: revokeCandidate,
        ) { agent in
            Button("Revoke", role: .destructive) { revoke(agent) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its token stops working and its report is removed. What it wrote stays.")
        }
    }

    private func detail(for agent: AgentEntry) -> String {
        let access = Self.access(agent.scopes)
        guard let used = agent.lastUsedAt else { return access }
        return "\(access) · active \(used.formatted(.relative(presentation: .named)))"
    }

    // What an agent's tokens allow, in words: whether it reads or changes items, and whether it
    // sends a status report.
    static func access(_ scopes: [String]) -> String {
        let items = scopes.contains("write") ? "Changes items" : scopes.contains("read") ? "Reads items" : nil
        let reports = scopes.contains("report") ? "sends its status" : nil
        switch (items, reports) {
        case let (items?, reports?): return "\(items), \(reports)"
        case let (items?, nil): return items
        case (nil, _): return "Sends its status"
        }
    }

    private func revoke(_ agent: AgentEntry) {
        Task {
            do {
                failure = nil
                try await session.revoke(agent: agent.id)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// The order of the agents at the top of the Agents screen, kept on this device. Dragged by its
// handles; an agent that starts to report later is added at the end.
private struct AgentOrderView: View {
    @Environment(Session.self) private var session
    @AppStorage(AgentBoard.orderKey) private var order = ""

    private var agents: [AgentEntry] {
        session.agents?.reporting(in: order) ?? []
    }

    var body: some View {
        // One reading for the rows and the moves, so a list that changes while a row is
        // dragged never moves another agent.
        let shown = agents
        let names = Dictionary(grouping: shown, by: \.name)
        List {
            Section {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                        // Two agents of one name are told apart by their IDs.
                        if names[agent.name, default: []].count > 1 {
                            Text(agent.id)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    // The same moves without a drag: for VoiceOver, and in the menu of the row.
                    .accessibilityAction(named: "Move Up") { move(shown, index, by: -1) }
                    .accessibilityAction(named: "Move Down") { move(shown, index, by: 1) }
                    .contextMenu {
                        Button("Move Up", systemImage: "arrow.up") { move(shown, index, by: -1) }
                            .disabled(index == 0)
                        Button("Move Down", systemImage: "arrow.down") { move(shown, index, by: 1) }
                            .disabled(index == shown.count - 1)
                    }
                }
                .onMove { source, destination in
                    var ids = shown.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    order = ids.joined(separator: ",")
                }
            } footer: {
                Text(
                    "Drag the agents into the order the Agents screen shows them in. The order is kept on this device.",
                )
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("Order")
        .settingsPage()
        .task { await session.agents?.watch() }
    }

    private func move(_ shown: [AgentEntry], _ index: Int, by step: Int) {
        let target = index + step
        guard shown.indices.contains(index), shown.indices.contains(target) else { return }
        var ids = shown.map(\.id)
        ids.swapAt(index, target)
        order = ids.joined(separator: ",")
    }
}

// Names a new agent, chooses what it may do, and shows its one-time code with the commands
// that use it.
private struct ConnectAgentView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var canWork = false
    @State private var code: AgentCode?
    @State private var failure: String?
    @State private var isMaking = false

    private var server: String {
        session.connection?.server.absoluteString ?? "https://pendenz.example.com"
    }

    private var commands: String {
        guard let code else { return "" }
        return """
        curl -fsSL https://github.com/unveroleone/pendenz/releases/latest/download/install.sh | sh
        ~/.local/bin/pendenz connect \(server) \(code.code)
        ~/.local/bin/pendenz report install
        """
    }

    var body: some View {
        Form {
            if let code {
                Section {
                    Text(commands)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    Button("Copy Commands", systemImage: "doc.on.doc") {
                        copy(commands)
                    }
                } header: {
                    Text("On the agent's machine")
                } footer: {
                    Text(
                        "The code works once, until \(expiry(code)). The first line installs the pendenz command; skip it where it is installed already.",
                    )
                }
            } else {
                Section {
                    TextField("Name", text: $name, prompt: Text("Mac mini"))
                } footer: {
                    Text("Shown in the activity and next to what the agent writes.")
                }
                Section {
                    Toggle("Can work on items", isOn: $canWork)
                } footer: {
                    Text(
                        canWork
                            ? "The agent sends its status and can read and change every item and note that is not hidden from agents."
                            : "The agent only sends its status. It cannot read or change any item or note.",
                    )
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect an Agent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(code == nil ? "Cancel" : "Done") { dismiss() }
            }
            if code == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make Code") { make() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isMaking)
                }
            }
        }
    }

    private func expiry(_ code: AgentCode) -> String {
        let date = (try? Date(code.expiresAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(code.expiresAt, strategy: .iso8601))
        return date?.formatted(date: .omitted, time: .shortened) ?? "it expires"
    }

    private func make() {
        isMaking = true
        Task {
            defer { isMaking = false }
            do {
                failure = nil
                code = try await session.agentCode(
                    name: name.trimmingCharacters(in: .whitespaces), access: canWork ? "work" : "status",
                )
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// The price of a kWh, which turns the energy a Mac reports into a cost on the Agents screen. It
// belongs to the server like the file limit, so it is sent there directly when the field is left
// or submitted, and an empty field clears it.
private struct EnergyPriceSection: View {
    @Environment(Session.self) private var session
    // One price the owner wants, nil to clear it.
    private struct Wish: Equatable {
        let price: Double?
    }

    @State private var text = ""
    // The text when the field took focus: a save only follows an edit.
    @State private var textAtFocus = ""
    @State private var failure: String?
    // The latest price waiting to be sent while a request is on its way. Requests go one at a
    // time, so the last wish is the one the server keeps.
    @State private var pending: Wish?
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    private var confirmed: Double? {
        session.store?.settings?.energyPriceChf
    }

    private static func shown(_ price: Double?) -> String {
        price?.formatted(.number.precision(.fractionLength(2 ... 4)).grouping(.never)) ?? ""
    }

    // Either decimal mark, whatever the region uses.
    private static func parsed(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (try? Double(trimmed, format: .number)) ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        Section {
            LabeledContent("Price per kWh") {
                HStack(spacing: 6) {
                    TextField("Price per kWh", text: $text, prompt: Text("0.30"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .focused($isFocused)
                        .onSubmit(save)
                        #if os(iOS)
                        // The decimal pad has no return key. On the field itself: on a
                        // section, the button shows once for each of its parts.
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Done") { isFocused = false }
                            }
                        }
                        #endif
                    Text("CHF")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Energy")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
                Text("Turns the energy a Mac reports into a cost on the Agents screen. Leave it empty for no cost.")
            }
        }
        .onAppear { text = Self.shown(confirmed) }
        // Leaving the screen while typing also sends the price.
        .onDisappear { if isFocused { save() } }
        .onChange(of: confirmed) { if !isFocused { text = Self.shown(confirmed) } }
        .onChange(of: isFocused) {
            if isFocused { textAtFocus = text } else { save() }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != textAtFocus.trimmingCharacters(in: .whitespaces) else {
            if !isFocused, !isSaving { text = Self.shown(confirmed) }
            return
        }
        textAtFocus = text
        let wish: Wish
        if trimmed.isEmpty {
            wish = Wish(price: nil)
        } else if let price = Self.parsed(trimmed), (0 ... 100).contains(price) {
            wish = Wish(price: price)
        } else {
            failure = "Enter a price from 0 to 100 CHF."
            return
        }
        failure = nil
        pending = wish
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer {
                isSaving = false
                if !isFocused { text = Self.shown(confirmed) }
            }
            while let wish = pending {
                pending = nil
                guard wish.price != confirmed else { continue }
                do {
                    _ = try await session.setEnergyPrice(wish.price)
                } catch {
                    failure = error.localizedDescription
                    pending = nil
                    return
                }
            }
        }
    }
}

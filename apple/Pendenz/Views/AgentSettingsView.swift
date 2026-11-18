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

    var body: some View {
        Form {
            Section {
                Picker("Show Agents", selection: $visibility) {
                    ForEach(AgentsVisibility.allCases) { Text($0.title).tag($0) }
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
        .task { await session.agents?.refresh() }
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
        let access = agent.scopes.contains("write") ? "Status and items" : "Status only"
        guard let used = agent.lastUsedAt else { return access }
        return "\(access) · active \(used.formatted(.relative(presentation: .named)))"
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
        pendenz connect \(server) \(code.code)
        pendenz report install
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

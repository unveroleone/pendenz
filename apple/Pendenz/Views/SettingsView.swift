import SwiftUI

// The pairing of this device: the server, the other devices, a code for one more, and the way
// out. A window of its own on the Mac, a sheet on iPhone and iPad.
struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [Device] = []
    @State private var current: String?
    @State private var code: PairingCode?
    @State private var failure: String?
    @State private var isLoading = false
    // The device the question is about. It stays after the answer, so the title keeps its
    // name while the alert fades.
    @State private var revokeCandidate: Device?
    @State private var isConfirmingRevoke = false
    @State private var isConfirmingUnpair = false

    var body: some View {
        Form {
            if let connection = session.connection {
                Section("Server") {
                    addressRow(connection.server.absoluteString)
                    if let name = connection.deviceName {
                        LabeledContent("This device", value: name)
                    }
                }
                Section {
                    NavigationLink(value: SettingsPage.notifications) {
                        LabeledContent("Notifications", value: Reminders.shared.access.label)
                    }
                    NavigationLink(value: SettingsPage.files) {
                        if let settings = session.store?.settings {
                            LabeledContent("Files", value: "Up to \(settings.fileLimitMb) MB")
                        } else {
                            Text("Files")
                        }
                    }
                }
                Section {
                    NavigationLink(value: SettingsPage.agents) {
                        LabeledContent("Agents", value: "\(session.agents?.connected.count ?? 0) connected")
                    }
                }
                if session.isDevelopment {
                    Section {
                        Text(
                            "This is the development server from the launch argument. It asks for no token, so there is nothing to pair.",
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    devicesSection
                    pairSection
                    Section {
                        Button("Unpair This Device", role: .destructive) { isConfirmingUnpair = true }
                            .formAction(.red)
                    } footer: {
                        Text(
                            "Removes this device from the server and deletes the items and notes stored on it. They stay on the server.",
                        )
                    }
                }
            } else {
                Section {
                    Text("This device is not paired.")
                        .foregroundStyle(.secondary)
                }
            }
            versionSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsPage.self) { page in
            switch page {
            case .notifications: NotificationSettingsView()
            case .files: FileSettingsView()
            case .agents: AgentSettingsView()
            }
        }
        // Neither can be taken back, so both ask, in an alert: see "Questions before an
        // action" in the plan.
        .alert("Unpair this device?", isPresented: $isConfirmingUnpair) {
            Button("Unpair", role: .destructive) {
                Task {
                    await session.unpair()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unpairWarning)
        }
        .alert(
            "Revoke \u{201C}\(revokeCandidate?.name ?? "")\u{201D}?", isPresented: $isConfirmingRevoke,
            presenting: revokeCandidate,
        ) { device in
            Button("Revoke", role: .destructive) { revoke(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It can no longer read or change anything until it is paired again.")
        }
        .task(id: session.connection) { await load() }
        .task { await Reminders.shared.refreshAccess() }
    }

    private var unpairWarning: String {
        let waiting = session.store?.pendingCount ?? 0
        let lost = waiting == 0 ? "" : " \(waiting) changes that were not sent yet are lost."
        return "You need a new pairing code to use Pendenz on this device again." + lost
    }

    // The app's version and build, and the version the server named in its last answer.
    private var versionSection: some View {
        Section {
            LabeledContent("App", value: Self.appVersion)
            if session.connection != nil {
                LabeledContent("Server", value: session.store?.serverVersion?.description ?? "Not known yet")
            }
        } header: {
            Text("Version")
        } footer: {
            if let notice = session.store?.outdatedServerNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    private var devicesSection: some View {
        Section {
            ForEach(devices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(detail(for: device))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if device.id != current {
                        Button("Revoke", role: .destructive) {
                            revokeCandidate = device
                            isConfirmingRevoke = true
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
            }
            if devices.isEmpty, isLoading {
                ProgressView()
            }
        } header: {
            Text("Paired devices")
        } footer: {
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
    }

    private var pairSection: some View {
        Section {
            if let code {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(code.code)
                            .font(.title.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-code")
                        Spacer(minLength: 0)
                        CopyButton(text: code.code, title: "Copy Code")
                            .accessibilityIdentifier("settings-copy-code")
                    }
                    Text("Enter it on the new device together with the address above. \(validity(of: code))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Button(code == nil ? "Show a Pairing Code" : "Show a New Code") {
                Task {
                    do {
                        code = try await session.pairingCode()
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            // Blue, the one colour besides red: in the gray of the form's tint the button read
            // as switched off.
            .formAction(.blue)
        } header: {
            Text("Pair another device")
        } footer: {
            Text("A code works once. A device paired with it can do everything this one can.")
        }
    }

    // The address with a button that copies it: the new device asks for it next to the code.
    // Where the row is too narrow for both, as on an iPhone with a long address, the address
    // stands alone under the section's title.
    private func addressRow(_ address: String) -> some View {
        let value = Text(address)
            .lineLimit(1)
            #if os(macOS)
            .textSelection(.enabled)
            #endif
            .accessibilityLabel("Address, \(address)")
            .accessibilityIdentifier("settings-address")
        // The button keeps its target and gives up the height it would add to the row.
        let copy = CopyButton(text: address, title: "Copy Address")
            .padding(.vertical, (24 - CopyButton.side) / 2)
            .accessibilityIdentifier("settings-copy-address")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Address")
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                value
                    .foregroundStyle(.secondary)
                copy
            }
            HStack(spacing: 12) {
                value
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                copy
            }
        }
    }

    private func load() async {
        guard session.connection?.token != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await session.devices()
            devices = list.devices
            current = list.current
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func revoke(_ device: Device) {
        Task {
            do {
                try await session.revoke(device)
            } catch {
                failure = error.localizedDescription
            }
            await load()
        }
    }

    private func detail(for device: Device) -> String {
        let used = Self.date(device.lastUsedAt)
            .map { "Last used \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Not used yet"
        return device.id == current ? "This device. \(used)" : used
    }

    private func validity(of code: PairingCode) -> String {
        guard let until = Self.date(code.expiresAt) else { return "" }
        return "It works until \(until.formatted(date: .omitted, time: .shortened))."
    }

    private static func date(_ text: String?) -> Date? {
        text.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
    }
}

// Copies a text, so it can be pasted on the new device. Between devices on the same Apple
// Account the system carries the clipboard across. The icon turns into a checkmark for a moment.
private struct CopyButton: View {
    let text: String
    // What the button does, for VoiceOver and the Mac's tooltip.
    let title: String
    // A 44 point target for a finger. The Mac's pointer needs no more than the icon.
    #if os(macOS)
    static let side: CGFloat = 24
    #else
    static let side: CGFloat = 44
    #endif
    // Counts the copies, for the checkmark and the haptic.
    @State private var copies = 0
    @State private var hasJustCopied = false

    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
            copies += 1
            hasJustCopied = true
        } label: {
            Label(hasJustCopied ? "Copied" : title, systemImage: hasJustCopied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                // The icon ends where the values of the other rows end, and its target
                // reaches to the left of it.
                .frame(width: Self.side, height: Self.side, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .tint(.blue)
        .help(title)
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            hasJustCopied = false
        }
    }
}

// A group of settings with a page of its own, behind a row of the first page.
enum SettingsPage: Hashable {
    case notifications
    case files
    case agents
}

// The gear that opens the settings on iPhone and iPad. The Mac has them in its app menu.
struct SettingsButton: View {
    @Environment(Session.self) private var session
    @State private var isShown = false

    var body: some View {
        Button("Settings", systemImage: "gearshape") { isShown = true }
            .sheet(isPresented: $isShown) {
                NavigationStack {
                    SettingsView()
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShown = false }
                            }
                        }
                }
                .environment(session)
            }
    }
}

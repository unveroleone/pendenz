import SwiftUI

#if os(macOS)
// The settings window of the Mac: a sidebar of panes, each a grouped form of its own, as the
// system's settings are laid out. iPhone and iPad show `SettingsView` as a sheet instead.
struct MacSettingsView: View {
    @Environment(Session.self) private var session
    // Kept on this device, so the window opens on the pane it was left on.
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    SettingsPaneRow(pane: .general)
                    if session.connection != nil {
                        SettingsPaneRow(pane: .devices)
                    }
                }
                // Behind a pairing, as the rows that lead to them on iPhone and iPad.
                if session.connection != nil {
                    Section {
                        SettingsPaneRow(pane: .notifications)
                        SettingsPaneRow(pane: .files)
                        SettingsPaneRow(pane: .agents)
                    }
                }
            }
            .listStyle(.sidebar)
            // Ahead of the width: after it, the column falls back to the system's width.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
        } detail: {
            // A stack per pane, so Agents can open its order and a new pane starts at its top.
            NavigationStack {
                content
            }
            .id(shownPane)
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 440, idealHeight: 520)
        .task { await Reminders.shared.refreshAccess() }
    }

    // The pane on screen: without a pairing only General is there.
    private var shownPane: SettingsPane {
        session.connection == nil ? .general : pane
    }

    private var selection: Binding<SettingsPane?> {
        Binding {
            shownPane
        } set: { pane in
            if let pane { self.pane = pane }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shownPane {
        case .general:
            Form {
                if session.connection != nil {
                    ServerSection()
                } else {
                    NotPairedSection()
                }
                VersionSection()
            }
            .formStyle(.grouped)
            .navigationTitle(SettingsPane.general.title)
        case .devices:
            Form {
                // The address once more: a new device asks for it next to the pairing code,
                // which is lost when the pane is left.
                ServerSection()
                DeviceSections()
            }
            .formStyle(.grouped)
            .navigationTitle(SettingsPane.devices.title)
        case .notifications: NotificationSettingsView()
        case .files: FileSettingsView()
        case .agents: AgentSettingsView()
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, devices, notifications, files, agents

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .devices: "Devices"
        case .notifications: "Notifications"
        case .files: "Files"
        case .agents: "Agents"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .devices: "laptopcomputer.and.iphone"
        case .notifications: "bell.badge.fill"
        case .files: "paperclip"
        case .agents: Place.agents.systemImage
        }
    }
}

private struct SettingsPaneRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsTile(systemImage: pane.systemImage)
        }
        .tag(pane)
    }
}

// A white symbol on a gray tile with the corners of an app icon, as the system's settings draw
// their panes. Gray, because color is kept for state.
private struct SettingsTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                Color(nsColor: .systemGray).gradient,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous),
            )
            .accessibilityHidden(true)
    }
}
#endif

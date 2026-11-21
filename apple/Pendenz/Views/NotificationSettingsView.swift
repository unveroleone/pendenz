import SwiftUI

// Whether this device may show reminders, and the way to change it. Sounds and banners are
// the system's to set, so the page only leads there.
struct NotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var reminders: Reminders { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Reminders", value: reminders.access.label)
                switch reminders.access {
                case .undecided:
                    Button("Allow Notifications") {
                        Task { await reminders.askForAccess() }
                    }
                    .formAction(.blue)
                case .allowed, .denied:
                    Button(Self.systemSettingsTitle) { openURL(Self.systemSettings) }
                        .formAction(.blue)
                case .unknown:
                    EmptyView()
                }
            } footer: {
                Text(explanation)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .settingsPage()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reminders.refreshAccess() }
        .onChange(of: scenePhase) { _, phase in
            // Back from the system settings, where the answer may have changed.
            if phase == .active {
                Task { await reminders.refreshAccess() }
            }
        }
    }

    private var explanation: String {
        switch reminders.access {
        case .unknown, .undecided:
            "A reminder arrives as a notification at its time, also without a connection. Pendenz asks once."
        case .allowed:
            "A reminder arrives as a notification at its time, also without a connection. Sounds and banners are set in the system settings."
        case .denied:
            "Notifications are switched off for Pendenz, so no reminder arrives on this device. Switch them on in the system settings."
        }
    }

    private static var systemSettingsTitle: String {
        #if os(macOS)
        "Open System Settings"
        #else
        "Open Settings"
        #endif
    }

    private static var systemSettings: URL {
        #if os(macOS)
        let bundle = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)")!
        #else
        return URL(string: UIApplication.openNotificationSettingsURLString)!
        #endif
    }
}

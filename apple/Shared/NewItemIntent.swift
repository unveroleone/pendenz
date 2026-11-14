import AppIntents

// The control "New Item" in Control Center, on the lock screen and for the Action button. It
// opens the app with quick add for the inbox, as the home screen menu does. In both targets,
// because the control is declared in the widget extension and carried out in the app.
struct NewItemIntent: AppIntent {
    static let title: LocalizedStringResource = "New Item"
    static let description = IntentDescription("Opens Pendenz with a new item.")
    // Only the control uses it. Shortcuts and Siri have Add Item, which needs no window.
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground
    // In the app, never in the extension, where nothing is set to carry it out.
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        ControlActions.newItem?()
        return .result()
    }
}

// Set by the session at launch, as for the widget's tick: the app may have been started for
// the control before any window exists.
enum ControlActions {
    static var newItem: (@MainActor () -> Void)?
}

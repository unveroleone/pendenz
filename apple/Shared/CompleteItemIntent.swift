import AppIntents

// The tick on a row of a widget. It runs in the app, which the system starts in the background
// for it, and never in the widget extension: the completion goes through the outbox like every
// other change, and the extension has neither the store nor a token.
struct CompleteItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Item"
    // Only a widget's row uses it. Shortcuts and Siri get intents of their own later.
    static let isDiscoverable = false
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Item")
    var itemID: Int
    // The due date the row showed, as `Due.text` writes it. Empty for an item without one.
    @Parameter(title: "Due")
    var due: String
    // The server the widget's rows came from.
    @Parameter(title: "Server")
    var server: String

    init() {}

    init(item: WidgetItem, server: String) {
        itemID = item.id
        due = item.due?.text ?? ""
        self.server = server
    }

    func perform() async throws -> some IntentResult {
        await WidgetActions.complete?(itemID, Due(text: due), server)
        return .result()
    }
}

// Set by the session at launch, as for the actions on a notification: the app may have been
// started in the background for the tick, without a window.
enum WidgetActions {
    static var complete: (@MainActor (_ itemID: Int, _ due: Due?, _ server: String) async -> Void)?
}

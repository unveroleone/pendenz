import AppIntents
import SwiftUI
import WidgetKit

// A button for Control Center, the lock screen and the Action button that opens quick add.
struct NewItemControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NewItem") {
            ControlWidgetButton(action: NewItemIntent()) {
                Label("New Item", systemImage: "plus.circle")
            }
        }
        .displayName("New Item")
        .description("Opens Pendenz with a new item.")
    }
}

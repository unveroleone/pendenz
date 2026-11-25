import SwiftUI
import WidgetKit

@main
struct PendenzWidgets: WidgetBundle {
    var body: some Widget {
        ListWidget()
        #if os(iOS)
        LockWidget()
        #endif
        NewItemControl()
    }
}

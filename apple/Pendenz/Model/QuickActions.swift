import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

// The actions in the menu of the app's icon on the home screen. They are listed in Info.plist
// (`UIApplicationShortcutItems`), so the menu has them before the app has ever run. The widget
// sizes at the foot of that menu come from the system, because the app has a widget.
@Observable
final class QuickActions {
    // The names are the types in Info.plist.
    enum Action: String {
        case newItem, newNote, reminders, search
    }

    static let shared = QuickActions()

    // The action that was chosen. The front window carries it out and clears this.
    var chosen: Action?

    @discardableResult
    func choose(_ type: String?) -> Bool {
        guard let action = type.flatMap(Action.init(rawValue:)) else { return false }
        chosen = action
        return true
    }
}

#if os(iOS)
// The system hands a chosen action to the delegate of the scene and to nothing else: with the
// options of a scene that it starts for the action, or in a call of its own when the app was
// already running.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_: UIScene, willConnectTo _: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        QuickActions.shared.choose(connectionOptions.shortcutItem?.type)
    }

    func windowScene(_: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickActions.shared.choose(shortcutItem.type)
    }
}
#endif

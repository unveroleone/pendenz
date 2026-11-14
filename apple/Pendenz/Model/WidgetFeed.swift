import Foundation
import WidgetKit

// Keeps the widgets' copy of the open items in step with the store. The file is written only
// when its content changes, and the widgets are asked to draw again right after.
final class WidgetFeed {
    static let shared = WidgetFeed()

    // What the file holds, read once per launch: a launch in the background that changes
    // nothing then writes nothing and spends none of the widgets' daily reloads.
    private var written: WidgetSnapshot?
    private var hasRead = false

    func put(_ snapshot: WidgetSnapshot) {
        if !hasRead {
            written = WidgetFile.read()
            hasRead = true
        }
        guard snapshot != written, WidgetFile.write(snapshot) else { return }
        written = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }

    // The pairing ended. The widgets show nothing of it any more.
    func clear() {
        hasRead = true
        written = nil
        if WidgetFile.remove() { WidgetCenter.shared.reloadAllTimelines() }
    }
}

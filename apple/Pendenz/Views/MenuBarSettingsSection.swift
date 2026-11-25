#if os(macOS)
import SwiftUI

// Quick capture from the menu bar and from any app, in the General pane of the Mac's settings.
// The two are apart: the shortcut also works without the item in the menu bar.
struct MenuBarSettingsSection: View {
    @Bindable private var capture = MenuBarCapture.shared

    var body: some View {
        Section {
            Toggle("Show in Menu Bar", isOn: $capture.showsInMenuBar)
            Picker("Keyboard Shortcut", selection: $capture.shortcut) {
                ForEach(CaptureShortcut.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            }
        } header: {
            Text("Quick Capture")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch capture.shortcut == .off ? nil : capture.shortcutFailure {
        case .taken: "Another app uses \(capture.shortcut.title). Choose another shortcut."
        case .failed: "\(capture.shortcut.title) could not be set up. Choose another shortcut."
        case nil: "Adds an item to the inbox from any app. A #project in the text puts it there."
        }
    }
}
#endif

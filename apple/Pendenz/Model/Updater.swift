#if SPARKLE
import Foundation
import Sparkle

// Updates for the Mac app handed out as a download, signed with Developer ID
// (`PENDENZ_MAC_SIGNING=developerid`). Every other build leaves Sparkle switched off, so a
// development build never replaces itself with the published one.
@Observable
final class Updater {
    static let shared = Updater()

    // False while a check or an update is under way.
    private(set) var canCheck = false

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil,
    )
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [
            .initial,
            .new,
        ]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}
#endif

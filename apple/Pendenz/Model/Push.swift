import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The silent push: after a change the server asks the app on every other device to sync, so a
// reminder made elsewhere is scheduled here before it is due. A push carries no text. The app
// needs no permission for it, because it shows nothing.
final class Push {
    enum Outcome {
        case newData, noData, failed
    }

    static let shared = Push()

    // The APNs token of this device as hexadecimal digits, once the system has handed it over.
    private(set) var token: String?
    // Set by the session at launch, like the action of a reminder: a push can start the app in
    // the background, where no window is built.
    var onToken: (() -> Void)?
    var onPush: (() async -> Outcome)?

    // The session wants pushes while the device is paired. The system is only asked once the
    // app has finished launching, which can be after the session exists.
    var isWanted = false {
        didSet { register() }
    }

    private var hasLaunched = false

    private init() {
        // A registration the server did not get is sent again when the app comes to the front.
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { _ in
            Task { @MainActor in Push.shared.onToken?() }
        }
    }

    func launched() {
        hasLaunched = true
        register()
    }

    private func register() {
        guard isWanted, hasLaunched else { return }
        // Asked at every launch, as Apple wants it: the token can change.
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func received(token data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        onToken?()
    }

    func arrived() async -> Outcome {
        await onPush?() ?? .noData
    }

    // Which of Apple's two push services knows this build's token. A build from Xcode is known
    // to the sandbox, one from TestFlight or the App Store to production. The server passes it
    // on with the token, because a token sent to the wrong one is refused.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.aps-environment" as CFString, nil,
              ) as? String
        else { return "production" }
        return value == "development" ? "sandbox" : "production"
        #else
        // The entitlement cannot be read on iOS, but the profile a development build carries
        // names it. A build from the App Store has no profile.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound ..< text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound ..< text.endIndex)
        else { return "production" }
        return text[open.upperBound ..< close.lowerBound] == "development" ? "sandbox" : "production"
        #endif
    }()
}

// The system hands the push token and the pushes to the app delegate and to nothing else. On
// iOS it also names the delegate of each scene, see `QuickActions`.
#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        Push.shared.launched()
        #if SPARKLE
        // Made here, so the updater starts and checks on its own schedule.
        _ = Updater.shared
        #endif
    }

    func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.received(token: deviceToken)
    }

    func application(_: NSApplication, didReceiveRemoteNotification _: [String: Any]) {
        Task { _ = await Push.shared.arrived() }
    }
}
#else
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        Push.shared.launched()
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.received(token: deviceToken)
    }

    // Gives every window the delegate that takes the actions of the home screen menu.
    func application(
        _: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    // The system waits for the answer before it lets a background launch end.
    func application(
        _: UIApplication, didReceiveRemoteNotification _: [AnyHashable: Any],
    ) async -> UIBackgroundFetchResult {
        switch await Push.shared.arrived() {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}
#endif

import Foundation
import LocalAuthentication
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Whether the locked notes can be read right now. One answer for the whole app: Face ID or
// Touch ID opens all of them, and they close again when the app leaves the front.
//
// The lock is a gate in front of the screen, not encryption. The text of a locked note is in
// the local store and on the server like that of every other note.
@Observable
final class NoteLock {
    static let shared = NoteLock()

    private(set) var isOpen = false
    // True while the system asks. Its sheet takes the front from the app, which must not
    // count as the app leaving it.
    private(set) var isAsking = false
    // Why the last try did not open the notes, when there is something to say about it.
    private(set) var failure: String?

    private init() {
        #if os(iOS)
        let left = UIApplication.willResignActiveNotification
        #else
        let left = NSApplication.didResignActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: left, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isAsking else { return }
                self.close()
            }
        }
    }

    // What opens the notes on this device, for the label of the button. A device names its
    // sensor also when no face or finger is set up on it, so that is asked first.
    static var method: String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch context.biometryType {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            default: break
            }
        }
        #if os(iOS)
        return "Passcode"
        #else
        return "Password"
        #endif
    }

    func close() {
        isOpen = false
    }

    // Asks for Face ID or Touch ID, and for the passcode or the password where neither is set
    // up or neither worked. Returns whether the locked notes are open.
    @discardableResult
    func open() async -> Bool {
        if isOpen { return true }
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        failure = nil
        // macOS puts the name of the app in front: "Pendenz is trying to open your locked notes."
        #if os(iOS)
        let reason = "Open your locked notes."
        #else
        let reason = "open your locked notes"
        #endif
        do {
            isOpen = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .systemCancel, .appCancel:
                break
            case .passcodeNotSet:
                #if os(iOS)
                failure = "This iPhone or iPad has no passcode. Set one in Settings to open locked notes here."
                #else
                failure = "This Mac has no password. Set one in System Settings to open locked notes here."
                #endif
            default:
                failure = error.localizedDescription
            }
        } catch {
            failure = error.localizedDescription
        }
        return isOpen
    }
}

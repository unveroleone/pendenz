import Foundation
import Observation
import UserNotifications

// Reminders are local notifications, scheduled on this device from the items it holds. They
// fire without a connection and when the server is down.
@Observable
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    enum Access {
        case unknown, undecided, allowed, denied

        // The state in a word, for the settings.
        var label: String {
            switch self {
            case .unknown: ""
            case .undecided: "Not Asked Yet"
            case .allowed: "On"
            case .denied: "Off"
            }
        }
    }

    // What a reminder offers on the notification itself, without opening the app.
    enum Action: String, CaseIterable {
        case done, inAnHour, tomorrow

        var title: String {
            switch self {
            case .done: "Done"
            case .inAnHour: "In 1 Hour"
            case .tomorrow: "Tomorrow"
            }
        }

        var symbol: String {
            switch self {
            case .done: "checkmark"
            case .inAnHour: "clock"
            case .tomorrow: "calendar"
            }
        }
    }

    private static let category = "reminder"

    static let shared = Reminders()
    // iOS keeps 64 waiting notifications per app. The nearest ones are scheduled, the rest
    // follow when the list is worked out again.
    private static let limit = 60

    private(set) var access = Access.unknown
    // The item whose notification was tapped. The front window opens it and clears this.
    var openedItemID: Int?
    // Carries out an action chosen on a notification. Set by the session at launch: the app
    // may have been started in the background for the action, without a window.
    @ObservationIgnored var onAction: ((Action, Int) async -> Void)?
    // The server this device is paired with, set by the session. A notification names the
    // server its item belongs to: item 12 of another server is another item.
    @ObservationIgnored var server: String?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var lastPass: Task<Void, Never>?

    override private init() {
        super.init()
        center.delegate = self
        // None of the actions brings the app to the front.
        let actions = Action.allCases.map { action in
            UNNotificationAction(
                identifier: action.rawValue, title: action.title, options: [],
                icon: UNNotificationActionIcon(systemImageName: action.symbol),
            )
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: []),
        ])
    }

    func refreshAccess() async {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: access = .undecided
        case .denied: access = .denied
        default: access = .allowed
        }
    }

    func askForAccess() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAccess()
    }

    // Brings the waiting notifications in line with the items: one per open item with a
    // reminder time ahead. Only the difference is added and removed.
    // Passes run one after the other. Two at once could both read the waiting list before
    // either has changed it, and leave a notification behind that no item wants.
    // `isCurrent` says that the items are the server's state as of a sync in this launch. Only
    // then is a notification that is already shown taken away for a missing item.
    func schedule(_ items: [Item], isCurrent: Bool, projectName: @escaping (String?) -> String?) async {
        let previous = lastPass
        let pass = Task {
            await previous?.value
            await reconcile(items, isCurrent: isCurrent, projectName: projectName)
        }
        lastPass = pass
        await pass.value
    }

    private func reconcile(_ items: [Item], isCurrent: Bool, projectName: (String?) -> String?) async {
        if access == .unknown { await refreshAccess() }
        guard access == .allowed else { return }
        let now = Date.now
        let upcoming = items
            .compactMap { item in item.isOpen ? item.reminderDate.map { (item, $0) } : nil }
            .filter { $0.1 > now }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.limit)
        var wanted: [String: UNNotificationRequest] = [:]
        for (item, date) in upcoming {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = projectName(item.projectId) ?? ""
            content.sound = .default
            content.userInfo = ["item": item.id, "server": server ?? ""]
            content.categoryIdentifier = Self.category
            // A reminder is a moment, so the trigger counts seconds to it. Date parts would be
            // read in the device's calendar, which need not be the Gregorian one.
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(date.timeIntervalSince(now), 1),
                repeats: false,
            )
            // The title and the time are part of the name, so an edit replaces the notification.
            // The checksum is worked out here because hashValue differs from launch to launch.
            // The "a" marks a notification with actions: one scheduled by a build without them
            // has another name and is replaced.
            let checksum = item.title.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
            let name = "item-\(item.id)-\(Int(date.timeIntervalSince1970))-\(checksum)-a"
            wanted[name] = UNNotificationRequest(identifier: name, content: content, trigger: trigger)
        }
        let waiting = await Set(center.pendingNotificationRequests().map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: waiting.filter { wanted[$0] == nil })
        for (name, request) in wanted where !waiting.contains(name) {
            try? await center.add(request)
        }
        // A notification that is already on the lock screen goes when its item was completed,
        // or its reminder moved or removed, on another device. One of an item that still has a
        // local number stays: the list knows that item under its number from the server.
        guard isCurrent else { return }
        let open = Dictionary(items.filter(\.isOpen).map { ($0.id, $0) }) { first, _ in first }
        let shown = await center.deliveredNotifications().filter { notification in
            let info = notification.request.content.userInfo
            guard let id = info["item"] as? Int, id > 0, info["server"] as? String == server else { return false }
            // The name carries the moment the notification was made for, after "item" and the
            // number. It stays for as long as that is still the item's reminder time.
            let parts = notification.request.identifier.split(separator: "-")
            guard parts.count > 2, let moment = Int(parts[2]) else { return false }
            guard let date = open[id]?.reminderDate else { return true }
            return Int(date.timeIntervalSince1970) != moment
        }
        center.removeDeliveredNotifications(withIdentifiers: shown.map(\.request.identifier))
    }

    // The device was unpaired: no reminder of an item it no longer holds may fire.
    func clear() async {
        await lastPass?.value
        center.removeAllPendingNotificationRequests()
        // Also the ones already shown: their actions would act on the next pairing's items.
        center.removeAllDeliveredNotifications()
    }

    // A reminder that fires while the app is open is shown as well.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    ) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["item"] as? Int else { return }
        let origin = info["server"] as? String
        let chosen = response.actionIdentifier
        // The system waits for this to return before it lets a background launch end.
        await respond(to: chosen, itemID: id, origin: origin)
    }

    private func respond(to chosen: String, itemID: Int, origin: String?) async {
        // Left over from a pairing with another server: the number means another item here.
        guard let server, origin == server else { return }
        if let action = Action(rawValue: chosen) {
            await onAction?(action, itemID)
        } else if chosen == UNNotificationDefaultActionIdentifier {
            openedItemID = itemID
        }
    }
}

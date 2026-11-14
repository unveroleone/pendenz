import Foundation

// What the widgets show. The app writes it into the app group's folder whenever the open items
// or the projects change. The widget extension reads nothing else: it holds no token and makes
// no request.
nonisolated struct WidgetSnapshot: Equatable, Sendable, Codable {
    // The server the rows came from. A tick names it, as a notification does: item 12 of
    // another server is another item.
    var server: String
    // False until this device has synced once, so an empty list is not shown as "nothing to do".
    var hasLoaded: Bool
    // Every open item. The inbox and each project come in the order the app shows them in.
    var items: [WidgetItem]
    // In the order the app lists them.
    var projects: [WidgetProject]
}

nonisolated struct WidgetItem: Identifiable, Equatable, Sendable, Codable {
    // Below zero while the server has not given the item a number yet. Such a number only
    // holds until the app is next started, so a widget offers no tick and no link for it.
    var id: Int
    var title: String
    var projectID: String?
    var due: Due?
    var isStarted: Bool
    var priority: Int

    var isSynced: Bool {
        id > 0
    }
}

nonisolated struct WidgetProject: Identifiable, Equatable, Sendable, Codable {
    var id: String
    var name: String
    var symbol: String
}

// A list a widget can show. "All" exists only there: the app has no list of everything.
nonisolated enum WidgetList: Hashable, Sendable {
    case reminders
    case inbox
    case all
    case project(String)

    // The name the widget's settings and its links keep.
    var id: String {
        switch self {
        case .reminders: "reminders"
        case .inbox: "inbox"
        case .all: "all"
        case .project(let id): "project:\(id)"
        }
    }

    init?(id: String) {
        switch id {
        case "reminders": self = .reminders
        case "inbox": self = .inbox
        case "all": self = .all
        default:
            guard id.hasPrefix("project:"), id.count > "project:".count else { return nil }
            self = .project(String(id.dropFirst("project:".count)))
        }
    }
}

// The one file the app and the widget extension share.
nonisolated enum WidgetFile {
    // Missing where the build has no app group: a Mac build that is signed ad hoc.
    static let url: URL? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PendenzAppGroup") as? String,
              !group.isEmpty, !group.hasPrefix(".")
        else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Widgets.json")
    }()

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    // Readable while the device is locked, once it was unlocked after a restart: a widget is
    // also drawn then.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    // True when there was a file to remove.
    @discardableResult
    static func remove() -> Bool {
        guard let url else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

// Where a tap on a widget leads in the app.
nonisolated enum WidgetLink: Equatable, Sendable {
    case item(Int)
    case list(WidgetList)

    static let scheme = "pendenz"

    // "pendenz://item/12" or "pendenz://list/project:home".
    var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .item(let id):
            parts.host = "item"
            parts.path = "/\(id)"
        case .list(let list):
            parts.host = "list"
            parts.path = "/\(list.id)"
        }
        return parts.url ?? URL(filePath: "/")
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch url.host() {
        case "item":
            guard let id = Int(name) else { return nil }
            self = .item(id)
        case "list":
            guard let list = WidgetList(id: name) else { return nil }
            self = .list(list)
        default:
            return nil
        }
    }
}

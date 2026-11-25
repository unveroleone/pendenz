import Foundation
import notify

// A share from another app. The share extension writes it into the app group's folder, and the
// app moves it into its outbox and deletes it. The extension holds no token and sends nothing:
// the share reaches the server the way every change made in the app does.
nonisolated struct SharedDrop: Equatable, Sendable, Codable {
    // A UUID. It names the drop's folder and is the idempotency key of the item's create, so a
    // drop that is already in the outbox is not queued twice.
    var id: String
    // The server the device was paired with when it was shared. A drop for another server is
    // never queued.
    var server: String
    var title: String
    var description: String?
    // An http or https address, kept as the item's link.
    var link: String?
    // The names of the pictures in the drop's folder, in the order they were shared.
    var pictures: [String]
    var createdAt: Date

    // The key of the item's create in the outbox.
    var key: String {
        "share-\(id)"
    }
}

// The pairing as far as the share extension needs to know it: whether there is one, and with
// which server. No token.
nonisolated struct SharedPairing: Equatable, Sendable, Codable {
    var server: String
}

// The folder in the app group where the drops wait.
nonisolated enum SharedDrops {
    // How long the text of a shared item may be, as the server counts it.
    static let titleLimit = 240
    static let descriptionLimit = 20000
    // A link cut to fit would point somewhere else, so a longer one is not taken.
    static let linkLimit = 2000
    static let pictureLimit = 10
    static let pictureBytesLimit = 50_000_000

    // Missing where the build has no app group: a Mac build that is signed ad hoc.
    static let group: URL? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PendenzAppGroup") as? String,
              !group.isEmpty, !group.hasPrefix(".")
        else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }()

    static var folder: URL? {
        group?.appending(path: "Shared", directoryHint: .isDirectory)
    }

    private static var pairingFile: URL? {
        group?.appending(path: "Pairing.json")
    }

    // Posted by the extension after it wrote a drop, so an app that is open takes it at once.
    static var notification: String {
        let group = Bundle.main.object(forInfoDictionaryKey: "PendenzAppGroup") as? String ?? "pendenz"
        return "\(group).shared"
    }

    static func announce() {
        notify_post(notification)
    }

    // MARK: Pairing

    static func pairing() -> SharedPairing? {
        guard let url = pairingFile, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedPairing.self, from: data)
    }

    static func setPairing(_ pairing: SharedPairing?) {
        guard let url = pairingFile else { return }
        if let pairing {
            guard pairing != self.pairing(), let data = try? JSONEncoder().encode(pairing) else { return }
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Drops

    // A new folder for a drop that is still being put together. Its name starts with a dot, so
    // the app passes it by until `finish` gives it its real name.
    static func draftFolder(for id: String) -> URL? {
        guard let folder else { return nil }
        let draft = folder.appending(path: ".\(id)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
            return draft
        } catch {
            return nil
        }
    }

    // Writes the drop into its draft folder and moves the folder into place in one step, so the
    // app never sees half a drop. The draft folder has to be there still: unpairing removes it,
    // and a drop must not come back without its pictures.
    static func finish(_ drop: SharedDrop) -> Bool {
        guard let folder, pairing()?.server == drop.server else { return false }
        let draft = folder.appending(path: ".\(drop.id)", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: draft.path(percentEncoded: false)),
              let data = try? JSONEncoder().encode(drop),
              (try? data.write(to: draft.appending(path: "drop.json"), options: .atomic)) != nil
        else { return false }
        do {
            try FileManager.default.moveItem(
                at: draft,
                to: folder.appending(path: drop.id, directoryHint: .isDirectory),
            )
            return true
        } catch {
            return false
        }
    }

    static func discardDraft(_ id: String) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: ".\(id)", directoryHint: .isDirectory))
    }

    // The drops that wait, oldest first. Drafts that an ended extension left behind for more
    // than a day are removed on the way.
    static func waiting() -> [SharedDrop] {
        guard let folder else { return [] }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        var drops: [SharedDrop] = []
        for name in names {
            let url = folder.appending(path: name, directoryHint: .isDirectory)
            if name.hasPrefix(".") {
                let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if made < Date.now.addingTimeInterval(-86400) { try? manager.removeItem(at: url) }
                continue
            }
            guard let data = try? Data(contentsOf: url.appending(path: "drop.json")),
                  let drop = try? JSONDecoder().decode(SharedDrop.self, from: data), drop.id == name
            else {
                // Not a drop this build can read. Kept a day, in case another build can.
                let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if made < Date.now.addingTimeInterval(-86400) { try? manager.removeItem(at: url) }
                continue
            }
            drops.append(drop)
        }
        return drops.sorted { $0.createdAt < $1.createdAt }
    }

    static func picture(_ name: String, of drop: SharedDrop) -> URL? {
        folder?.appending(path: drop.id, directoryHint: .isDirectory).appending(path: name)
    }

    // Removes a drop that is queued or not wanted. A drop whose folder could not be removed
    // keeps a receipt, so it is not queued a second time after its item was sent.
    static func remove(_ drop: SharedDrop) {
        guard let folder else { return }
        var receipts = Set(UserDefaults.standard.stringArray(forKey: receiptsKey) ?? [])
        do {
            try FileManager.default.removeItem(at: folder.appending(path: drop.id, directoryHint: .isDirectory))
            guard receipts.remove(drop.id) != nil else { return }
        } catch CocoaError.fileNoSuchFile {
            guard receipts.remove(drop.id) != nil else { return }
        } catch {
            receipts.insert(drop.id)
        }
        UserDefaults.standard.set(Array(receipts), forKey: receiptsKey)
    }

    // Whether this drop was queued already and only its folder is left.
    static func isQueued(_ drop: SharedDrop) -> Bool {
        UserDefaults.standard.stringArray(forKey: receiptsKey)?.contains(drop.id) == true
    }

    private static let receiptsKey = "queuedShares"

    // Every drop and draft: the device was unpaired. A share sheet that was saving just then
    // can still leave one, which `isFromEndedPairing` turns away.
    static func removeAll() {
        UserDefaults.standard.set(Date.now, forKey: unpairedKey)
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func isFromEndedPairing(_ drop: SharedDrop) -> Bool {
        guard let unpaired = UserDefaults.standard.object(forKey: unpairedKey) as? Date else { return false }
        return drop.createdAt <= unpaired
    }

    private static let unpairedKey = "sharesUnpairedAt"
}

import Foundation
import notify

// Moves the shares that the share extension left in the app group into the outbox: at launch,
// each time the app comes to the front, and when the extension says it left one while the app
// is open (next to the sharing app on an iPad).
final class SharedDropsIntake {
    static let shared = SharedDropsIntake()

    // Set by `Session`, which knows the store and its server.
    var take: (() async -> Void)?
    private var isTaking = false
    private var isAskedAgain = false
    private var token: Int32 = NOTIFY_TOKEN_INVALID

    private init() {
        notify_register_dispatch(SharedDrops.notification, &token, .main) { _ in
            MainActor.assumeIsolated {
                SharedDropsIntake.shared.start()
            }
        }
    }

    // One intake at a time. A call while one runs makes it look again when it is done.
    func start() {
        guard let take else { return }
        guard !isTaking else {
            isAskedAgain = true
            return
        }
        isTaking = true
        Task {
            repeat {
                isAskedAgain = false
                await take()
            } while isAskedAgain
            isTaking = false
        }
    }
}

extension Session {
    // Queues every drop for the paired server, oldest first. A drop that cannot be queued stays
    // and is tried at the next intake.
    func takeSharedDrops() async {
        guard let connection, let store, !store.isClosed else { return }
        let server = connection.server.absoluteString
        for drop in SharedDrops.waiting() {
            guard drop.server == server else {
                // Shared while the device was paired with another server.
                SharedDrops.remove(drop)
                continue
            }
            if store.hasShared(drop) {
                SharedDrops.remove(drop)
                continue
            }
            var pictures: [(jpeg: Data, width: Int, height: Int)] = []
            var unread = 0
            for name in drop.pictures {
                if let url = SharedDrops.picture(name, of: drop),
                   let data = try? Data(contentsOf: url),
                   let scaled = await Pictures.scaled(data)
                {
                    pictures.append(scaled)
                } else {
                    unread += 1
                }
            }
            // The pairing may have ended while the pictures were scaled.
            guard self.store === store, !store.isClosed else { return }
            // Removed before anything else can run, so the sync cannot send the item while its
            // drop is still there to be queued again.
            guard store.addShared(drop, pictures: pictures) else { return }
            SharedDrops.remove(drop)
            if unread > 0 {
                store.rejection = unread == 1
                    ? "An image shared with “\(drop.title)” could not be read and was left out."
                    : "\(unread) images shared with “\(drop.title)” could not be read and were left out."
            }
        }
    }
}

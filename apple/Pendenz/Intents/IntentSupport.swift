import AppIntents
import Foundation
import Observation

// Why an action from Siri, Shortcuts or Spotlight could not be carried out. The text is what
// Siri says and Shortcuts shows.
nonisolated enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired
    case missingItem
    case missingNote
    case missingProject
    case emptyTitle
    case emptyNote
    case longNote
    case rejected(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: "Pendenz is not paired with a server yet. Open the app and pair it first."
        case .missingItem: "That item is no longer open in Pendenz."
        case .missingNote: "That note is no longer in Pendenz."
        case .missingProject: "That project is no longer in Pendenz."
        case .emptyTitle: "An item needs a title."
        case .emptyNote: "A note needs some text."
        case .longNote: "The note is too long. A note can have up to 100,000 characters."
        case .rejected(let reason): "The server did not take it. \(reason)"
        }
    }
}

extension Session {
    // The store an intent works on. The system may have started the app in the background for
    // the intent, where no window exists: the session is made with the app, so it is there.
    static func intentStore() throws -> Store {
        guard let store = current?.store, !store.isClosed else { throw IntentError.notPaired }
        return store
    }

    // The store, brought up to date first when this launch has not synced yet.
    static func freshIntentStore() async throws -> Store {
        let store = try intentStore()
        await refreshForIntent(store)
        guard !store.isClosed else { throw IntentError.notPaired }
        return store
    }

    // Before an intent reads or acts on rows: a launch in the background has only what was on
    // disk, which can be days old. One sync, for a few seconds at most.
    static func refreshForIntent(_ store: Store) async {
        guard !store.isCurrent else { return }
        await within(seconds: 4) { await store.sync() }
    }

    // After an intent changed something. The reminders follow at once, and the change is sent
    // if the server answers within a few seconds. Siri waits for this, so it does not wait for
    // a slow server: the change stays in the outbox, which is on disk, and goes with the next
    // sync.
    static func settleIntent(_ store: Store) async {
        await Reminders.shared.schedule(store.openItems, isCurrent: store.isCurrent, projectName: store.projectName)
        await within(seconds: 8) { await store.sync() }
        guard !store.isClosed else { return }
        await Reminders.shared.schedule(store.openItems, isCurrent: store.isCurrent, projectName: store.projectName)
        await within(seconds: 2) { await SpotlightFeed.shared.flush(store) }
    }

    // Waits for the work or for the time, whichever ends first. The work goes on after that,
    // for as long as the app keeps running.
    private static func within(seconds: Double, _ work: @escaping () async -> Void) async {
        let answer = FirstAnswer()
        await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task {
                await work()
                answer.give()
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                answer.give()
            }
        }
    }
}

// The one end of a wait, given by whichever comes first.
private final class FirstAnswer {
    var continuation: CheckedContinuation<Void, Never>?

    func give() {
        continuation?.resume()
        continuation = nil
    }
}

// What an intent asked the app to show: a list, an item or a note. The front window shows it
// and clears this, also when the intent started the app and the window came after it.
@Observable
final class OpenRequest {
    static let shared = OpenRequest()

    var place: Place?
    var itemID: Int?
    var noteID: Int?
}

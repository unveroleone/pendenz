import CryptoKit
import Foundation
import Observation

// The agents of the paired server and their latest reports, for the Agents screen. Asked from
// the server directly, like the device list: a report describes the agent's machine right now,
// and an old one is only shown with its age. The last answer is kept on disk per server, so the
// screen opens with it and without a connection.
@Observable
final class AgentBoard {
    enum Problem: Equatable {
        // The server is older than agent reports.
        case outdated
        // No connection, or the server failed. The last list stays on screen with its age.
        case unreachable
    }

    private(set) var list: AgentList?
    // When the list on screen was fetched, on this device's clock.
    private(set) var fetchedAt: Date?
    private(set) var problem: Problem?
    private(set) var isLoading = false

    private let api: APIClient
    private let file: URL
    private var isClosed = false

    // How often an open Agents screen asks again. The report command runs every two minutes.
    static let interval: Duration = .seconds(30)

    init(api: APIClient) {
        self.api = api
        let name = SHA256.hash(data: Data(api.baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appending(path: "Agents/\(name).json")
        if let data = try? Data(contentsOf: file), let list = try? AgentList.decode(data) {
            self.list = list
            fetchedAt = (try? FileManager.default.attributesOfItem(
                atPath: file.path(percentEncoded: false),
            )[.modificationDate]) as? Date
        }
    }

    // The agents that sent a report. The Agents screen is offered when there is one.
    var reporting: [AgentEntry] {
        list?.reporting ?? []
    }

    // The age of a report on the server's clock, so a device whose clock is off still shows it
    // right. Measured to now: the list may have been fetched a while ago.
    func age(of entry: AgentEntry, at now: Date = .now) -> TimeInterval? {
        guard let received = entry.receivedAt, let list, let fetchedAt else { return nil }
        let serverNow = list.now.addingTimeInterval(now.timeIntervalSince(fetchedAt))
        return max(0, serverNow.timeIntervalSince(received))
    }

    // A report older than this is shown as stale: the report command stopped sending.
    static let staleAfter: TimeInterval = 10 * 60

    func refresh() async {
        guard !isClosed, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await api.agents()
            let list = try AgentList.decode(data)
            guard !isClosed else { return }
            self.list = list
            fetchedAt = .now
            problem = nil
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try? data.write(to: file, options: .atomic)
        } catch APIError.status(404, _) {
            guard !isClosed else { return }
            problem = .outdated
        } catch {
            guard !isClosed else { return }
            problem = .unreachable
        }
    }

    // Asks again while a screen that shows the agents is open: call it from that screen's task.
    // Several windows share the answers, since a fetch younger than the interval is not repeated.
    func watch() async {
        while !Task.isCancelled, !isClosed {
            if fetchedAt.map({ Date.now.timeIntervalSince($0) >= 25 }) ?? true || problem != nil {
                await refresh()
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    func close() {
        isClosed = true
    }

    // The pairing ended: nothing of this server's agents stays on the device.
    func erase() {
        isClosed = true
        list = nil
        try? FileManager.default.removeItem(at: file)
    }
}

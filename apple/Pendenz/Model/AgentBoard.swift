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
    // The last time any window asked, answered or not, so open windows share one request.
    private var askedAt: Date?
    // Called when the server refuses this device's token: the pairing is over.
    var onUnauthorized: (() -> Void)?

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

    // The agents that sent a report, in the order the owner set in Settings: the IDs saved under
    // `orderKey` first, every other agent after them by name. A fixed order, since the server
    // lists the newest report first and the switcher would move with every report.
    func reporting(in savedOrder: String) -> [AgentEntry] {
        let order = savedOrder.split(separator: ",").map(String.init)
        return reporting.sorted { a, b in
            switch (order.firstIndex(of: a.id), order.firstIndex(of: b.id)) {
            case let (i?, j?): i < j
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil):
                switch a.name.localizedStandardCompare(b.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: a.id < b.id
                }
            }
        }
    }

    // Where the order of the agents is kept on this device, as their IDs joined by commas.
    static let orderKey = "agentOrder"

    // The agents that still have a working token, in the server's order.
    var connected: [AgentEntry] {
        list?.agents.filter { !$0.scopes.isEmpty } ?? []
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
        askedAt = .now
        defer { isLoading = false }
        do {
            var data: Data
            var list: AgentList
            // An answer that left the server before a line was written there would put the old
            // line back on screen: ask again.
            repeat {
                let written = writes
                data = try await api.agents()
                list = try AgentList.decode(data)
                if written == writes { break }
            } while !isClosed
            guard !isClosed else { return }
            self.list = list
            fetchedAt = .now
            problem = nil
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try? data.write(to: file, options: .atomic)
        } catch APIError.status(401, _) {
            guard !isClosed else { return }
            onUnauthorized?()
        } catch APIError.status(404, _) {
            guard !isClosed else { return }
            problem = .outdated
        } catch {
            guard !isClosed else { return }
            problem = .unreachable
        }
    }

    // How many lines this board has written, so a list fetched during a write is not shown.
    private var writes = 0

    // Writes the owner's line about one of an agent's jobs, or removes it with an empty text,
    // then reads the list again, which also keeps it on disk. Throws when the server refused
    // it. A line the server took shows at once, also when the list cannot be read right after.
    func setJobDescription(agent: String, job: String, text: String) async throws {
        guard !isClosed else { return }
        do {
            try await api.setJobDescription(agent: agent, job: job, text: text)
        } catch APIError.status(401, let message) {
            if !isClosed { onUnauthorized?() }
            throw APIError.status(401, message)
        }
        guard !isClosed else { return }
        writes += 1
        let text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let index = list?.agents.firstIndex(where: { $0.id == agent }) {
            var lines = list?.agents[index].jobDescriptions?.filter { $0.job != job } ?? []
            if !text.isEmpty { lines.append(AgentJobDescription(job: job, text: text)) }
            list?.agents[index].jobDescriptions = lines
        }
        // A refresh in flight asks again by itself, since `writes` changed.
        if !isLoading { await refresh() }
    }

    // Asks again while a screen that shows the agents is open: call it from that screen's task.
    // Several windows share the answers, since a fetch younger than the interval is not repeated.
    func watch() async {
        while !Task.isCancelled, !isClosed {
            if askedAt.map({ Date.now.timeIntervalSince($0) >= 25 }) ?? true {
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

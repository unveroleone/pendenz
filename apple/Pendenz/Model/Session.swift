import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

// The server this device is paired with, and the token it uses there.
nonisolated struct Connection: Equatable, Sendable, Codable {
    var server: URL
    // Missing only for the development server named with `-apiURL`, which asks for none.
    var token: String?
    var deviceID: String?
    var deviceName: String?
}

nonisolated enum PairingError: LocalizedError {
    case address
    case insecure
    case keychain

    var errorDescription: String? {
        switch self {
        case .address: "Enter the address of your Pendenz server, for example https://pendenz.example.com."
        case .insecure: "The address has to start with https://. Only a server on this device may use http://."
        case .keychain: "The device is paired, but its token could not be saved in the Keychain. Revoke it on another device and try again."
        }
    }
}

// Whether this device is paired, and the store that belongs to the pairing. Without a pairing
// there is no store and the app shows the pairing screen.
@Observable
final class Session {
    private(set) var connection: Connection?
    private(set) var store: Store?
    // The agents of the paired server, for the Agents screen. Made and ended with the store.
    private(set) var agents: AgentBoard?
    // Said on the pairing screen: why the device is no longer paired.
    var notice: String?
    // The push token the server has taken in this launch, with the pairing it was sent for.
    private var pushRegistration: String?
    private var isRegisteringPush = false
    // The pairing whose server is older than push. It is asked again at the next launch.
    private var pairingWithoutPush: Connection?
    // The session of this launch, for the actions of Siri, Shortcuts and Spotlight, which the
    // system can run without a window. There is one per launch.
    private(set) weak static var current: Session?

    // The server last paired with, offered again on the pairing screen.
    var lastServer: String {
        UserDefaults.standard.string(forKey: "server") ?? ""
    }

    // True for the development server from `-apiURL`: there is nothing to pair or unpair.
    var isDevelopment: Bool {
        connection != nil && connection?.token == nil
    }

    init() {
        if let server = Settings.apiURL {
            connection = Connection(server: server)
        } else if let data = Keychain.load() {
            connection = try? JSONDecoder().decode(Connection.self, from: data)
        }
        openStore()
        Session.current = self
        // Set here and not by a view: an action on a notification can start the app in the
        // background, where no window is built.
        Reminders.shared.onAction = { [weak self] action, itemID in
            await self?.carryOut(action, itemID: itemID)
        }
        WidgetActions.complete = { [weak self] itemID, due, server in
            await self?.completeFromWidget(itemID, due: due, server: server)
        }
        ControlActions.newItem = { QuickActions.shared.chosen = .newItem }
        Push.shared.onToken = { [weak self] in self?.registerForPush() }
        Push.shared.onPush = { [weak self] in await self?.pushed() ?? .noData }
        SharedDropsIntake.shared.take = { [weak self] in await self?.takeSharedDrops() }
        SharedDropsIntake.shared.start()
    }

    // MARK: Push

    // Tells the server this device's push token: when the system hands it over, and again each
    // time the app comes to the front until the server has taken it. Not through the outbox: a
    // server from before push answers 404, and nothing may wait behind that.
    private func registerForPush() {
        guard let connection, connection.token != nil, let api, let token = Push.shared.token else { return }
        let registration = [connection.deviceID ?? "", Push.environment, token].joined(separator: " ")
        guard pushRegistration != registration, !isRegisteringPush, pairingWithoutPush != connection else { return }
        isRegisteringPush = true
        Task {
            var isTaken = false
            var isMissing = false
            var isRefused = false
            do {
                try await api.registerPush(token: token, environment: Push.environment)
                isTaken = true
            } catch APIError.status(401, _) {
                isRefused = true
            } catch APIError.status(404, _) {
                isMissing = true
            } catch {
                // No connection. Tried again when the app comes to the front.
            }
            isRegisteringPush = false
            // The answer belongs to the pairing that asked. A late one must not end a newer
            // pairing or switch push off for it.
            guard self.connection == connection else {
                // Paired anew in the meantime, and that pairing could not ask while this ran.
                registerForPush()
                return
            }
            if isTaken { pushRegistration = registration }
            if isMissing { pairingWithoutPush = connection }
            if isRefused {
                lostPairing()
            } else if Push.shared.token != token {
                // The system handed over a new token while the request was on its way.
                registerForPush()
            }
        }
    }

    // The server says that something changed. The system gives a background launch about half
    // a minute, so the answer is given after 25 seconds at the latest; a sync that takes longer
    // goes on for as long as the app is left running.
    private func pushed() async -> Push.Outcome {
        guard let store, !store.isClosed else { return .noData }
        let before = store.cursor
        let answer = PushAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task {
                await store.sync()
                if !store.isClosed {
                    await Reminders.shared.schedule(
                        store.openItems,
                        isCurrent: store.isCurrent,
                        projectName: store.projectName,
                    )
                    // The app may be suspended right after the answer.
                    await SpotlightFeed.shared.flush(store)
                }
                if case .failed = store.phase {
                    answer.give(.failed)
                } else {
                    answer.give(store.cursor == before ? .noData : .newData)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(25))
                answer.give(.failed)
            }
        }
    }

    // An action chosen on a reminder's notification. The change goes through the outbox, so it
    // also holds without a connection. The system gives a background launch about half a
    // minute; a server that does not answer is given up on after 15 seconds.
    private func carryOut(_ action: Reminders.Action, itemID: Int) async {
        guard let store, !store.isClosed else { return }
        switch action {
        case .done: store.complete(itemID)
        case .inAnHour: store.remind(itemID, at: Date.now.addingTimeInterval(3600))
        case .tomorrow: store.remindTomorrow(itemID)
        }
        // Before the sync: the app may be ended at any moment after this returns, and the
        // moved reminder has to be waiting by then.
        await Reminders.shared.schedule(store.openItems, isCurrent: store.isCurrent, projectName: store.projectName)
        await store.sync()
        guard !store.isClosed else { return }
        await Reminders.shared.schedule(store.openItems, isCurrent: store.isCurrent, projectName: store.projectName)
        await SpotlightFeed.shared.flush(store)
    }

    // A tick on a row of a widget, carried out like "Done" on a notification. The widget names
    // the server its rows came from: left over from another pairing, the number means another
    // item here.
    private func completeFromWidget(_ itemID: Int, due: Due?, server: String) async {
        guard let store, !store.isClosed, connection?.server.absoluteString == server else { return }
        // A repeating item stays open when it is completed and moves to its next date. The
        // widget may still show a date that another device has ticked off, and a tick for it
        // would then complete the next one. So the server is asked first, and the tick only
        // counts for the date it was made on. Without a connection it counts for what this
        // device knows, as a tick in the app does.
        if store.item(itemID)?.repeatRule != nil {
            await store.sync()
            guard !store.isClosed, Self.isSame(store.item(itemID)?.dueAt, due) else { return }
        }
        await carryOut(.done, itemID: itemID)
    }

    // A time has passed through text on its way to the widget and back, which keeps whole
    // seconds.
    private static func isSame(_ lhs: Due?, _ rhs: Due?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.day(let left), .day(let right)): left == right
        case (.time(let left), .time(let right)): abs(left.timeIntervalSince(right)) < 1
        default: false
        }
    }

    private var api: APIClient? {
        connection.map { APIClient(baseURL: $0.server, token: $0.token) }
    }

    private func openStore() {
        guard let connection, let api else {
            store = nil
            agents = nil
            Reminders.shared.server = nil
            Push.shared.isWanted = false
            WidgetFeed.shared.clear()
            SpotlightFeed.shared.clear()
            SharedDrops.setPairing(nil)
            return
        }
        Reminders.shared.server = connection.server.absoluteString
        // The share extension adds only while the app is paired, and only for this server.
        SharedDrops.setPairing(SharedPairing(server: connection.server.absoluteString))
        // The development server from `-apiURL` knows no device to send a push to.
        Push.shared.isWanted = connection.token != nil
        let store = Store(api: api, disk: LocalStore(server: connection.server))
        if connection.token != nil {
            store.onUnauthorized = { [weak self] in self?.lostPairing() }
        }
        self.store?.close()
        self.store = store
        agents?.close()
        let agents = AgentBoard(api: api)
        if connection.token != nil {
            agents.onUnauthorized = { [weak self] in self?.lostPairing() }
        }
        self.agents = agents
    }

    // MARK: Pairing

    // The address as typed, as the base of the API: "pendenz.example.com" means https.
    static func server(from text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let typed = URLComponents(string: text), let host = typed.host, !host.isEmpty else {
            throw PairingError.address
        }
        var base = URLComponents()
        base.scheme = typed.scheme?.lowercased()
        base.host = host.lowercased()
        base.port = typed.port
        guard let url = base.url else { throw PairingError.address }
        // The token travels with every request, so it only goes over TLS. A server on this
        // device is the exception, for development.
        let isLocal = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard base.scheme == "https" || (base.scheme == "http" && isLocal) else {
            throw PairingError.insecure
        }
        return url
    }

    static var defaultDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model
        #endif
    }

    // Trades a pairing code for this device's token and opens the store of that server.
    func pair(server text: String, code: String, name: String) async throws {
        let server = try Self.server(from: text)
        let pairing = try await APIClient(baseURL: server).pair(code: code, name: name)
        let connection = Connection(
            server: server, token: pairing.token, deviceID: pairing.device.id, deviceName: pairing.device.name,
        )
        guard let data = try? JSONEncoder().encode(connection), Keychain.save(data) else {
            throw PairingError.keychain
        }
        UserDefaults.standard.set(server.absoluteString, forKey: "server")
        notice = nil
        self.connection = connection
        openStore()
        SharedDropsIntake.shared.start()
    }

    // Removes everything of this pairing from the device, then takes the device off the server.
    // In that order: an answer that arrives in between then finds nothing left to act on.
    func unpair() async {
        guard let connection, let api, connection.token != nil else { return }
        store?.erase()
        agents?.erase()
        // Shares that wait for the outbox go with it. The pairing first, so the share sheet
        // cannot leave a new one in between.
        SharedDrops.setPairing(nil)
        SharedDrops.removeAll()
        close()
        var isRevoked = false
        if let id = connection.deviceID {
            do {
                try await api.revoke(device: id)
                isRevoked = true
            } catch APIError.status(401, _) {
                // Already revoked from elsewhere.
                isRevoked = true
            } catch {}
        }
        // Unless the device was paired again while the request was on its way.
        if self.connection == nil, !isRevoked {
            notice = "The server could not be reached, so it still lists this device. Revoke it from another device."
        }
    }

    // The server refused this device's token: it was revoked. What is stored here stays, and
    // is used again when the device is paired with the same server.
    func lostPairing() {
        guard connection?.token != nil else { return }
        close()
        notice = "This device is no longer paired with the server. Pair it again with a new code."
    }

    private func close() {
        Keychain.delete()
        notice = nil
        connection = nil
        store?.close()
        store = nil
        // Unlike the items, the reports of a pairing that ended are not kept: they say what an
        // agent's machine runs and spends, and a new pairing fetches them again.
        agents?.erase()
        agents = nil
        // The widgets and Spotlight show nothing of a pairing that has ended.
        WidgetFeed.shared.clear()
        SpotlightFeed.shared.clear()
        // A revoked device keeps its waiting shares, as it keeps its outbox, for a pairing with
        // the same server. Nothing new is shared until then.
        SharedDrops.setPairing(nil)
        Reminders.shared.server = nil
        // The server drops the push token with the device. A push that still arrives finds no
        // store and does nothing.
        Push.shared.isWanted = false
        pushRegistration = nil
        Task { await Reminders.shared.clear() }
    }

    // MARK: Devices

    // These ask the server directly: a list of devices means nothing without it.
    func devices() async throws -> DeviceList {
        try await call { try await $0.devices() }
    }

    func pairingCode() async throws -> PairingCode {
        try await call { try await $0.pairingCode() }
    }

    func revoke(_ device: Device) async throws {
        try await call { try await $0.revoke(device: device.id) }
    }

    // MARK: Agents

    // Asked directly, like the device routes: a code means nothing without the server.
    func agentCode(name: String, access: String) async throws -> AgentCode {
        try await call { try await $0.agentCode(name: name, access: access) }
    }

    func revoke(agent id: String) async throws {
        try await call { try await $0.revoke(agent: id) }
        await agents?.refresh()
    }

    // MARK: Settings of the server

    // Also asked directly, like the devices: the server's settings belong to the server, and a
    // limit set without a connection could not be checked against anything. What the server
    // confirms is kept in the store for the checks made before a file is queued.
    func serverSettings() async throws -> ServerSettings {
        // The store of the pairing that asks. A closed one keeps nothing.
        let store = store
        let settings = try await call { try await $0.settings() }
        store?.keep(settings)
        return settings
    }

    func setFileLimit(_ megabytes: Int) async throws -> ServerSettings {
        let store = store
        let settings = try await call { try await $0.update(fileLimitMb: megabytes) }
        store?.keep(settings)
        return settings
    }

    func setEnergyPrice(_ francs: Double?) async throws -> ServerSettings {
        let store = store
        let settings = try await call { try await $0.update(energyPriceChf: francs) }
        store?.keep(settings)
        return settings
    }

    private func call<Value: Sendable>(_ request: (APIClient) async throws -> Value) async throws -> Value {
        guard let api, let asked = connection else { throw APIError.status(401, nil) }
        do {
            return try await request(api)
        } catch APIError.status(401, let message) {
            // Only the pairing that asked is over. A late answer must not end a newer one.
            if connection == asked { lostPairing() }
            throw APIError.status(401, message)
        }
    }
}

// The one answer to a push, given by whichever comes first: the sync or the deadline.
private final class PushAnswer {
    var continuation: CheckedContinuation<Push.Outcome, Never>?

    func give(_ outcome: Push.Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

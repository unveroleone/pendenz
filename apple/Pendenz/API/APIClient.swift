import Foundation

nonisolated struct ChangePage: Sendable, Decodable {
    let cursor: Int
    let hasMore: Bool
    let reset: Bool
    let changes: [Change]
    // Missing from a server older than files.
    let settings: ServerSettings?
}

// The settings of the server, the same for every device.
nonisolated struct ServerSettings: Equatable, Sendable, Codable {
    // The largest file that can be added, in megabytes of a million bytes.
    var fileLimitMb: Int
    // The most the limit can be set to.
    var fileLimitCeilingMb: Int

    var fileLimitBytes: Int {
        fileLimitMb * AttachmentFiles.megabyte
    }
}

private nonisolated struct SettingsPatch: Encodable {
    let fileLimitMb: Int
}

// One row of the changes feed in its current state.
nonisolated enum Change: Sendable, Decodable {
    case item(Item)
    case project(Project)
    case note(Note)
    case comment(Comment)
    case other

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "item": self = try .item(container.decode(Item.self, forKey: .data))
        case "project": self = try .project(container.decode(Project.self, forKey: .data))
        case "note": self = try .note(container.decode(Note.self, forKey: .data))
        case "comment": self = try .comment(container.decode(Comment.self, forKey: .data))
        default: self = .other
        }
    }
}

nonisolated enum APIError: LocalizedError {
    case status(Int, String?)
    // A change refused by a server older than `ServerVersion.minimum`. Most likely it does not
    // know the route, the method or a field yet, so the refusal does not count until the
    // server is updated.
    case outdated(ServerVersion, String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let message): message ?? "The server answered with status \(code)."
        case .outdated(_, let message): message
        }
    }
}

// The body of an error answer: {"error": "..."}.
private nonisolated struct Failure: Decodable {
    let error: String
}

private nonisolated struct Detail: Decodable {
    let item: Item
}

private nonisolated struct CommentDetail: Decodable {
    let comments: [Comment]
}

private nonisolated struct Workspace: Decodable {
    let actors: [Author]
}

private nonisolated struct NoteDetail: Decodable {
    let note: Note
}

// The version next to the fields of an edit, in one JSON object.
private nonisolated struct Versioned<Patch: Encodable>: Encodable {
    let version: Int
    let patch: Patch

    private enum CodingKeys: String, CodingKey {
        case version
    }

    func encode(to encoder: Encoder) throws {
        try patch.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
    }
}

// A device as the server lists it.
nonisolated struct Device: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
    let createdAt: String
    let lastUsedAt: String?
}

nonisolated struct DeviceList: Sendable, Decodable {
    let devices: [Device]
    // The device that asked, when it asked with the token of a paired device.
    let current: String?
}

nonisolated struct PairingCode: Sendable, Decodable {
    let code: String
    let expiresAt: String
}

// What a new device gets for its pairing code.
nonisolated struct Pairing: Sendable, Decodable {
    nonisolated struct Paired: Sendable, Decodable {
        let id: String
        let name: String
    }

    let token: String
    let device: Paired
}

private nonisolated struct PairRequest: Encodable {
    let code: String
    let name: String
}

private nonisolated struct PushRegistration: Encodable {
    let token: String
    let environment: String
}

private nonisolated struct Registered: Decodable {
    let registered: Bool
}

private nonisolated struct Revoked: Decodable {
    let revoked: Bool
}

// The API never redirects. A redirect is not followed, so the token is not sent to wherever
// it points, and the answer shows up as the error it is.
private final nonisolated class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}

nonisolated struct APIClient: Sendable {
    let baseURL: URL
    // The token of this device. Without one the server only answers in its local mode.
    var token: String?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    // Fetches and decodes off the main actor, so a large first sync does not block scrolling.
    // Also answers with the version of the server.
    @concurrent
    func changes(after cursor: Int) async throws -> (ChangePage, ServerVersion) {
        let url = baseURL.appending(path: "api/changes").appending(queryItems: [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: "500"),
        ])
        let (data, version) = try await exchange(URLRequest(url: url))
        return try (Self.decoder.decode(ChangePage.self, from: data), version)
    }

    private func write(_ method: String, _ path: String, key: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return request
    }

    // The key makes a retry safe: the server answers a repeated request with the row it wrote the
    // first time.
    @concurrent
    func create(_ item: NewItem, key: String) async throws -> Item {
        try await send(write("POST", "api/items", key: key, body: item))
    }

    // The version is the one this device last saw. The server answers 409 when it holds a newer one.
    @concurrent
    func update(_ id: Int, patch: ItemPatch, version: Int, key: String) async throws -> Item {
        try await send(write("PATCH", "api/items/\(id)", key: key, body: Versioned(version: version, patch: patch)))
    }

    // Sends a file as it is, from the disk: the body is the bytes, the name and the upload ID
    // travel in headers. A file can be large, so it is never read into memory. Answers with the
    // item, which lists the new file under the upload ID.
    @concurrent
    func addFile(_ source: URL, _ file: PendingFile, to id: Int, key: String) async throws -> Item {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(id)/files"))
        request.httpMethod = "POST"
        request.setValue(file.mime, forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(Self.headerValue(file.name), forHTTPHeaderField: "Pendenz-File-Name")
        request.setValue(file.id, forHTTPHeaderField: "Pendenz-Upload-Id")
        // The idle time between two packets, as for every request. A slow line that keeps
        // moving is not cut off.
        let (data, response) = try await Self.session.upload(for: authorized(request), fromFile: source)
        _ = try check(request, response, data)
        return try Self.decoder.decode(Item.self, from: data)
    }

    @concurrent
    func removeFile(_ file: Int, from id: Int, key: String) async throws -> Item {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(id)/files/\(file)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request)
    }

    // The bytes of one file, written to a file of the caller's: a temporary one that the caller
    // moves or removes.
    @concurrent
    func file(_ file: Int, of id: Int) async throws -> URL {
        let request = URLRequest(url: baseURL.appending(path: "api/items/\(id)/files/\(file)"))
        let (download, response) = try await Self.session.download(for: authorized(request))
        // The system removes its own file once this returns, so it is moved first.
        let kept = FileManager.default.temporaryDirectory.appending(path: "Download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: download, to: kept)
        do {
            // An error answer is small: its body is the API's message.
            let isError = (response as? HTTPURLResponse)?.statusCode != 200
            _ = try check(request, response, isError ? (try? Data(contentsOf: kept)) ?? Data() : Data())
        } catch {
            try? FileManager.default.removeItem(at: kept)
            throw error
        }
        return kept
    }

    // A name in a header: percent-encoded UTF-8, as the server reads it.
    private static func headerValue(_ name: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "File"
    }

    // MARK: Settings

    @concurrent
    func settings() async throws -> ServerSettings {
        try await send(URLRequest(url: baseURL.appending(path: "api/settings")))
    }

    // Sets the largest file. Asked directly and never queued: a setting means nothing without
    // the server. Sending the same value again does no harm.
    @concurrent
    func update(fileLimitMb: Int) async throws -> ServerSettings {
        var request = URLRequest(url: baseURL.appending(path: "api/settings"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(SettingsPatch(fileLimitMb: fileLimitMb))
        return try await send(request)
    }

    @concurrent
    func create(_ project: NewProject, key: String) async throws -> Project {
        try await send(write("POST", "api/projects", key: key, body: project))
    }

    @concurrent
    func update(project id: String, patch: ProjectPatch, key: String) async throws -> Project {
        try await send(write("PATCH", "api/projects/\(id)", key: key, body: patch))
    }

    // Answers with the project's row, now marked as deleted.
    @concurrent
    func delete(project id: String, key: String) async throws -> Project {
        var request = URLRequest(url: baseURL.appending(path: "api/projects/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request)
    }

    @concurrent
    func create(_ note: NewNote, key: String) async throws -> Note {
        try await send(write("POST", "api/notes", key: key, body: note))
    }

    @concurrent
    func update(note id: Int, patch: NotePatch, version: Int, key: String) async throws -> Note {
        try await send(write("PATCH", "api/notes/\(id)", key: key, body: Versioned(version: version, patch: patch)))
    }

    @concurrent
    func note(_ id: Int) async throws -> Note {
        let detail: NoteDetail = try await send(URLRequest(url: baseURL.appending(path: "api/notes/\(id)")))
        return detail.note
    }

    @concurrent
    func item(_ id: Int) async throws -> Item {
        let url = baseURL.appending(path: "api/items/\(id)").appending(queryItems: [
            URLQueryItem(name: "activity", value: "0"),
        ])
        let detail: Detail = try await send(URLRequest(url: url))
        return detail.item
    }

    // The comments of an item as the server holds them now, without the deleted ones.
    @concurrent
    func comments(of id: Int) async throws -> [Comment] {
        let url = baseURL.appending(path: "api/items/\(id)").appending(queryItems: [
            URLQueryItem(name: "activity", value: "0"),
        ])
        let detail: CommentDetail = try await send(URLRequest(url: url))
        return detail.comments
    }

    @concurrent
    func update(comment id: Int, of itemID: Int, patch: CommentPatch, version: Int, key: String) async throws
        -> Comment
    {
        try await send(write(
            "PATCH", "api/items/\(itemID)/comments/\(id)", key: key, body: Versioned(version: version, patch: patch),
        ))
    }

    // Answers with the comment's row, now marked as deleted.
    @concurrent
    func delete(comment id: Int, of itemID: Int, key: String) async throws -> Comment {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(itemID)/comments/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request)
    }

    // Who writes on this server: the owner and the agents, with their names.
    @concurrent
    func authors() async throws -> [Author] {
        let workspace: Workspace = try await send(URLRequest(url: baseURL.appending(path: "api/bootstrap")))
        return workspace.actors
    }

    // MARK: Devices

    // Trades a pairing code for this device's token. The one request without a token.
    @concurrent
    func pair(code: String, name: String) async throws -> Pairing {
        var request = URLRequest(url: baseURL.appending(path: "api/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(code: code, name: name))
        return try await send(request)
    }

    @concurrent
    func devices() async throws -> DeviceList {
        try await send(URLRequest(url: baseURL.appending(path: "api/devices")))
    }

    @concurrent
    func pairingCode() async throws -> PairingCode {
        var request = URLRequest(url: baseURL.appending(path: "api/pairing-codes"))
        request.httpMethod = "POST"
        return try await send(request)
    }

    @concurrent
    func revoke(device id: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/devices/\(id)"))
        request.httpMethod = "DELETE"
        let _: Revoked = try await send(request)
    }

    // Tells the server where to send this device's pushes. Sending the same again does no harm.
    @concurrent
    func registerPush(token: String, environment: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/push-token"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PushRegistration(token: token, environment: environment))
        let _: Registered = try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        try await Self.decoder.decode(Response.self, from: load(request))
    }

    // The body of a successful answer. Anything else is thrown with the API's own message.
    private func load(_ request: URLRequest) async throws -> Data {
        try await exchange(request).0
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, ServerVersion) {
        let (data, response) = try await Self.session.data(for: authorized(request))
        return try (data, check(request, response, data))
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // The version of the server, for an answer that succeeded. Anything else is thrown with the
    // API's own message. Every request goes through here, whether its body came from memory or
    // from a file.
    private func check(_ request: URLRequest, _ response: URLResponse, _ data: Data) throws -> ServerVersion {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let version = ServerVersion(header: http?.value(forHTTPHeaderField: "Pendenz-Version"))
        guard status == 200 else {
            let message = (try? Self.decoder.decode(Failure.self, from: data))?.error
            // An older server answers a route it does not know with 404, a method with 405 and
            // a field with 400. Only writes count: they are what waits in the outbox. An answer
            // without the API's own message did not come from the API.
            if let message, (request.httpMethod ?? "GET") != "GET", [400, 404, 405].contains(status),
               version < .minimum
            {
                throw APIError.outdated(version, message)
            }
            throw APIError.status(status, message)
        }
        return version
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // A reminder time arrives as "2026-11-13T09:00:00+01:00".
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

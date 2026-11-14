import Foundation

nonisolated struct ChangePage: Sendable, Decodable {
    let cursor: Int
    let hasMore: Bool
    let reset: Bool
    let changes: [Change]
}

// One row of the changes feed in its current state. Comments are skipped until the item detail
// shows them.
nonisolated enum Change: Sendable, Decodable {
    case item(Item)
    case project(Project)
    case note(Note)
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
        default: self = .other
        }
    }
}

nonisolated enum APIError: LocalizedError {
    case status(Int, String?)

    var errorDescription: String? {
        switch self {
        case .status(let code, let message): message ?? "The server answered with status \(code)."
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

private nonisolated struct ImageUpload: Encodable {
    let mime: String
    let data: String
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
    @concurrent
    func changes(after cursor: Int) async throws -> ChangePage {
        let url = baseURL.appending(path: "api/changes").appending(queryItems: [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: "500"),
        ])
        return try await send(URLRequest(url: url))
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

    // Answers with the item, which lists the new image. No version: an image is added to the
    // item as it is, like a comment.
    @concurrent
    func addImage(_ jpeg: Data, to id: Int, key: String) async throws -> Item {
        let body = ImageUpload(mime: "image/jpeg", data: jpeg.base64EncodedString())
        return try await send(write("POST", "api/items/\(id)/images", key: key, body: body))
    }

    @concurrent
    func removeImage(_ image: Int, from id: Int, key: String) async throws -> Item {
        var request = URLRequest(url: baseURL.appending(path: "api/items/\(id)/images/\(image)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return try await send(request)
    }

    // The bytes of one image.
    @concurrent
    func image(_ image: Int, of id: Int) async throws -> Data {
        try await load(URLRequest(url: baseURL.appending(path: "api/items/\(id)/images/\(image)")))
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
        var request = request
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError.status(status, (try? Self.decoder.decode(Failure.self, from: data))?.error)
        }
        return data
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // A reminder time arrives as "2026-11-13T09:00:00+01:00".
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

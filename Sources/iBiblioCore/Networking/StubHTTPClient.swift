import Foundation

/// Canned-response `HTTPClient` used by unit tests and by the app's offline
/// demo mode (so the app is fully explorable with no backend at all).
public actor StubHTTPClient: HTTPClient {

    /// One canned reply.
    public struct Reply: Sendable {
        public var statusCode: Int
        public var body: Data
        public var headers: [String: String]

        public init(statusCode: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }

        public static func json(_ value: some Encodable, statusCode: Int = 200) -> Reply {
            Reply(
                statusCode: statusCode,
                body: ((try? JSONEncoder.json.encode(value)) ?? Data()),
                headers: ["Content-Type": "application/json"]
            )
        }

        public static func text(_ value: String, statusCode: Int = 200) -> Reply {
            Reply(statusCode: statusCode, body: Data(value.utf8), headers: ["Content-Type": "text/plain"])
        }
    }

    private var replies: [String: Reply] = [:]
    private var errors: [String: HTTPError] = [:]

    /// Every request this client received, for assertions in tests.
    public private(set) var recordedRequests: [HTTPRequest] = []

    public init() {}

    // MARK: - Stubbing

    public func stub(_ url: URL, with reply: Reply) {
        replies[url.absoluteString] = reply
    }

    public func stub(_ urlString: String, with reply: Reply) {
        replies[urlString] = reply
    }

    public func stub(_ url: URL, with error: HTTPError) {
        errors[url.absoluteString] = error
    }

    public func reset() {
        replies = [:]
        errors = [:]
        recordedRequests = []
    }

    // MARK: - HTTPClient
    //
    // Not marked `nonisolated`: every `HTTPClient` requirement is `async`, so
    // actor-isolated implementations satisfy the protocol directly. Marking them
    // nonisolated would forbid reading `replies` / `errors`.

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)

        let key = request.url.absoluteString
        if let error = errors[key] {
            throw error
        }
        guard let reply = replies[key] else {
            throw HTTPError.status(
                code: 404,
                body: "StubHTTPClient has no reply registered for \(key)"
            )
        }
        return HTTPResponse(statusCode: reply.statusCode, headers: reply.headers, body: reply.body)
    }

    public func data(from url: URL) async throws -> Data {
        try await send(HTTPRequest(method: .get, url: url)).body
    }

    public func download(from url: URL, to destination: URL) async throws {
        let data = try await data(from: url)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }
}

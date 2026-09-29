import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct HTTPRequest: Sendable {

    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        method: HTTPMethod = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Appends a bearer token if one is supplied.
    public func authorized(with token: AuthToken?) -> HTTPRequest {
        guard let token else { return self }
        var copy = self
        copy.headers["Authorization"] = token.authorizationHeaderValue
        return copy
    }
}

public struct HTTPResponse: Sendable {

    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public var bodyAsString: String {
        String(data: body, encoding: .utf8) ?? "<non-UTF8 body, \(body.count) bytes>"
    }

    public func decoded<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = .json
    ) throws -> T {
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw HTTPError.decodingFailed(
                reason: String(describing: error),
                bodyPreview: String(decoding: body.prefix(512), as: UTF8.self)
            )
        }
    }
}

public enum HTTPError: Error, Sendable, Equatable {
    case invalidURL(String)
    case transport(String)
    case status(code: Int, body: String)
    case decodingFailed(reason: String, bodyPreview: String)
}

/// Abstraction over the network so the whole core stays testable on Windows.
///
/// Deliberately *not* `URLSession`-typed: this lets tests inject canned
/// responses without spinning up a server, and keeps the Readium-free core
/// portable across platforms with different networking stacks.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func data(from url: URL) async throws -> Data
    func download(from url: URL, to destination: URL) async throws
}

extension HTTPClient {

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(HTTPRequest(method: .get, url: url, headers: headers))
    }

    /// Throws `HTTPError.status` unless the response is 2xx.
    public func sendExpectingSuccess(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await send(request)
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, body: response.bodyAsString)
        }
        return response
    }
}

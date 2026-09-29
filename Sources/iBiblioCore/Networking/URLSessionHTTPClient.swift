import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPClient` backed by `URLSession`.
///
/// Uses completion handlers wrapped in `withCheckedThrowingContinuation` rather
/// than `URLSession.data(for:)`, because the async `URLSession` APIs are not
/// uniformly available across swift-corelibs-foundation (used on Windows) and
/// Apple's Foundation. Completion handlers work identically on both.
public struct URLSessionHTTPClient: HTTPClient {

    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = "iBiblioDemo/1.0 (iOS)") {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        #if !os(Windows)
        // `waitsForConnectivity` is read-only in swift-corelibs-foundation, so it
        // can only be set on Apple platforms.
        configuration.waitsForConnectivity = true
        #endif
        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public init(session: URLSession) {
        self.session = session
        self.userAgent = "iBiblioDemo/1.0"
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: HTTPError.transport(error.localizedDescription))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: HTTPError.transport("Non-HTTP response received"))
                    return
                }

                var headers: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    if let key = key as? String {
                        headers[key] = String(describing: value)
                    }
                }

                continuation.resume(
                    returning: HTTPResponse(
                        statusCode: httpResponse.statusCode,
                        headers: headers,
                        body: data ?? Data()
                    )
                )
            }.resume()
        }
    }

    public func data(from url: URL) async throws -> Data {
        let response = try await send(HTTPRequest(method: .get, url: url))
        guard response.isSuccess else {
            throw HTTPError.status(code: response.statusCode, body: response.bodyAsString)
        }
        return response.body
    }

    public func download(from url: URL, to destination: URL) async throws {
        let temporaryURL: URL
        do {
            (temporaryURL, _) = try await session.download(from: url)
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let parent = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }
}

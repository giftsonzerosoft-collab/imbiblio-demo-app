import Foundation
import XCTest
@testable import iBiblioCore

/// Thread-safe sink for values produced by callbacks that may fire on an
/// arbitrary executor (`SessionStore.onChange`, `UploadService.upload(onState:)`).
///
/// Being an actor is what makes the tests deterministic: the callbacks are
/// `async`, so a plain array would be a data race.
actor ValueRecorder<Value> {

    private(set) var values: [Value] = []

    init() {}

    func append(_ value: Value) {
        values.append(value)
    }

    /// For polling callbacks: yields briefly so pending `Task`s can enqueue.
    func snapshot(settlingNanoseconds: UInt64 = 50_000_000) async -> [Value] {
        if settlingNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: settlingNanoseconds)
        }
        return values
    }
}

typealias SessionStateRecorder = ValueRecorder<SessionState>
typealias UploadStateRecorder = ValueRecorder<UploadState>

// MARK: - Async-safe assertions

/// `XCTUnwrap` takes a *non-async* autoclosure, so `await` cannot appear inside
/// it. Tests use this instead of `try XCTUnwrap(await client.recordedRequests.first)`.
func requireFirstRequest(
    _ http: StubHTTPClient,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> HTTPRequest {
    let requests = await http.recordedRequests
    guard let request = requests.first else {
        XCTFail("expected StubHTTPClient to record a request", file: file, line: line)
        throw TestSupportError.noRecordedRequest
    }
    return request
}

enum TestSupportError: Error {
    case noRecordedRequest
}

// MARK: - Fixtures

enum TestFixtures {

    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func token(
        accessToken: String = "at",
        refreshToken: String? = "rt",
        expiresIn: TimeInterval = 3600,
        idToken: String? = nil
    ) -> AuthToken {
        AuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "Bearer",
            expiresAt: referenceDate.addingTimeInterval(expiresIn),
            scope: "openid profile",
            idToken: idToken
        )
    }

    /// A scratch directory that is removed when `defer`red.
    static func makeTemporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibiblio-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a file with the given contents and returns its URL.
    @discardableResult
    static func writeFile(
        named name: String,
        contents: String = "payload",
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

// MARK: - Utilities

extension Data {
    /// `Data.range(of:)` exists on Apple platforms but its behaviour differs on
    /// swift-corelibs-foundation, so containment is checked explicitly.
    func containsSubsequence(_ needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        let haystack = [UInt8](self)
        let target = [UInt8](needle)
        for start in 0...(haystack.count - target.count) {
            if Array(haystack[start..<(start + target.count)]) == target {
                return true
            }
        }
        return false
    }
}

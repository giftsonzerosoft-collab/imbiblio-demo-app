import Foundation

/// Presents an authorization URL in a system browser and returns the callback.
///
/// On iOS this is backed by `ASWebAuthenticationSession`; see
/// `App/Sources/Support/WebAuthSessionPresenter.swift`. Keeping it behind a
/// protocol means the whole OIDC flow below is exercised by unit tests on
/// Windows with a stub presenter.
public protocol WebAuthSessionPresenting: Sendable {
    /// - Parameters:
    ///   - url: the authorization endpoint URL to open.
    ///   - callbackURLScheme: scheme the callback will use, e.g. `"ibiblio"`.
    /// - Returns: the callback URL the provider redirected to.
    /// - Throws: `AuthError.cancelled` if the user dismisses the sheet.
    func presentAuthorizationURL(_ url: URL, callbackURLScheme: String) async throws -> URL
}

/// A `WebAuthSessionPresenting` that returns a canned callback URL.
///
/// Used by the iBiblioCore test suite and by the app's `-useMockAuth` mode.
public struct StubWebAuthPresenter: WebAuthSessionPresenting {

    private let handler: @Sendable (URL) async throws -> URL
    private let captured: CapturedURLs

    /// Thread-safe recorder so tests can assert on the generated URL.
    public final class CapturedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        public init() {}

        public var urls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        public var last: URL? {
            lock.lock(); defer { lock.unlock() }
            return storage.last
        }

        fileprivate func append(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            storage.append(url)
        }
    }

    public init(captured: CapturedURLs = CapturedURLs()) {
        self.captured = captured
        self.handler = { url in
            captured.append(url)
            throw AuthError.authorizationFailed(
                reason: "StubWebAuthPresenter has no callback configured"
            )
        }
    }

    /// Returns `callback` for the next `presentAuthorizationURL` call.
    public init(capturing captured: CapturedURLs = CapturedURLs(),
                returning callback: @escaping @Sendable (URL) -> URL) {
        self.captured = captured
        self.handler = { url in
            captured.append(url)
            return callback(url)
        }
    }

    /// Fails the next call with `error` (e.g. `AuthError.cancelled`).
    public init(capturing captured: CapturedURLs = CapturedURLs(),
                throwing error: @escaping @Sendable (URL) -> AuthError) {
        self.captured = captured
        self.handler = { url in
            captured.append(url)
            throw error(url)
        }
    }

    public func presentAuthorizationURL(_ url: URL, callbackURLScheme: String) async throws -> URL {
        try await handler(url)
    }
}

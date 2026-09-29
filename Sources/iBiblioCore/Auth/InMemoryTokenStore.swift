import Foundation

/// In-memory `TokenStore` for tests and previews.
public actor InMemoryTokenStore: TokenStore {

    private var token: AuthToken?
    private var failNextWrite: Bool

    public init(initialToken: AuthToken? = nil) {
        self.token = initialToken
        self.failNextWrite = false
    }

    public func load() async throws -> AuthToken? { token }
    public func save(_ token: AuthToken) async throws {
        if failNextWrite { throw AuthError.tokenStoreFailure("InMemoryTokenStore configured to fail") }
        self.token = token
    }
    public func clear() async throws { token = nil }

    /// Forces the next `save` to throw, for error-path testing.
    public func setFailingWrites(_ failing: Bool) { failNextWrite = failing }
}

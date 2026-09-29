import Foundation

/// Persistence for the current `AuthToken`.
///
/// Backed by the Keychain on iOS and by a JSON file elsewhere, so the
/// `SessionStore` logic that consumes this protocol is identical (and testable)
/// on both platforms.
public protocol TokenStore: Sendable {
    func load() async throws -> AuthToken?
    func save(_ token: AuthToken) async throws
    func clear() async throws
}

extension TokenStore {
    /// Loads the token, treating any storage failure as "no token" so a corrupt
    /// or inaccessible store can never lock the user out of the login screen.
    public func loadIgnoringErrors() async -> AuthToken? {
        try? await load()
    }
}

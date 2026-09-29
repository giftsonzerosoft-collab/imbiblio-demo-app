import Foundation

/// Errors surfaced by every authentication path.
public enum AuthError: Error, Sendable, Equatable {
    /// No issuer/endpoint/client-id configured — usually a missing Info.plist key.
    case notConfigured
    /// The user dismissed the system browser sheet.
    case cancelled
    /// The callback URL did not match the expected scheme/state, or the server
    /// returned an `error` / `error_description` parameter.
    case authorizationFailed(reason: String)
    /// The callback carried no authorization code.
    case missingAuthorizationCode
    /// The token endpoint returned a body we could not parse.
    case invalidTokenResponse(underlying: String)
    /// The token endpoint returned a non-2xx status.
    case tokenEndpointFailure(statusCode: Int, body: String)
    /// Refresh was requested but the token carries no refresh token.
    case cannotRefresh
    /// The token store is unavailable (e.g. no writable container).
    case tokenStoreFailure(String)
}

/// Source of `AuthToken`s.
///
/// The app ships three implementations: `OIDCAuthProvider` (real), and
/// `MockAuthProvider` (offline demo / UI tests). Adding a username+password
/// backend later means writing one more conformance here and nothing else.
public protocol AuthProvider: Sendable {
    /// Runs the interactive login flow and returns a fresh token.
    func authorize() async throws -> AuthToken
    /// Exchanges a refresh token for a new access token.
    func refresh(_ token: AuthToken) async throws -> AuthToken
    /// Revokes/clears credentials.
    func signOut(_ token: AuthToken?) async
}

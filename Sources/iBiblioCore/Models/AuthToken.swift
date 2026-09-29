import Foundation

/// An OAuth 2.0 / OpenID Connect bearer token.
///
/// This is a pure value type with no Apple-only dependencies so that the entire
/// authentication flow (parsing, expiry, refresh) is unit-testable on Windows.
public struct AuthToken: Codable, Equatable, Sendable {

    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let expiresAt: Date
    public let scope: String?
    public let idToken: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date,
        scope: String? = nil,
        idToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scope = scope
        self.idToken = idToken
    }

    // MARK: - Expiry

    /// Seconds of "slack" applied when checking expiry so that a token does not
    /// expire in-flight between the check and the request that uses it.
    public static let defaultLeeway: TimeInterval = 30

    public func isExpired(
        at date: Date = Date(),
        leeway: TimeInterval = AuthToken.defaultLeeway
    ) -> Bool {
        date.addingTimeInterval(leeway) >= expiresAt
    }

    public func isUsable(at date: Date = Date(), leeway: TimeInterval = AuthToken.defaultLeeway) -> Bool {
        !isExpired(at: date, leeway: leeway)
    }

    /// Value for the `Authorization` request header.
    public var authorizationHeaderValue: String {
        "\(tokenType) \(accessToken)"
    }

    public var canBeRefreshed: Bool {
        refreshToken != nil
    }
}

// MARK: - Parsing an OAuth token endpoint response

extension AuthToken {

    /// Wire format returned by an RFC 6749 token endpoint.
    struct TokenEndpointResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String?
        let expiresIn: Double?
        let scope: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case scope
            case idToken = "id_token"
        }
    }

    /// Parses a token endpoint response body.
    ///
    /// `expires_in` is relative to `receivedAt`, so the absolute `expiresAt` is
    /// computed at parse time rather than at use time. When the server omits
    /// `expires_in` we fall back to `defaultLifetime`, matching the behaviour of
    /// most clients in the wild.
    public static let defaultLifetime: TimeInterval = 60 * 60

    public static func parse(
        tokenEndpointResponse data: Data,
        receivedAt: Date = Date(),
        decoder: JSONDecoder = .json
    ) throws -> AuthToken {
        let response: TokenEndpointResponse
        do {
            response = try decoder.decode(TokenEndpointResponse.self, from: data)
        } catch {
            throw AuthError.invalidTokenResponse(underlying: String(describing: error))
        }

        let lifetime = response.expiresIn ?? defaultLifetime
        return AuthToken(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            tokenType: response.tokenType ?? "Bearer",
            expiresAt: receivedAt.addingTimeInterval(lifetime),
            scope: response.scope,
            idToken: response.idToken
        )
    }
}

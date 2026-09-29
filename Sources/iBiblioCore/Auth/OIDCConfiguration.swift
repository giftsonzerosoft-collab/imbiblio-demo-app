import Foundation

/// Endpoints and client identifiers for the authorization server.
public struct OIDCConfiguration: Sendable, Equatable {

    public var issuer: URL
    public var authorizeEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]

    public init(
        issuer: URL,
        authorizeEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String] = ["openid", "profile", "offline_access"]
    ) {
        self.issuer = issuer
        self.authorizeEndpoint = authorizeEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// Standard discovery-based endpoints, for issuers that follow
    /// `https://<host>/.well-known/openid-configuration` layout.
    public init(issuer: URL, clientID: String, redirectURI: String, scopes: [String] = ["openid", "profile", "offline_access"]) {
        self.init(
            issuer: issuer,
            authorizeEndpoint: issuer.appendingPathComponent("authorize"),
            tokenEndpoint: issuer.appendingPathComponent("token"),
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: scopes
        )
    }

    /// The scheme the callback URL must carry, e.g. `"ibiblio"` for
    /// `ibiblio://oauth/callback`. Returned by `ASWebAuthenticationSession`.
    public var callbackURLScheme: String? {
        guard let scheme = URL(string: redirectURI)?.scheme else { return nil }
        return scheme
    }

    public var scopeValue: String {
        scopes.joined(separator: " ")
    }

    /// Reads configuration from an `Info.plist`-style dictionary, applying
    /// defaults so the demo runs with no server at all.
    ///
    /// Recognised keys: `OIDCIssuer`, `OIDCAuthorizeURL`, `OIDCTokenURL`,
    /// `OIDCClientID`, `OIDCRedirectURI`, `OIDCScopes`.
    public static func fromInfoDictionary(
        _ info: [String: String],
        defaults: OIDCConfiguration
    ) -> OIDCConfiguration {
        func url(_ key: String) -> URL? {
            guard let raw = info[key], !raw.isEmpty else { return nil }
            return URL(string: raw)
        }

        let scopes = info["OIDCScopes"]
            .map { $0.split(separator: " ").map(String.init) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return OIDCConfiguration(
            issuer: url("OIDCIssuer") ?? defaults.issuer,
            authorizeEndpoint: url("OIDCAuthorizeURL") ?? defaults.authorizeEndpoint,
            tokenEndpoint: url("OIDCTokenURL") ?? defaults.tokenEndpoint,
            clientID: info["OIDCClientID"].flatMap { $0.isEmpty ? nil : $0 } ?? defaults.clientID,
            redirectURI: info["OIDCRedirectURI"].flatMap { $0.isEmpty ? nil : $0 } ?? defaults.redirectURI,
            scopes: scopes ?? defaults.scopes
        )
    }

    /// The configuration used by the demo when no real server is configured.
    public static let demo = OIDCConfiguration(
        issuer: URL(string: "https://auth.example.invalid")!,
        authorizeEndpoint: URL(string: "https://auth.example.invalid/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example.invalid/token")!,
        clientID: "ibiblio-demo",
        redirectURI: "ibiblio://oauth/callback"
    )
}

import Foundation

/// OAuth 2.0 Authorization Code + PKCE (RFC 6749 §4.1 / RFC 7636).
///
/// Everything in this type is platform-agnostic Foundation: the browser hop is
/// delegated to a `WebAuthSessionPresenting`, and the token calls go through an
/// `HTTPClient`. That is deliberate — it means the entire login flow, including
/// state validation, error mapping and refresh, is unit-tested on Windows.
public struct OIDCAuthProvider: AuthProvider {

    private let configuration: OIDCConfiguration
    private let httpClient: HTTPClient
    private let presenter: WebAuthSessionPresenting

    /// Injected so tests can assert on expiry without waiting an hour.
    private let now: @Sendable () -> Date

    public init(
        configuration: OIDCConfiguration,
        httpClient: HTTPClient,
        presenter: WebAuthSessionPresenting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.presenter = presenter
        self.now = now
    }

    // MARK: - AuthProvider

    public func authorize() async throws -> AuthToken {
        let state = SecureRandom.hexString()
        let pkce = PKCEPair.generate()

        guard let authorizationURL = try makeAuthorizationURL(state: state, pkce: pkce) else {
            throw AuthError.notConfigured
        }
        guard let callbackScheme = configuration.callbackURLScheme else {
            throw AuthError.notConfigured
        }

        let callbackURL = try await presenter.presentAuthorizationURL(
            authorizationURL,
            callbackURLScheme: callbackScheme
        )

        let parameters = try Self.validateCallback(callbackURL, expectedState: state)
        guard let code = parameters["code"] else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchangeAuthorizationCode(code, verifier: pkce.verifier)
    }

    public func refresh(_ token: AuthToken) async throws -> AuthToken {
        guard let refreshToken = token.refreshToken else {
            throw AuthError.cannotRefresh
        }

        var form = URLEncodedForm()
        form.add("grant_type", "refresh_token")
        form.add("refresh_token", refreshToken)
        form.add("client_id", configuration.clientID)

        let response = try await postTokenRequest(form)

        var refreshed = try AuthToken.parse(tokenEndpointResponse: response.body, receivedAt: now())
        // Servers may omit the refresh token on rotation; keep the old one.
        if refreshed.refreshToken == nil {
            refreshed = AuthToken(
                accessToken: refreshed.accessToken,
                refreshToken: refreshToken,
                tokenType: refreshed.tokenType,
                expiresAt: refreshed.expiresAt,
                scope: refreshed.scope,
                idToken: refreshed.idToken
            )
        }
        return refreshed
    }

    public func signOut(_ token: AuthToken?) async {
        // A pure-OIDC flow has no revocation endpoint in the demo config. The
        // caller clears the `TokenStore`; add `revocation_endpoint` handling here
        // if your provider offers one.
        _ = token
    }

    // MARK: - URL construction

    /// Builds the authorization URL. `nil` means the redirect URI is unusable.
    public func makeAuthorizationURL(state: String, pkce: PKCEPair) throws -> URL? {
        guard var components = URLComponents(
            url: configuration.authorizeEndpoint,
            resolvingAgainstBaseURL: false
        ) else { return nil }

        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: configuration.clientID))
        items.append(URLQueryItem(name: "redirect_uri", value: configuration.redirectURI))
        items.append(URLQueryItem(name: "scope", value: configuration.scopeValue))
        items.append(URLQueryItem(name: "state", value: state))
        items.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        components.queryItems = items

        return components.url
    }

    // MARK: - Callback handling

    /// Validates a redirect against the expected state and decodes its query.
    ///
    /// - Throws: `AuthError.cancelled` when the provider signals a user denial
    ///   (`error=access_denied`), and `AuthError.authorizationFailed` for a
    ///   state mismatch or any other provider-side error.
    public static func validateCallback(_ url: URL, expectedState: String) throws -> [String: String] {
        // A fragment response is legal for the implicit flow; support both.
        let rawQuery = url.query ?? url.fragment ?? ""
        let parameters = URLEncodedForm.decode(rawQuery)

        if let error = parameters["error"] {
            let description = parameters["error_description"] ?? error
            if error == "access_denied" || description.lowercased().contains("cancel") {
                throw AuthError.cancelled
            }
            throw AuthError.authorizationFailed(reason: "\(error): \(description)")
        }

        guard let state = parameters["state"] else {
            throw AuthError.authorizationFailed(reason: "Callback is missing the state parameter")
        }
        // Constant-time comparison is overkill for a public client, but compare
        // the full string so a prefix never passes.
        guard state == expectedState else {
            throw AuthError.authorizationFailed(reason: "state mismatch — possible CSRF")
        }

        return parameters
    }

    // MARK: - Token endpoint

    private func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> AuthToken {
        var form = URLEncodedForm()
        form.add("grant_type", "authorization_code")
        form.add("code", code)
        form.add("redirect_uri", configuration.redirectURI)
        form.add("client_id", configuration.clientID)
        form.add("code_verifier", verifier)

        let response = try await postTokenRequest(form)
        return try AuthToken.parse(tokenEndpointResponse: response.body, receivedAt: now())
    }

    private func postTokenRequest(_ form: URLEncodedForm) async throws -> HTTPResponse {
        let request = HTTPRequest(
            method: .post,
            url: configuration.tokenEndpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: form.encoded()
        )

        let response: HTTPResponse
        do {
            response = try await httpClient.send(request)
        } catch let error as HTTPError {
            throw AuthError.tokenEndpointFailure(
                statusCode: -1,
                body: "\(error)"
            )
        }

        guard response.isSuccess else {
            throw AuthError.tokenEndpointFailure(
                statusCode: response.statusCode,
                body: response.bodyAsString
            )
        }
        return response
    }
}

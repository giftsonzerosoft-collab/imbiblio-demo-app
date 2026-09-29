import XCTest
@testable import iBiblioCore

/// Tests for the full Authorization Code + PKCE flow, driven through a stub
/// browser presenter and a `StubHTTPClient`. This is the part of the app that
/// normally needs a device; here it runs on Windows.
final class OIDCAuthProviderTests: XCTestCase {

    private let configuration = OIDCConfiguration(
        issuer: URL(string: "https://auth.example.test")!,
        authorizeEndpoint: URL(string: "https://auth.example.test/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example.test/token")!,
        clientID: "ibiblio-demo",
        redirectURI: "ibiblio://oauth/callback"
    )

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    /// Builds a provider whose browser hands back `callback` verbatim.
    private func makeProvider(
        callback: @escaping @Sendable (URL) -> URL,
        captured: StubWebAuthPresenter.CapturedURLs = .init()
    ) -> (OIDCAuthProvider, StubHTTPClient) {
        let http = StubHTTPClient()
        let presenter = StubWebAuthPresenter(capturing: captured, returning: callback)
        let provider = OIDCAuthProvider(
            configuration: configuration,
            httpClient: http,
            presenter: presenter,
            now: { self.reference }
        )
        return (provider, http)
    }

    /// Echoes the `state` the provider generated back in a valid callback.
    ///
    /// `static` so it can be passed as an `@Sendable` closure without the
    /// compiler warning about converting a non-Sendable function value -- it
    /// captures nothing, so there is no reason for it to be an instance method.
    private static func echoState(_ url: URL) -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        return URL(string: "ibiblio://oauth/callback?code=auth-code-1&state=\(state)")!
    }

    /// Actor-isolated registration, so this has to be `await`ed by the caller;
    /// a bare `Task` would race the token exchange that follows.
    private func stubTokenEndpoint(_ http: StubHTTPClient, statusCode: Int = 200, body: String) async {
        let reply = StubHTTPClient.Reply(
            statusCode: statusCode,
            body: Data(body.utf8),
            headers: ["Content-Type": "application/json"]
        )
        await http.stub(configuration.tokenEndpoint, with: reply)
    }

    // MARK: - Authorization URL

    func testAuthorizationURLContainsAllRequiredParameters() throws {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, _) = makeProvider(callback: { _ in
            URL(string: "ibiblio://oauth/callback")!
        }, captured: captured)

        let pkce = PKCEPair.generate()
        let url = try XCTUnwrap(provider.makeAuthorizationURL(state: "st-1", pkce: pkce))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let map = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "auth.example.test")
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertEqual(map["response_type"], "code")
        XCTAssertEqual(map["client_id"], "ibiblio-demo")
        XCTAssertEqual(map["redirect_uri"], "ibiblio://oauth/callback")
        XCTAssertEqual(map["scope"], "openid profile offline_access")
        XCTAssertEqual(map["state"], "st-1")
        XCTAssertEqual(map["code_challenge"], pkce.challenge)
        XCTAssertEqual(map["code_challenge_method"], "S256")
    }

    func testCallbackURLSchemeIsDerivedFromRedirectURI() {
        XCTAssertEqual(configuration.callbackURLScheme, "ibiblio")
    }

    // MARK: - Happy path

    func testAuthorizeExchangesCodeForToken() async throws {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, http) = makeProvider(callback: { Self.echoState($0) }, captured: captured)
        await stubTokenEndpoint(http, body: """
        {"access_token":"access-abc","refresh_token":"refresh-xyz","token_type":"Bearer","expires_in":3600}
        """)

        let token = try await provider.authorize()

        XCTAssertEqual(token.accessToken, "access-abc")
        XCTAssertEqual(token.refreshToken, "refresh-xyz")
        XCTAssertEqual(token.expiresAt.timeIntervalSince(reference), 3600, accuracy: 0.001)

        // The browser was opened exactly once.
        XCTAssertEqual(captured.urls.count, 1)

        // And the token request was well formed.
        let requests = await http.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, configuration.tokenEndpoint)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")

        let form = URLEncodedForm.decode(String(decoding: request.body ?? Data(), as: UTF8.self))
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "auth-code-1")
        XCTAssertEqual(form["redirect_uri"], "ibiblio://oauth/callback")
        XCTAssertEqual(form["client_id"], "ibiblio-demo")
        XCTAssertNotNil(form["code_verifier"], "the plaintext verifier must be sent at the token endpoint")
    }

    /// The verifier sent to the token endpoint must be the one whose digest was
    /// put in the authorization URL — that is the whole point of PKCE.
    func testVerifierMatchesTheChallengeThatWasSent() async throws {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, http) = makeProvider(callback: { Self.echoState($0) }, captured: captured)
        await stubTokenEndpoint(http, body: #"{"access_token":"a","expires_in":60}"#)

        _ = try await provider.authorize()

        let authorizationURL = try XCTUnwrap(captured.last)
        let challenge = try XCTUnwrap(
            URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "code_challenge" }?
                .value
        )

        let requests = await http.recordedRequests
        let tokenRequest = try XCTUnwrap(requests.first)
        let form = URLEncodedForm.decode(String(decoding: tokenRequest.body ?? Data(), as: UTF8.self))
        let verifier = try XCTUnwrap(form["code_verifier"])

        XCTAssertEqual(PKCEPair.challenge(for: verifier), challenge)
    }

    func testStateIsRandomisedBetweenCalls() async throws {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, http) = makeProvider(callback: { Self.echoState($0) }, captured: captured)
        await stubTokenEndpoint(http, body: #"{"access_token":"a","expires_in":60}"#)

        _ = try await provider.authorize()
        _ = try await provider.authorize()

        // `CapturedURLs` is lock-protected, so this read is synchronous.
        let states = captured.urls.compactMap { url -> String? in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "state" }?
                .value
        }
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(Set(states).count, 2, "state must differ per authorization request")
    }

    // MARK: - Failure paths

    func testUserCancellationSurfacesAsCancelled() async {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, _) = makeProvider(
            callback: { _ in URL(string: "ibiblio://oauth/callback?error=access_denied&error_description=The+user+said+no")! },
            captured: captured
        )

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .cancelled)
        }
    }

    func testStateMismatchIsRejected() async {
        let (provider, _) = makeProvider(callback: { _ in
            URL(string: "ibiblio://oauth/callback?code=c&state=tampered")!
        })

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            guard case AuthError.authorizationFailed(let reason) = error else {
                return XCTFail("expected authorizationFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("state mismatch"), reason)
        }
    }

    func testMissingCodeIsRejected() async {
        let captured = StubWebAuthPresenter.CapturedURLs()
        let (provider, _) = makeProvider(callback: { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "ibiblio://oauth/callback?state=\(state)")!
        }, captured: captured)

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .missingAuthorizationCode)
        }
    }

    func testPresenterCancellationPropagates() async {
        let presenter = StubWebAuthPresenter { _ in AuthError.cancelled }
        let provider = OIDCAuthProvider(
            configuration: configuration,
            httpClient: StubHTTPClient(),
            presenter: presenter
        )

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .cancelled)
        }
    }

    func testTokenEndpointHTTPErrorIsMapped() async {
        let (provider, http) = makeProvider(callback: { Self.echoState($0) })
        await stubTokenEndpoint(http, statusCode: 401, body: #"{"error":"invalid_grant"}"#)

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            guard case AuthError.tokenEndpointFailure(let status, _) = error else {
                return XCTFail("expected tokenEndpointFailure, got \(error)")
            }
            XCTAssertEqual(status, 401)
        }
    }

    func testUnparseableTokenResponseIsMapped() async {
        let (provider, http) = makeProvider(callback: { Self.echoState($0) })
        await stubTokenEndpoint(http, body: "<html>gateway error</html>")

        do {
            _ = try await provider.authorize()
            XCTFail("expected a throw")
        } catch {
            guard case AuthError.invalidTokenResponse = error else {
                return XCTFail("expected invalidTokenResponse, got \(error)")
            }
        }
    }

    // MARK: - Refresh

    func testRefreshSendsGrantTypeAndRefreshToken() async throws {
        let http = StubHTTPClient()
        let provider = OIDCAuthProvider(
            configuration: configuration,
            httpClient: http,
            presenter: StubWebAuthPresenter(),
            now: { self.reference }
        )
        await stubTokenEndpoint(http, body: #"{"access_token":"new-access","token_type":"Bearer","expires_in":900}"#)

        let stale = AuthToken(
            accessToken: "old",
            refreshToken: "old-refresh",
            expiresAt: reference.addingTimeInterval(-10)
        )
        let refreshed = try await provider.refresh(stale)

        XCTAssertEqual(refreshed.accessToken, "new-access")

        let requests = await http.recordedRequests
        let request = try XCTUnwrap(requests.first)
        let form = URLEncodedForm.decode(String(decoding: request.body ?? Data(), as: UTF8.self))
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "old-refresh")
        XCTAssertEqual(form["client_id"], "ibiblio-demo")
    }

    /// Many servers omit `refresh_token` on rotation; the old one must be kept
    /// or the session becomes unrecoverable after one refresh.
    func testRefreshKeepsOldRefreshTokenWhenServerOmitsIt() async throws {
        let http = StubHTTPClient()
        let provider = OIDCAuthProvider(
            configuration: configuration,
            httpClient: http,
            presenter: StubWebAuthPresenter(),
            now: { self.reference }
        )
        await stubTokenEndpoint(http, body: #"{"access_token":"new-access","expires_in":900}"#)

        let refreshed = try await provider.refresh(
            AuthToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: reference)
        )
        XCTAssertEqual(refreshed.refreshToken, "old-refresh")
    }

    func testRefreshWithoutRefreshTokenThrows() async {
        let provider = OIDCAuthProvider(
            configuration: configuration,
            httpClient: StubHTTPClient(),
            presenter: StubWebAuthPresenter()
        )

        do {
            _ = try await provider.refresh(AuthToken(accessToken: "a", expiresAt: reference))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .cannotRefresh)
        }
    }
}

final class OIDCConfigurationTests: XCTestCase {

    func testDerivedEndpoints() {
        let configuration = OIDCConfiguration(
            issuer: URL(string: "https://id.example.test")!,
            clientID: "c",
            redirectURI: "ibiblio://cb"
        )
        XCTAssertEqual(configuration.authorizeEndpoint.absoluteString, "https://id.example.test/authorize")
        XCTAssertEqual(configuration.tokenEndpoint.absoluteString, "https://id.example.test/token")
    }

    func testScopeJoining() {
        var configuration = OIDCConfiguration.demo
        configuration.scopes = ["openid", "offline_access"]
        XCTAssertEqual(configuration.scopeValue, "openid offline_access")
    }

    func testInfoDictionaryOverridesAndDefaults() {
        let overridden = OIDCConfiguration.fromInfoDictionary(
            [
                "OIDCClientID": "real-client",
                "OIDCTokenURL": "https://real.example.test/token"
            ],
            defaults: .demo
        )
        XCTAssertEqual(overridden.clientID, "real-client")
        XCTAssertEqual(overridden.tokenEndpoint.absoluteString, "https://real.example.test/token")
        XCTAssertEqual(overridden.issuer, OIDCConfiguration.demo.issuer, "unset keys keep the default")
    }

    func testEmptyInfoDictionaryValuesFallBackToDefaults() {
        let configuration = OIDCConfiguration.fromInfoDictionary(
            ["OIDCClientID": "", "OIDCTokenURL": ""],
            defaults: .demo
        )
        XCTAssertEqual(configuration.clientID, OIDCConfiguration.demo.clientID)
    }

    func testScopeOverrideFromSpaceSeparatedString() {
        let configuration = OIDCConfiguration.fromInfoDictionary(
            ["OIDCScopes": "openid email"],
            defaults: .demo
        )
        XCTAssertEqual(configuration.scopes, ["openid", "email"])
    }
}

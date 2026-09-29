import XCTest
@testable import iBiblioCore

final class SessionStoreTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeToken(
        expiresIn: TimeInterval = 3600,
        refresh: String? = "rt"
    ) -> AuthToken {
        AuthToken(
            accessToken: "at",
            refreshToken: refresh,
            expiresAt: reference.addingTimeInterval(expiresIn)
        )
    }

    private func makeStore(
        provider: MockAuthProvider,
        store: TokenStore,
        recorder: SessionStateRecorder? = nil
    ) -> SessionStore {
        SessionStore(
            provider: provider,
            tokenStore: store,
            onChange: { state in
                if let recorder { await recorder.append(state) }
            },
            now: { self.reference }
        )
    }

    // MARK: - Restore

    func testRestoreWithNoStoredTokenLandsSignedOut() async {
        let store = InMemoryTokenStore()
        let session = makeStore(provider: MockAuthProvider(now: { self.reference }), store: store)

        await session.restore()

        let state = await session.state
        XCTAssertEqual(state, .signedOut)
    }

    func testRestoreWithValidStoredTokenLandsSignedIn() async {
        let store = InMemoryTokenStore(initialToken: makeToken())
        let session = makeStore(provider: MockAuthProvider(now: { self.reference }), store: store)

        await session.restore()

        let state = await session.state
        XCTAssertTrue(state.isSignedIn)
        let token = await session.token
        XCTAssertEqual(token?.accessToken, "at")
    }

    func testRestoreWithExpiredButRefreshableTokenRefreshesProactively() async throws {
        let store = InMemoryTokenStore(initialToken: makeToken(expiresIn: -60))
        let provider = MockAuthProvider(now: { self.reference })
        let session = makeStore(provider: provider, store: store)

        await session.restore()

        let refreshes = await provider.refreshCallCount
        XCTAssertEqual(refreshes, 1, "an already-expired token should be refreshed on launch")
        let state = await session.state
        XCTAssertTrue(state.isSignedIn)
    }

    func testRestoreWithExpiredUnrefreshableTokenLandsSignedOut() async {
        let store = InMemoryTokenStore(initialToken: makeToken(expiresIn: -60, refresh: nil))
        let session = makeStore(provider: MockAuthProvider(now: { self.reference }), store: store)

        await session.restore()

        let state = await session.state
        XCTAssertEqual(state, .signedOut)
        let remaining = await store.loadIgnoringErrors()
        XCTAssertNil(remaining, "the dead token should be cleared")
    }

    // MARK: - Sign in

    func testSignInStoresAndPersistsTheToken() async throws {
        let store = InMemoryTokenStore()
        let provider = MockAuthProvider(now: { self.reference })
        let session = makeStore(provider: provider, store: store)

        try await session.signIn()

        let state = await session.state
        XCTAssertTrue(state.isSignedIn)
        let persisted = await store.loadIgnoringErrors()
        XCTAssertEqual(persisted?.accessToken, "mock-access-token-1")
    }

    func testSignInFailureSurfacesAndDoesNotPersist() async {
        let store = InMemoryTokenStore()
        let provider = MockAuthProvider(shouldFail: true, now: { self.reference })
        let session = makeStore(provider: provider, store: store)

        do {
            try await session.signIn()
            XCTFail("expected a throw")
        } catch {
            let state = await session.state
            guard case .failed = state else {
                return XCTFail("expected .failed, got \(state)")
            }
            let persisted = await store.loadIgnoringErrors()
            XCTAssertNil(persisted)
        }
    }

    func testSignInEmitsProgressingStates() async throws {
        let recorder = SessionStateRecorder()
        let provider = MockAuthProvider(now: { self.reference })
        let session = SessionStore(
            provider: provider,
            tokenStore: InMemoryTokenStore(),
            onChange: { state in await recorder.append(state) },
            now: { self.reference }
        )

        try await session.signIn()

        let states = await recorder.snapshot()
        XCTAssertTrue(states.contains(.signingIn))
        XCTAssertTrue(states.contains { $0.isSignedIn })
    }

    // MARK: - Token refresh

    func testValidTokenIsReturnedWithoutRefreshing() async throws {
        let store = InMemoryTokenStore(initialToken: makeToken())
        let provider = MockAuthProvider(now: { self.reference })
        let session = makeStore(provider: provider, store: store)
        await session.restore()

        let token = try await session.validToken()

        XCTAssertEqual(token.accessToken, "at")
        let refreshes = await provider.refreshCallCount
        XCTAssertEqual(refreshes, 0)
    }

    func testExpiredTokenIsRefreshedOnDemand() async throws {
        // Stored token is still technically valid but sits inside the leeway
        // window, so `restore` will not burn a refresh on it — `validToken` must.
        let store = InMemoryTokenStore(initialToken: makeToken(expiresIn: 5))
        let provider = MockAuthProvider(now: { self.reference })
        let session = makeStore(provider: provider, store: store)
        await session.restore()

        let refreshesBefore = await provider.refreshCallCount
        let token = try await session.validToken()
        let refreshesAfter = await provider.refreshCallCount

        XCTAssertEqual(refreshesBefore, 0)
        XCTAssertEqual(refreshesAfter, 1)
        XCTAssertEqual(token.accessToken, "mock-access-token-1", "should be the refreshed token")
        XCTAssertNotEqual(token.accessToken, "at", "must not return the stale stored token")
    }

    func testRefreshedTokenIsPersisted() async throws {
        let store = InMemoryTokenStore(initialToken: makeToken(expiresIn: 5))
        let session = makeStore(
            provider: MockAuthProvider(now: { self.reference }),
            store: store
        )
        await session.restore()

        let refreshed = try await session.validToken()

        let persisted = await store.loadIgnoringErrors()
        XCTAssertEqual(persisted?.accessToken, "mock-access-token-1")
        XCTAssertEqual(persisted?.accessToken, refreshed.accessToken)
    }

    func testValidTokenWithoutSessionThrows() async {
        let session = makeStore(provider: MockAuthProvider(), store: InMemoryTokenStore())
        await session.restore()

        do {
            _ = try await session.validToken()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? AuthError, .cannotRefresh)
            let state = await session.state
            XCTAssertEqual(state, .signedOut)
        }
    }

    // MARK: - Sign out

    func testSignOutClearsEverything() async throws {
        let store = InMemoryTokenStore(initialToken: makeToken())
        let provider = MockAuthProvider(now: { self.reference })
        let session = makeStore(provider: provider, store: store)
        await session.restore()

        await session.signOut()

        let state = await session.state
        XCTAssertEqual(state, .signedOut)
        let token = await session.token
        XCTAssertNil(token)
        let persisted = await store.loadIgnoringErrors()
        XCTAssertNil(persisted)
        let signOuts = await provider.signOutCount
        XCTAssertEqual(signOuts, 1)
    }

    // MARK: - Error messaging

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertEqual(SessionStore.describe(AuthError.cancelled), "Sign-in was cancelled.")
        XCTAssertEqual(
            SessionStore.describe(AuthError.cannotRefresh),
            "Your session expired. Please sign in again."
        )
        XCTAssertTrue(
            SessionStore.describe(AuthError.notConfigured).contains("-useMockAuth")
        )
    }
}

// MARK: - Token stores

final class TokenStoreTests: XCTestCase {

    func testInMemoryStoreRoundTrip() async throws {
        let store = InMemoryTokenStore()
        let initially = try await store.load()
        XCTAssertNil(initially)

        let token = AuthToken(accessToken: "a", expiresAt: Date(timeIntervalSince1970: 1000))
        try await store.save(token)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, token)

        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    func testInMemoryStoreCanBeMadeToFail() async {
        let store = InMemoryTokenStore()
        await store.setFailingWrites(true)

        do {
            try await store.save(AuthToken(accessToken: "a", expiresAt: Date()))
            XCTFail("expected a throw")
        } catch {
            guard case AuthError.tokenStoreFailure = error else {
                return XCTFail("expected tokenStoreFailure, got \(error)")
            }
        }
    }

    func testFileStoreRoundTrip() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibiblio-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileTokenStore(directory: directory)
        let initially = try await store.load()
        XCTAssertNil(initially)

        let token = AuthToken(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            scope: "openid"
        )
        try await store.save(token)
        let storagePath = await store.storageURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: storagePath))

        // A fresh instance must read from disk, proving the cache is not a
        // shortcut that hides a broken write.
        let reopened = FileTokenStore(directory: directory)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded, token)

        try await store.clear()
        let afterClear = try await FileTokenStore(directory: directory).load()
        XCTAssertNil(afterClear)
    }

    func testFileStoreTreatsCorruptDataAsEmptyAndCleansUp() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibiblio-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileTokenStore(directory: directory)
        try Data("{ this is not json".utf8).write(to: await store.storageURL)

        let loaded = try await store.load()
        XCTAssertNil(loaded, "a corrupt store must not lock the user out")
    }
}

final class HTTPClientTests: XCTestCase {

    func testAuthorizedAddsBearerHeader() {
        let request = HTTPRequest(url: URL(string: "https://x.test")!)
            .authorized(with: AuthToken(accessToken: "t", expiresAt: Date()))
        XCTAssertEqual(request.headers["Authorization"], "Bearer t")
    }

    func testAuthorizedWithNilTokenLeavesRequestUntouched() {
        let original = HTTPRequest(url: URL(string: "https://x.test")!)
        let request = original.authorized(with: nil)
        XCTAssertNil(request.headers["Authorization"])
    }

    func testStubClientRecordsRequestsAndReturnsReplies() async throws {
        let http = StubHTTPClient()
        let url = URL(string: "https://api.test/v1/books")!
        await http.stub(url, with: .text("hello", statusCode: 201))

        let response = try await http.send(HTTPRequest(method: .post, url: url))
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.bodyAsString, "hello")
        XCTAssertTrue(response.isSuccess)

        let recorded = await http.recordedRequests
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.method, .post)
    }

    func testStubClientThrows404ForUnstubbedURLs() async {
        let http = StubHTTPClient()
        do {
            _ = try await http.send(HTTPRequest(url: URL(string: "https://api.test/missing")!))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HTTPError, .status(code: 404, body: "StubHTTPClient has no reply registered for https://api.test/missing"))
        }
    }

    func testSendExpectingSuccessThrowsOnNon2xx() async {
        let http = StubHTTPClient()
        let url = URL(string: "https://api.test/fail")!
        await http.stub(url, with: .text("nope", statusCode: 500))

        do {
            _ = try await http.sendExpectingSuccess(HTTPRequest(url: url))
            XCTFail("expected a throw")
        } catch {
            guard case HTTPError.status(let code, _) = error else {
                return XCTFail("expected status, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    func testResponseDecodingFailureIsMapped() {
        let response = HTTPResponse(statusCode: 200, body: Data("nope".utf8))
        do {
            _ = try response.decoded(BookItem.self)
            XCTFail("expected a throw")
        } catch {
            guard case HTTPError.decodingFailed = error else {
                return XCTFail("expected decodingFailed, got \(error)")
            }
        }
    }

    func testNonUTF8BodyDoesNotCrashDescription() {
        let response = HTTPResponse(statusCode: 200, body: Data([0xFF, 0xFE, 0x00]))
        XCTAssertFalse(response.bodyAsString.isEmpty)
    }
}

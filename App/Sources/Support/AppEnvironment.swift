import Foundation
import iBiblioCore
import SwiftUI

/// Owns the long-lived objects and hands them to SwiftUI.
///
/// Built once in `iBiblioDemoApp`, which keeps `SessionStore`, `UploadService`
/// and the Readium stack alive across navigation and avoids rebuilding them on
/// every view update.
@MainActor
final class AppEnvironment: ObservableObject {

    let configuration: AppConfiguration
    let session: SessionStore
    let uploads: UploadService
    let library: LibraryService
    let httpClient: URLSessionHTTPClient

    /// Readium is only constructed on Apple platforms, and only when a
    /// publication is actually opened. See `ReaderCoordinator`.
    let reader: ReaderCoordinator

    @Published private(set) var sessionState: SessionState = .restoring
    @Published private(set) var uploadState: UploadState?

    init(configuration: AppConfiguration = .resolve()) {
        self.configuration = configuration
        self.httpClient = URLSessionHTTPClient()

        let tokenStore = KeychainTokenStore(
            service: "com.example.ibiblio.demo",
            account: "oauth-token"
        )

        let authProvider: any AuthProvider
        switch configuration.auth {
        case .mock:
            authProvider = MockAuthProvider()
        case .mockFailing:
            authProvider = MockAuthProvider(shouldFail: true)
        case .oidc:
            // Force-unwrapped above: `.oidc` is only selected when an issuer parsed.
            let oidc = configuration.oidc!
            authProvider = OIDCAuthProvider(
                configuration: oidc,
                httpClient: httpClient,
                presenter: WebAuthSessionPresenter()
            )
        }

        self.session = SessionStore(
            provider: authProvider,
            tokenStore: tokenStore,
            onChange: { [weak self] state in
                // The callback is async and `SessionStore` is an actor, so the
                // hop to the main actor is explicit and ordered -- no `Task` needed.
                await MainActor.run { self?.sessionState = state }
            }
        )

        self.uploads = UploadService(
            configuration: UploadService.Configuration(
                uploadEndpoint: configuration.backend.appendingPathComponent("upload")
            ),
            httpClient: httpClient
        )

        self.library = LibraryService(
            catalogEndpoint: configuration.catalogEndpoint,
            fixturesDirectory: FixtureLocator.directory(),
            includesLocalFixtures: configuration.useLocalFixtures
        )

        self.reader = ReaderCoordinator()
    }

    /// Restores a persisted session. Call once, from the root view's `.task`.
    func start() async {
        await session.restore()
        sessionState = await session.state
    }

    func signIn() async {
        do {
            try await session.signIn()
        } catch {
            // `SessionStore` has already published `.failed(message)`; nothing to
            // add here, but the error must not escape as an unhandled rejection.
        }
        sessionState = await session.state
    }

    func signOut() async {
        await session.signOut()
        sessionState = await session.state
    }

    /// The access token to attach to backend calls, refreshing when stale.
    func validToken() async -> AuthToken? {
        try? await session.validToken()
    }

    // MARK: - Upload

    func upload(fileURL: URL, title: String?, author: String?) async -> BookItem? {
        uploadState = .validating
        do {
            let token = await validToken()
            let item = try await uploads.upload(
                fileURL: fileURL,
                title: title,
                author: author,
                token: token,
                onState: { [weak self] state in
                    await MainActor.run { self?.uploadState = state }
                }
            )
            // Reuse the token: the catalog can be authenticated too, and a
            // reload without it would drop the new book straight back off the list.
            await library.reload(token: token)
            return item
        } catch {
            uploadState = .failed(Self.describe(error))
            return nil
        }
    }

    func clearUploadState() {
        uploadState = nil
    }

    private static func describe(_ error: Error) -> String {
        SessionStore.describe(error)
    }
}

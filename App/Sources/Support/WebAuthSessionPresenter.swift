import AuthenticationServices
import Foundation
import UIKit
import iBiblioCore

/// `WebAuthSessionPresenting` backed by `ASWebAuthenticationSession`.
///
/// This is the only piece of the sign-in flow that cannot be built on Windows:
/// it needs UIKit to put a sheet on screen. Everything above it — the
/// authorization URL, the state/nonce check, the PKCE exchange and the token
/// parsing — lives in `iBiblioCore` and is unit-tested there.
@MainActor
final class WebAuthSessionPresenter: NSObject, WebAuthSessionPresenting {

    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    /// `ASWebAuthenticationSession` is retained for the duration of the flow, and
    /// it is not thread-safe, so the whole class is main-actor bound.
    func presentAuthorizationURL(
        _ url: URL,
        callbackURLScheme: String
    ) async throws -> URL {

        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callbackURL, error in
                // The completion handler is not main-actor isolated.
                Task { @MainActor in
                    self?.finish(with: callbackURL, error: error, continuation: continuation)
                }
            }

            session.presentationContextProvider = self
            // Do not let a stray Safari password prompt swallow the flow.
            session.prefersEphemeralWebBrowserSession = false

            self.session = session
            self.continuation = continuation

            if !session.start() {
                finish(
                    with: nil,
                    error: AuthError.authorizationFailed(
                        reason: "ASWebAuthenticationSession refused to start"
                    ),
                    continuation: continuation
                )
            }
        }
    }

    /// Idempotent on purpose.
    ///
    /// There are two ways in: the session's completion handler, and the
    /// `start() == false` fallback above. Resuming a `CheckedContinuation` twice
    /// is a runtime trap, so the second caller is dropped rather than allowed to
    /// crash the app.
    private func finish(
        with callbackURL: URL?,
        error: Error?,
        continuation: CheckedContinuation<URL, Error>
    ) {
        guard self.continuation === continuation else { return }
        self.continuation = nil
        self.session = nil

        if let callbackURL {
            continuation.resume(returning: callbackURL)
            return
        }

        if let authenticationError = error as? ASWebAuthenticationSessionError,
           authenticationError.code == .canceledLogin {
            continuation.resume(throwing: AuthError.cancelled)
            return
        }

        continuation.resume(
            throwing: AuthError.authorizationFailed(
                reason: error?.localizedDescription ?? "No callback URL was returned"
            )
        )
    }
}

// MARK: - Presentation context

extension WebAuthSessionPresenter: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Anchor the sheet to whichever window is frontmost; the app has a single
        // scene, so the first connected scene is always the right answer.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
    }
}

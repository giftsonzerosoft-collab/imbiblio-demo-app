import Foundation

/// The observable authentication state that drives the UI.
public enum SessionState: Sendable, Equatable {
    /// Nothing loaded yet.
    case restoring
    case signedOut
    case signingIn
    case signedIn(user: SessionUser)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .restoring, .signingIn: return true
        default: return false
        }
    }
}

/// Minimal user profile decoded from the OIDC `id_token` when a `userinfo`
/// endpoint is not available.
public struct SessionUser: Sendable, Equatable, Codable {
    public var subject: String
    public var displayName: String
    public var email: String?

    public init(subject: String, displayName: String? = nil, email: String? = nil) {
        self.subject = subject
        self.displayName = displayName ?? subject
        self.email = email
    }
}

/// Owns the auth lifecycle: restore → sign in → auto-refresh → sign out.
///
/// An actor, so the refresh-on-expiry path is race-free: two concurrent
/// requests cannot both trigger a refresh.
public actor SessionStore {

    private let provider: AuthProvider
    private let tokenStore: TokenStore
    private let now: @Sendable () -> Date

    public private(set) var state: SessionState = .restoring
    public private(set) var token: AuthToken?

    /// Called on every state transition. Hop to the main actor before touching UI.
    private let onChange: @Sendable (SessionState) async -> Void

    public init(
        provider: AuthProvider,
        tokenStore: TokenStore,
        onChange: @escaping @Sendable (SessionState) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.tokenStore = tokenStore
        self.onChange = onChange
        self.now = now
    }

    // MARK: - Lifecycle

    /// Loads a persisted token, if any. Safe to call on launch.
    public func restore() async {
        let stored = await tokenStore.loadIgnoringErrors()
        guard let stored else {
            await transition(to: .signedOut)
            return
        }
        guard stored.canBeRefreshed || stored.isUsable(at: now()) else {
            // Expired and unrecoverable: drop it so the next launch starts clean.
            try? await tokenStore.clear()
            await transition(to: .signedOut)
            return
        }
        token = stored
        await transition(to: .signedIn(user: stored.userProfile()))

        // Refresh proactively only when the token is already hard-expired. One
        // that merely sits inside the leeway window is refreshed on first use by
        // `validToken()` instead, which keeps cold launch free of a round-trip.
        if stored.isExpired(at: now(), leeway: 0) {
            // A failure here is not fatal: the token is only hard-expired, and
            // `validToken()` will try again on first use. `refreshIfNeeded` has
            // already published `.failed` if it gave up entirely.
            _ = try? await refreshIfNeeded()
        }
    }

    /// Runs the interactive login flow and persists the result.
    public func signIn() async throws {
        await transition(to: .signingIn)
        do {
            let newToken = try await provider.authorize()
            try await tokenStore.save(newToken)
            token = newToken
            await transition(to: .signedIn(user: newToken.userProfile()))
        } catch {
            let message = Self.describe(error)
            await transition(to: .failed(message))
            throw error
        }
    }

    /// Clears credentials and returns to the signed-out state.
    public func signOut() async {
        let current = token
        await provider.signOut(current)
        try? await tokenStore.clear()
        token = nil
        await transition(to: .signedOut)
    }

    /// Returns a usable token, refreshing first if needed.
    ///
    /// This is what every authenticated request should call.
    public func validToken() async throws -> AuthToken {
        guard let current = token else {
            await transition(to: .signedOut)
            throw AuthError.cannotRefresh
        }
        if current.isUsable(at: now()) {
            return current
        }
        return try await refreshIfNeeded()
    }

    // MARK: - Private

    @discardableResult
    private func refreshIfNeeded() async throws -> AuthToken {
        guard let current = token else {
            await transition(to: .signedOut)
            throw AuthError.cannotRefresh
        }
        guard current.canBeRefreshed else {
            // Expired and unrecoverable: force a fresh interactive login.
            try? await tokenStore.clear()
            token = nil
            await transition(to: .signedOut)
            throw AuthError.cannotRefresh
        }

        do {
            let refreshed = try await provider.refresh(current)
            try await tokenStore.save(refreshed)
            token = refreshed
            await transition(to: .signedIn(user: refreshed.userProfile()))
            return refreshed
        } catch {
            // Refresh failures are terminal for the session.
            try? await tokenStore.clear()
            token = nil
            await transition(to: .failed(Self.describe(error)))
            throw error
        }
    }

    private func transition(to newState: SessionState) async {
        state = newState
        // Awaited rather than fire-and-forget: callers that observe the state
        // sequence (the app's SwiftUI binding, and the tests) must not be able to
        // observe a later state before an earlier one has been delivered.
        await onChange(newState)
    }

    /// Turns any error thrown by the core into a sentence worth showing a user.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let authError as AuthError:
            switch authError {
            case .cancelled: return "Sign-in was cancelled."
            case .notConfigured: return "No sign-in server is configured. Run with -useMockAuth for the demo."
            case .missingAuthorizationCode: return "The sign-in server did not return an authorization code."
            case .cannotRefresh: return "Your session expired. Please sign in again."
            case .tokenStoreFailure: return "Could not save your session securely."
            case .invalidTokenResponse, .authorizationFailed, .tokenEndpointFailure:
                return "Sign-in failed: \(authError)"
            }
        case let uploadError as UploadError:
            return String(describing: uploadError)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - id_token introspection

extension AuthToken {

    /// Pulls the `sub` claim out of a JWT payload **without verifying the
    /// signature** — acceptable for displaying a name, never for authorization
    /// decisions. A production app must validate the ID token against the
    /// issuer's JWKS.
    func subjectFromIDToken() -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payload = Base64URL.decode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any]
        else { return nil }
        return object["sub"] as? String
    }

    /// Pulls a claim such as `name` or `email`, if present in the ID token.
    func claim(_ name: String) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let payload = Base64URL.decode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any]
        else { return nil }
        return object[name] as? String
    }

    /// Best-effort user profile for display.
    func userProfile() -> SessionUser {
        SessionUser(
            subject: subjectFromIDToken() ?? "reader",
            displayName: claim("name") ?? claim("preferred_username"),
            email: claim("email")
        )
    }
}

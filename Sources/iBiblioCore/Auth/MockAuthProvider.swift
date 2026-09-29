import Foundation

/// A fake authorization server, so the app is fully explorable with no backend.
///
/// Issues a signed-looking (but genuinely just deterministic) token, and
/// optionally fails a configurable number of times first, which is what the
/// screenshot UI tests use to exercise the error state.
public actor MockAuthProvider: AuthProvider {

    private let lifetime: TimeInterval
    private let shouldFail: Bool
    private let now: @Sendable () -> Date

    private var issueCounter = 0
    public private(set) var signOutCount = 0
    public private(set) var authorizeCallCount = 0
    public private(set) var refreshCallCount = 0

    public init(
        lifetime: TimeInterval = 60 * 60,
        shouldFail: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lifetime = lifetime
        self.shouldFail = shouldFail
        self.now = now
    }

    public func authorize() async throws -> AuthToken {
        authorizeCallCount += 1
        if shouldFail {
            throw AuthError.authorizationFailed(reason: "MockAuthProvider configured to fail")
        }
        issueCounter += 1
        return makeToken(index: issueCounter)
    }

    public func refresh(_ token: AuthToken) async throws -> AuthToken {
        refreshCallCount += 1
        issueCounter += 1
        return makeToken(index: issueCounter)
    }

    public func signOut(_ token: AuthToken?) async {
        signOutCount += 1
    }

    private func makeToken(index: Int) -> AuthToken {
        let issuedAt = now()
        return AuthToken(
            accessToken: "mock-access-token-\(index)",
            refreshToken: "mock-refresh-token-\(index)",
            tokenType: "Bearer",
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            scope: "openid profile offline_access",
            idToken: "mock-id-token-\(index)"
        )
    }
}

import XCTest

@testable import iBiblio

/// Tests for the app's own logic -- the parts of the iOS target that are plain
/// Swift and therefore do not need a simulator interaction to be trusted.
///
/// `AppConfiguration` gets the most attention here because it parses launch
/// arguments, and a `-key value` pair is easy to mistake for a bare switch. That
/// exact mistake shipped once: `-authMode mockFailing` was silently downgraded to
/// plain `.mock`, so the sign-in error UI was never exercised.
final class AppConfigurationTests: XCTestCase {

    // MARK: - Auth mode

    func testDefaultModeIsMock() {
        // No issuer, no arguments: the demo must work out of the box.
        let configuration = AppConfiguration.resolve(arguments: [], environment: [:])
        XCTAssertEqual(configuration.auth, .mock)
        XCTAssertNil(configuration.oidc)
        XCTAssertNil(configuration.misconfiguration)
    }

    func testAuthModeIsReadFromAValuedArgument() {
        // Regression test: `-authMode mockFailing` is a *pair*, and reading it as
        // a bare switch returned nil, which fell through to `.mock`.
        let configuration = AppConfiguration.resolve(
            arguments: ["iBiblio", "-authMode", "mockFailing"],
            environment: [:]
        )
        XCTAssertEqual(configuration.auth, .mockFailing)
    }

    func testEveryAuthModeRoundTripsThroughALaunchArgument() throws {
        for mode in [AppConfiguration.AuthMode.mock, .mockFailing, .oidc] {
            let arguments = ["-authMode", mode.rawValue]
            let resolved = AppConfiguration.resolve(
                arguments: mode == .oidc
                    ? arguments + ["-oidcIssuer", "https://issuer.example.com"]
                    : arguments,
                environment: [:]
            )
            XCTAssertEqual(resolved.auth, mode)
        }
    }

    func testUnknownAuthModeFallsBackRatherThanCrashing() {
        let configuration = AppConfiguration.resolve(
            arguments: ["-authMode", "nonsense"],
            environment: [:]
        )
        XCTAssertEqual(configuration.auth, .mock)
    }

    func testLegacyUseMockAuthSwitchStillWorks() {
        let configuration = AppConfiguration.resolve(
            arguments: ["-useMockAuth"],
            environment: [:]
        )
        XCTAssertEqual(configuration.auth, .mock)
    }

    // MARK: - OIDC

    func testIssuerArgumentSelectsOIDCMode() throws {
        let configuration = AppConfiguration.resolve(
            arguments: [
                "-oidcIssuer", "https://issuer.example.com",
                "-oidcClientID", "demo-client",
                "-oidcRedirectURI", "ibiblio://oauth/callback",
            ],
            environment: [:]
        )

        XCTAssertEqual(configuration.auth, .oidc)
        XCTAssertNil(configuration.misconfiguration)
        let oidc = try XCTUnwrap(configuration.oidc)
        XCTAssertEqual(oidc.issuer.absoluteString, "https://issuer.example.com")
        XCTAssertEqual(oidc.clientID, "demo-client")
        XCTAssertEqual(oidc.redirectURI, "ibiblio://oauth/callback")
    }

    func testEnvironmentVariablesAreUsedWhenNoArgumentIsGiven() throws {
        let configuration = AppConfiguration.resolve(
            arguments: [],
            environment: [
                "OIDC_ISSUER": "https://from-env.example.com",
                "OIDC_CLIENT_ID": "env-client",
            ]
        )

        XCTAssertEqual(configuration.auth, .oidc)
        let oidc = try XCTUnwrap(configuration.oidc)
        XCTAssertEqual(oidc.issuer.absoluteString, "https://from-env.example.com")
        XCTAssertEqual(oidc.clientID, "env-client")
    }

    func testLaunchArgumentBeatsEnvironmentVariable() throws {
        let configuration = AppConfiguration.resolve(
            arguments: ["-oidcIssuer", "https://from-arg.example.com"],
            environment: ["OIDC_ISSUER": "https://from-env.example.com"]
        )
        let oidc = try XCTUnwrap(configuration.oidc)
        XCTAssertEqual(oidc.issuer.absoluteString, "https://from-arg.example.com")
    }

    func testRequestingOIDCWithAnUnusableIssuerIsReportedNotHidden() {
        // Silently falling back to a mock sign-in would look like it worked.
        let configuration = AppConfiguration.resolve(
            arguments: ["-authMode", "oidc", "-oidcIssuer", ""],
            environment: [:]
        )

        XCTAssertEqual(configuration.auth, .mock, "still runs, via the mock provider")
        let problem = configuration.misconfiguration
        XCTAssertNotNil(problem, "but the operator is told why")
        XCTAssertTrue(problem?.contains("-oidcIssuer") == true)
    }

    // MARK: - Backend

    func testCatalogDefaultsToTheBackendAppendPath() {
        let configuration = AppConfiguration.resolve(
            arguments: ["-backendBaseURL", "https://api.example.com/v1"],
            environment: [:]
        )
        XCTAssertEqual(
            configuration.catalogEndpoint.absoluteString,
            "https://api.example.com/v1/catalog"
        )
    }

    func testExplicitCatalogURLWins() {
        let configuration = AppConfiguration.resolve(
            arguments: [
                "-backendBaseURL", "https://api.example.com/v1",
                "-catalogURL", "https://api.example.com/books",
            ],
            environment: [:]
        )
        XCTAssertEqual(configuration.catalogEndpoint.absoluteString, "https://api.example.com/books")
    }

    func testRelativeURLIsRejectedInFavourOfTheFallback() {
        let configuration = AppConfiguration.resolve(
            arguments: ["-backendBaseURL", "not a url"],
            environment: [:]
        )
        XCTAssertEqual(configuration.backend.absoluteString, "https://example.invalid")
    }

    // MARK: - Fixtures

    func testLocalFixturesAreOnByDefaultAndCanBeTurnedOff() {
        XCTAssertTrue(
            AppConfiguration.resolve(arguments: [], environment: [:]).useLocalFixtures
        )
        XCTAssertFalse(
            AppConfiguration.resolve(
                arguments: ["-useLocalFixtures", "NO"],
                environment: [:]
            ).useLocalFixtures
        )
        XCTAssertTrue(
            AppConfiguration.resolve(
                arguments: ["-useLocalFixtures"],
                environment: [:]
            ).useLocalFixtures,
            "a bare switch means true"
        )
    }
}

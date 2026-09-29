import Foundation
import iBiblioCore

/// Everything the app needs to talk to a backend, resolved once at launch.
///
/// Values come from (in order of precedence) launch arguments, environment
/// variables and Info.plist-backed defaults. The UI tests use launch arguments to
/// pin the configuration, which is why nothing here reads shared state.
struct AppConfiguration: Sendable {

    var auth: AuthMode
    var oidc: OIDCConfiguration?
    /// Non-nil when the requested auth mode could not be honoured.
    var misconfiguration: String?
    var backend: URL
    var catalogEndpoint: URL
    var useLocalFixtures: Bool

    enum AuthMode: String, Sendable {
        /// Real OIDC Authorization Code + PKCE in an `ASWebAuthenticationSession`.
        case oidc
        /// `MockAuthProvider`: sign-in always succeeds, no network required.
        case mock
        /// Same as `.mock`, but `authorize()` throws — exercises the error UI.
        case mockFailing
    }

    // Launch-argument keys, mirrored in App/UITests/UITestSupport.swift.
    enum Key {
        static let authMode = "-authMode"
        static let issuer = "-oidcIssuer"
        static let clientID = "-oidcClientID"
        static let redirectURI = "-oidcRedirectURI"
        static let backend = "-backendBaseURL"
        static let catalog = "-catalogURL"
        static let useLocalFixtures = "-useLocalFixtures"
    }

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppConfiguration {

        let values = LaunchArguments(arguments: arguments, environment: environment)

        // `-authMode mockFailing` is a `-key value` pair, so it has to be read as
        // a value, not as a bare switch.
        let auth = values.argument(Key.authMode).flatMap(AuthMode.init(rawValue:))
            ?? (values.isPresent("-useMockAuth") ? AuthMode.mock : nil)
            ?? (values.string(Key.issuer) == nil ? AuthMode.mock : .oidc)

        let issuer = values.string(Key.issuer)
            ?? values.string("OIDC_ISSUER")
        let clientID = values.string(Key.clientID) ?? values.string("OIDC_CLIENT_ID") ?? "ibiblio-demo"
        let redirectURI = values.string(Key.redirectURI)
            ?? values.string("OIDC_REDIRECT_URI")
            ?? "ibiblio://oauth/callback"

        let issuerURL = issuer.flatMap(URL.init(string:))
        let configuration: OIDCConfiguration?
        if let issuerURL {
            configuration = OIDCConfiguration(
                issuer: issuerURL,
                clientID: clientID,
                redirectURI: redirectURI
            )
        } else {
            configuration = nil
        }

        let backend = Self.url(from: values.string(Key.backend) ?? values.string("BACKEND_BASE_URL"),
                               fallback: "https://example.invalid")
        let catalog = Self.url(from: values.string(Key.catalog) ?? values.string("CATALOG_URL"),
                               fallback: backend.appendingPathComponent("catalog"))

        // Asking for OIDC without a usable issuer is a deployment mistake, not a
        // reason to quietly sign the user in as a mock. Fall back so the app
        // still runs, but say so instead of pretending the config was honoured.
        let misconfiguration: String? = {
            guard auth == .oidc, configuration == nil else { return nil }
            let supplied = issuer.map { "“\($0)”" } ?? "nothing"
            return "Sign-in is configured for OIDC but \(supplied) is not a valid issuer URL, "
                + "so demo sign-in is being used instead. Pass -oidcIssuer with your provider's issuer."
        }()

        return AppConfiguration(
            auth: configuration == nil && auth == .oidc ? .mock : auth,
            oidc: configuration,
            misconfiguration: misconfiguration,
            backend: backend,
            catalogEndpoint: catalog,
            useLocalFixtures: values.bool(Key.useLocalFixtures) ?? true
        )
    }

    private static func url(from string: String?, fallback: URL) -> URL {
        guard let string, let url = URL(string: string), url.scheme != nil else {
            return fallback
        }
        return url
    }
}

/// Tiny `-flag value` / `-flag` parser.
///
/// Written by hand rather than pulling in swift-argument-parser: the app is not
/// a command-line tool, and the whole surface is two dozen strings.
private struct LaunchArguments {

    private let values: [String: String]
    private let flags: Set<String>

    init(arguments: [String], environment: [String: String]) {
        var values: [String: String] = [:]
        var flags: Set<String> = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-") else {
                index += 1
                continue
            }
            // A value is anything that does not itself look like a flag.
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(argument)
                values[argument] = ""
                index += 1
            }
        }

        self.values = values.merging(environment) { launch, _ in launch }
        self.flags = flags
    }

    func string(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    /// Whether the key appeared on the command line at all, with or without a
    /// value. Needed because `-authMode mock` and `-useMockAuth` have to be
    /// distinguished: the first carries a value, the second is a bare switch.
    func isPresent(_ key: String) -> Bool {
        flags.contains(key) || values[key] != nil
    }

    /// The value of a `-key value` pair, falling back to `""` for a bare `-key`.
    func argument(_ key: String) -> String? {
        guard isPresent(key) else { return nil }
        return values[key] ?? ""
    }

    func bool(_ key: String) -> Bool? {
        guard isPresent(key) else { return nil }
        guard let value = values[key], !value.isEmpty else { return true }
        return ["1", "true", "YES", "yes"].contains(value)
    }
}

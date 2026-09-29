import iBiblioCore
import SwiftUI

/// Sign-in screen. Shows a different affordance depending on whether the app was
/// configured with a real issuer or the mock provider.
struct SignInView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var mode: AppConfiguration.AuthMode { environment.configuration.auth }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("iBiblio")
                    .font(.largeTitle.bold())
                Text("Your library, signed in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let problem = environment.configuration.misconfiguration {
                Label(problem, systemImage: "gearshape.arrow.trianglehead.counterclockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("signin.misconfiguration")
            }

            if case .failed(let message) = environment.sessionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("signin.error")
            }

            VStack(spacing: 12) {
                if mode == .oidc {
                    Button {
                        Task { await environment.signIn() }
                    } label: {
                        Label("Sign in", systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("signin.button")

                    Text("Opens your identity provider in a secure browser sheet and returns via \(redirectDescription).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Button {
                        Task { await environment.signIn() }
                    } label: {
                        Label("Sign in", systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("signin.button")

                    Label("Demo mode — no network required", systemImage: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("signin.demoBadge")
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Text("Session is stored in the iOS Keychain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    private var redirectDescription: String {
        guard let uri = environment.configuration.oidc?.redirectURI else { return "the app" }
        return uri.hasPrefix("ibiblio://") ? "the app" : uri
    }
}

#Preview {
    SignInView()
        .environmentObject(AppEnvironment())
}

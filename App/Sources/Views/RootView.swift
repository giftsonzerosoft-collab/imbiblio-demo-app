import iBiblioCore
import SwiftUI

/// The single place the session decides what the user can see.
struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Group {
            switch environment.sessionState {
            case .restoring:
                RestoringView()
            case .signedOut, .failed:
                SignInView()
            case .signingIn:
                ProgressView("Signing in…")
            case .signedIn(let user):
                LibraryView(user: user)
            }
        }
        .animation(.default, value: environment.sessionState)
    }
}

private struct RestoringView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Restoring your session…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("session.restoring")
    }
}

#Preview {
    RootView()
        .environmentObject(AppEnvironment())
}

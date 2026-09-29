import SwiftUI

/// The app entry point.
///
/// Separate from `AppEnvironment` so the environment stays a plain object that
/// could be built in a test or a preview, and so `@main` is the one thing a
/// reader has to find when they open the target.
@main
struct iBiblioDemoApp: App {

    /// Built once for the lifetime of the process: `SessionStore`, `UploadService`
    /// and the Readium stack all need to outlive individual view updates.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .task { await environment.start() }
        }
    }
}

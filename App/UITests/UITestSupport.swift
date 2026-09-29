import XCTest

/// Shared plumbing for the UI tests.
///
/// Every test launches the app with `-authMode mock` so it never touches the
/// network or the Keychain, which is what makes the screenshots deterministic.
enum UITestSupport {

    static func launch(
        _ app: XCUIApplication,
        authMode: String = "mock",
        extra: [String] = []
    ) {
        app.launchArguments = ["-authMode", authMode] + extra
        app.launchEnvironment["UITEST"] = "1"
        app.launch()
    }

    /// Waits for an element and fails with a useful message rather than a timeout.
    @discardableResult
    static func wait(
        _ element: XCUIElement,
        _ timeout: TimeInterval = 20,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        if !found && !message.isEmpty {
            XCTFail("Timed out waiting for \(message)", file: file, line: line)
        }
        return found
    }
}

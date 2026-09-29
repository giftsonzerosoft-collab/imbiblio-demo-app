import XCTest

/// End-to-end checks of the flows that are hard to unit-test: the session gate,
/// the library, the upload sheet, and each Readium renderer.
final class iBiblioDemoUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Session

    func testSignInGateShowsDemoBadge() {
        UITestSupport.launch(app)

        UITestSupport.wait(app.buttons["signin.button"], 20, "sign-in button")
        XCTAssertTrue(app.staticTexts["signin.demoBadge"].exists)
    }

    func testMockSignInReachesTheLibrary() {
        UITestSupport.launch(app)

        let signIn = app.buttons["signin.button"]
        XCTAssertTrue(UITestSupport.wait(signIn, 20, "sign-in button"))
        signIn.tap()

        UITestSupport.wait(app.navigationBars["Library"], 20, "library")
        XCTAssertTrue(app.navigationBars["Library"].exists)
    }

    func testFailingSignInShowsTheError() {
        // `mockFailing` makes `MockAuthProvider.authorize()` throw, which is how
        // the `.failed` branch of the session gate gets covered.
        UITestSupport.launch(app, authMode: "mockFailing")

        let signIn = app.buttons["signin.button"]
        XCTAssertTrue(UITestSupport.wait(signIn, 20, "sign-in button"))
        signIn.tap()

        UITestSupport.wait(app.staticTexts["signin.error"], 20, "sign-in error")
    }

    func testSignOutReturnsToTheGate() {
        UITestSupport.launch(app)

        let signIn = app.buttons["signin.button"]
        XCTAssertTrue(UITestSupport.wait(signIn, 20, "sign-in button"))
        signIn.tap()

        UITestSupport.wait(app.buttons["library.upload"], 20, "library toolbar")

        app.buttons["library.upload"].tap()
        UITestSupport.wait(app.buttons["upload.cancel"], 10, "upload sheet")
        app.buttons["upload.cancel"].tap()

        app.navigationBars["Library"].buttons.firstMatch.tap()
        app.buttons["library.signOut"].tap()

        UITestSupport.wait(app.buttons["signin.button"], 20, "sign-in button again")
    }

    // MARK: - Library and upload

    func testBundledFixturesAreListed() {
        UITestSupport.launch(app)

        let signIn = app.buttons["signin.button"]
        XCTAssertTrue(UITestSupport.wait(signIn, 20, "sign-in button"))
        signIn.tap()

        // Scripts/generate_fixtures.py writes manifest.json with these ids.
        UITestSupport.wait(app.cells["library.row.fixture-epub"], 20, "EPUB fixture row")
        XCTAssertTrue(app.cells["library.row.fixture-pdf"].exists)
        XCTAssertTrue(app.cells["library.row.fixture-audiobook"].exists)
    }

    func testUploadSheetRejectsUnsupportedFileTypes() {
        UITestSupport.launch(app)

        let signIn = app.buttons["signin.button"]
        XCTAssertTrue(UITestSupport.wait(signIn, 20, "sign-in button"))
        signIn.tap()

        UITestSupport.wait(app.buttons["library.upload"], 20, "library toolbar")
        app.buttons["library.upload"].tap()

        UITestSupport.wait(app.buttons["upload.chooseFile"], 10, "file picker button")
        XCTAssertTrue(app.buttons["upload.confirm"].exists)
        // Nothing chosen yet, so the confirm button must stay disabled.
        XCTAssertFalse(app.buttons["upload.confirm"].isEnabled)
    }

    // MARK: - Readers

    func testOpeningTheEPUBFixtureShowsTheReader() {
        try? signIn()

        let row = app.cells["library.row.fixture-epub"]
        XCTAssertTrue(UITestSupport.wait(row, 20, "EPUB fixture row"))
        row.tap()

        // The EPUB navigator is a WKWebView; the demo's first chapter is
        // "The Offline Library".
        let webView = app.webViews.firstMatch
        XCTAssertTrue(UITestSupport.wait(webView, 40, "EPUB web view"))
        XCTAssertTrue(
            UITestSupport.wait(
                app.staticTexts["The Offline Library"],
                40,
                "first chapter heading"
            )
        )
    }

    func testOpeningThePDFFixtureShowsThePDFReader() {
        try? signIn()

        let row = app.cells["library.row.fixture-pdf"]
        XCTAssertTrue(UITestSupport.wait(row, 20, "PDF fixture row"))
        row.tap()

        UITestSupport.wait(app.otherElements["reader.pdfView"], 40, "PDF view")
    }

    func testOpeningTheAudiobookFixtureShowsThePlayer() {
        try? signIn()

        let row = app.cells["library.row.fixture-audiobook"]
        XCTAssertTrue(UITestSupport.wait(row, 20, "audiobook fixture row"))
        row.tap()

        XCTAssertTrue(UITestSupport.wait(app.buttons["audiobook.playPause"], 40, "play button"))
        XCTAssertTrue(app.buttons["audiobook.skipForward"].exists)
        XCTAssertTrue(app.buttons["audiobook.skipBack"].exists)
    }

    // MARK: - Helpers

    @discardableResult
    private func signIn() -> Bool {
        UITestSupport.launch(app)
        let button = app.buttons["signin.button"]
        guard UITestSupport.wait(button, 20, "sign-in button") else { return false }
        button.tap()
        return UITestSupport.wait(app.navigationBars["Library"], 20, "library")
    }
}

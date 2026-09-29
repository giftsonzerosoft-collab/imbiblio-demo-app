import iBiblioCore
import XCTest

@testable import iBiblio

/// Tests for library identity and fixture manifest decoding.
///
/// The id rules matter more than they look: `ReaderCoordinator` reports the entry
/// id back, and the reader view compares the two to decide whether the
/// publication on screen is the one the user tapped. A prefix that disagreed
/// between the manifest and `LibraryEntry.id` meant the reader never appeared.
final class LibraryEntryTests: XCTestCase {

    private func fixture(
        id: String = "epub",
        fileName: String = "sample.epub",
        format: BookFormat = .epub
    ) -> FixturePublication {
        FixturePublication(
            id: id,
            title: "Sample",
            author: "Author",
            format: format,
            fileName: fileName
        )
    }

    // MARK: - Identity

    func testFixtureEntryIdIsPrefixed() {
        XCTAssertEqual(LibraryEntry.fixture(fixture()).id, "fixture-epub")
    }

    func testRemoteEntryIdIsPrefixed() {
        let item = BookItem(id: "42", title: "Remote", format: .pdf)
        XCTAssertEqual(LibraryEntry.remote(item).id, "remote-42")
    }

    func testFixtureAndRemoteEntriesCannotCollide() {
        // A remote catalog is free to use "epub" as an id; the prefix is what
        // keeps the two sources from shadowing each other in the ForEach.
        let remote = LibraryEntry.remote(BookItem(id: "epub", title: "Remote", format: .epub))
        let bundled = LibraryEntry.fixture(fixture())
        XCTAssertNotEqual(remote.id, bundled.id)
    }

    func testEntriesAreHashableSoSwiftUIDiffingIsStable() {
        let entry = LibraryEntry.fixture(fixture())
        XCTAssertEqual(Set([entry, entry]).count, 1)
    }

    // MARK: - Manifest

    func testManifestDecodesTheGeneratorOutput() throws {
        // Mirrors what Scripts/generate_fixtures.py writes. The ids are
        // deliberately unprefixed here -- `LibraryEntry.id` adds the prefix.
        let json = """
        {
          "publications": [
            {
              "id": "epub",
              "title": "iBiblio Sample Publication",
              "author": "iBiblio Demo",
              "format": "epub",
              "fileName": "sample.epub"
            },
            {
              "id": "audiobook",
              "title": "iBiblio Test Tone",
              "author": null,
              "format": "audiobook",
              "fileName": "sample.wav"
            }
          ]
        }
        """

        let directory = try Self.makeDirectory()
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))

        let publications = FixturePublication.load(from: directory)

        XCTAssertEqual(publications.count, 2)
        XCTAssertEqual(publications[0].id, "epub")
        XCTAssertEqual(publications[0].format, .epub)
        XCTAssertEqual(publications[0].fileName, "sample.epub")
        XCTAssertEqual(publications[1].id, "audiobook")
        XCTAssertNil(publications[1].author, "author is optional")
    }

    func testUnknownFormatIsSkippedRatherThanFailingTheWholeManifest() throws {
        let json = """
        {
          "publications": [
            { "id": "ok", "title": "Fine", "format": "epub", "fileName": "a.epub" },
            { "id": "bad", "title": "Manga", "format": "comic", "fileName": "a.cbz" }
          ]
        }
        """
        let directory = try Self.makeDirectory()
        try Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))

        let publications = FixturePublication.load(from: directory)

        XCTAssertEqual(publications.map(\.id), ["ok"])
    }

    func testMissingManifestYieldsNoFixturesInsteadOfCrashing() throws {
        let directory = try Self.makeDirectory()
        XCTAssertTrue(FixturePublication.load(from: directory).isEmpty)
    }

    func testMalformedManifestYieldsNoFixtures() throws {
        let directory = try Self.makeDirectory()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertTrue(FixturePublication.load(from: directory).isEmpty)
    }

    func testFileURLIsNilWhenTheFileIsNotInTheDirectory() throws {
        let directory = try Self.makeDirectory()
        let publication = fixture(fileName: "absent.epub")
        XCTAssertNil(publication.fileURL(in: directory))
    }

    func testFileURLResolvesWhenTheFileExists() throws {
        let directory = try Self.makeDirectory()
        try Data("PK".utf8).write(to: directory.appendingPathComponent("sample.epub"))
        XCTAssertNotNil(fixture().fileURL(in: directory))
    }

    // MARK: - Library service

    @MainActor
    func testFixturesAreExcludedWhenDisabled() async {
        let service = LibraryService(
            catalogEndpoint: URL(string: "https://api.example.com/catalog")!,
            fixturesDirectory: nil,
            includesLocalFixtures: false
        )
        XCTAssertTrue(service.fixtures.isEmpty)
    }

    @MainActor
    func testCatalogErrorStillYieldsFixtures() async {
        // A dead backend is the normal case in the demo, so it must degrade to
        // the bundled publications rather than an empty screen.
        let http = StubHTTPClient()
        let endpoint = URL(string: "https://api.example.com/catalog")!
        await http.stub(endpoint, with: HTTPError.transport("offline"))

        let service = LibraryService(
            catalogEndpoint: endpoint,
            fixturesDirectory: Self.writeFixtureBundle(),
            httpClient: http
        )
        await service.reload()

        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.errorMessage?.contains("bundled publications") == true)
        XCTAssertEqual(service.entries.map(\.id), ["fixture-epub"])
    }

    @MainActor
    func testRemoteEntriesAppearAlongsideFixtures() async {
        let http = StubHTTPClient()
        let endpoint = URL(string: "https://api.example.com/catalog")!
        await http.stub(
            endpoint,
            with: .text(#"{"books":[{"id":"42","title":"Remote Book","format":"pdf"}]}"#)
        )

        let service = LibraryService(
            catalogEndpoint: endpoint,
            fixturesDirectory: Self.writeFixtureBundle(),
            httpClient: http
        )
        await service.reload()

        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.entries.map(\.id), ["remote-42", "fixture-epub"])
    }

    @MainActor
    func testCatalogAcceptsABareArray() async {
        let http = StubHTTPClient()
        let endpoint = URL(string: "https://api.example.com/catalog")!
        await http.stub(endpoint, with: .text(#"[{"id":"7","title":"Bare","format":"epub"}]"#))

        let service = LibraryService(
            catalogEndpoint: endpoint,
            fixturesDirectory: nil,
            includesLocalFixtures: false,
            httpClient: http
        )
        await service.reload()

        XCTAssertEqual(service.entries.map(\.id), ["remote-7"])
    }

    @MainActor
    func testRequestCarriesTheBearerToken() async {
        let http = StubHTTPClient()
        let endpoint = URL(string: "https://api.example.com/catalog")!
        await http.stub(endpoint, with: .text(#"[]"#))

        let service = LibraryService(
            catalogEndpoint: endpoint,
            fixturesDirectory: nil,
            includesLocalFixtures: false,
            httpClient: http
        )
        let token = AuthToken(
            accessToken: "at-1",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3600)
        )
        await service.reload(token: token)

        let recorded = await http.recordedRequests
        XCTAssertEqual(recorded.first?.headers["Authorization"], "Bearer at-1")
    }

    // MARK: - Helpers

    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeFixtureBundle() -> URL? {
        let directory = try? makeDirectory()
        guard let directory else { return nil }
        let json = """
        { "publications": [
            { "id": "epub", "title": "Sample", "format": "epub", "fileName": "sample.epub" }
        ] }
        """
        try? Data(json.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

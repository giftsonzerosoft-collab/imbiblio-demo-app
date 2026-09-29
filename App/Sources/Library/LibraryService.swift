import Foundation
import iBiblioCore

/// One row in the library: a remote catalog entry, or a bundled fixture.
///
/// The two sources are intentionally different types. A remote `BookItem` has
/// whatever the server chose to send; a fixture has a name, a format and a local
/// file URL and no server-side identity at all.
enum LibraryEntry: Identifiable, Hashable {

    case remote(BookItem)
    case fixture(FixturePublication)

    var id: String {
        switch self {
        case .remote(let item): return "remote-\(item.id)"
        case .fixture(let fixture): return "fixture-\(fixture.id)"
        }
    }

    var title: String {
        switch self {
        case .remote(let item): return item.title
        case .fixture(let fixture): return fixture.title
        }
    }

    var author: String? {
        switch self {
        case .remote(let item): return item.author
        case .fixture(let fixture): return fixture.author
        }
    }

    var format: BookFormat {
        switch self {
        case .remote(let item): return item.format
        case .fixture(let fixture): return fixture.format
        }
    }

    /// The remote catalog is authoritative when it is reachable; fixtures are
    /// always appended so the demo works with no backend at all.
    var isFixture: Bool {
        if case .fixture = self { return true }
        return false
    }
}

/// A publication that ships inside the app bundle.
struct FixturePublication: Identifiable, Hashable {

    let id: String
    let title: String
    let author: String?
    let format: BookFormat
    let fileName: String

    /// Resolved lazily against the bundle; `nil` if the file is missing.
    func fileURL(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decodes `manifest.json`, written by `Scripts/generate_fixtures.py`.
    struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let title: String
            let author: String?
            let format: String
            let fileName: String
        }
        let publications: [Entry]
    }

    static func load(from directory: URL) -> [FixturePublication] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }

        return manifest.publications.compactMap { entry in
            guard let format = BookFormat(rawValue: entry.format) else { return nil }
            return FixturePublication(
                id: entry.id,
                title: entry.title,
                author: entry.author,
                format: format,
                fileName: entry.fileName
            )
        }
    }
}

/// Locates the bundled fixture directory inside the built app.
///
/// How XcodeGen puts `Resources/Fixtures` into the bundle depends on the
/// project's resource settings: a folder reference preserves the `Fixtures`
/// subdirectory, while individual file references flatten it into the bundle
/// root. Probing both is a few lines and removes the guesswork.
enum FixtureLocator {

    static func directory(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidates = [
            resources.appendingPathComponent("Fixtures", isDirectory: true),
            resources,
        ]
        for candidate in candidates
        where FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("manifest.json").path
        ) {
            return candidate
        }
        return nil
    }
}

/// Loads the library: remote catalog plus bundled fixtures.
@MainActor
final class LibraryService: ObservableObject {

    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let catalogEndpoint: URL
    let fixturesDirectory: URL?
    let includesLocalFixtures: Bool
    private let httpClient: HTTPClient

    init(
        catalogEndpoint: URL,
        fixturesDirectory: URL?,
        includesLocalFixtures: Bool = true,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.catalogEndpoint = catalogEndpoint
        self.fixturesDirectory = fixturesDirectory
        self.includesLocalFixtures = includesLocalFixtures
        self.httpClient = httpClient
    }

    var fixtures: [FixturePublication] {
        guard includesLocalFixtures, let fixturesDirectory else { return [] }
        return FixturePublication.load(from: fixturesDirectory)
    }

    /// Resolves the local file for a fixture entry, if the bundle still has it.
    func localURL(for entry: LibraryEntry) -> URL? {
        guard case .fixture(let fixture) = entry else { return nil }
        guard let fixturesDirectory else { return nil }
        return fixture.fileURL(in: fixturesDirectory)
    }

    func reload(token: AuthToken? = nil) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var remote: [BookItem] = []
        do {
            var request = HTTPRequest(method: .get, url: catalogEndpoint)
            request = request.authorized(with: token)
            let response = try await httpClient.send(request)
            guard response.isSuccess else {
                throw HTTPError.status(code: response.statusCode, body: response.bodyAsString)
            }
            if let envelope = try? response.decoded(BookItem.CatalogEnvelope.self) {
                remote = envelope.books
            } else {
                remote = (try? response.decoded([BookItem].self)) ?? []
            }
        } catch {
            // A missing backend is the normal case in the demo, so this is
            // reported but never blocks the bundled fixtures.
            errorMessage = includesLocalFixtures
                ? "Offline — showing bundled publications. (\(SessionStore.describe(error)))"
                : SessionStore.describe(error)
        }

        entries = remote.map(LibraryEntry.remote)
            + fixtures.map(LibraryEntry.fixture)
    }
}

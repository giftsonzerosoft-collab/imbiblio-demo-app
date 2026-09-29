import Foundation
import ReadiumShared
import ReadiumStreamer
import SwiftUI

/// Wraps Readium's *retrieval* layer so exactly one place in the app knows it
/// exists.
///
/// This is deliberately the only file that touches `ReadiumStreamer`. The rest of
/// the app works with `BookFormat` and `Publication`, which is what lets the
/// other 90% of the project build and test on Windows.
///
/// Rendering lives in `ReaderContainerView` (which imports `ReadiumNavigator`).
@MainActor
final class ReaderCoordinator: ObservableObject {

    enum Failure: LocalizedError {
        case notAbsoluteURL(URL)
        case unsupportedFormat(BookFormat)
        case formatMismatch(expected: BookFormat, actual: BookFormat)
        case unsupportedPublication(String)
        case couldNotOpen(String)

        var errorDescription: String? {
            switch self {
            case .notAbsoluteURL(let url):
                return "\(url.absoluteString) is not a URL Readium can read."
            case .unsupportedFormat(let format):
                return "iBiblio cannot open \(format.displayName) files."
            case .formatMismatch(let expected, let actual):
                return "This file is a \(actual.displayName), not the "
                    + "\(expected.displayName) the library expected."
            case .unsupportedPublication(let name):
                return "“\(name)” is not an EPUB, PDF or audiobook, so iBiblio "
                    + "cannot open it."
            case .couldNotOpen(let reason):
                return "Could not open the publication: \(reason)"
            }
        }
    }

    /// A parsed publication plus the format Readium detected for it.
    struct Opened: Identifiable {
        /// The *library entry's* id, not the publication URL. Views compare this
        /// against the row the user tapped so that a failed open cannot be
        /// mistaken for a successful one on a different book.
        let id: String
        let publication: Publication
        let format: BookFormat

        var title: String { publication.metadata.title ?? "Untitled" }
        var author: String? { publication.metadata.authors.first?.name }
    }

    /// A failed open, tagged with the entry that failed so a stale failure from
    /// one book is never shown on another.
    struct OpenFailure: Identifiable {
        let id: String
        let message: String
    }

    @Published private(set) var opened: Opened?
    @Published private(set) var isOpening = false
    @Published private(set) var failure: OpenFailure?

    // MARK: - Opening

    /// Opens a library entry. The entry's own `id` is what `Opened.id` will be,
    /// so the caller can compare them directly and never has to reconstruct the
    /// prefixed id by hand.
    func open(_ entry: LibraryEntry, fixturesDirectory: URL?) async {
        switch entry {
        case .fixture(let fixture):
            guard let fixturesDirectory,
                  let fileURL = fixture.fileURL(in: fixturesDirectory)
            else {
                fail(
                    id: entry.id,
                    .couldNotOpen("\(fixture.fileName) is missing from the app bundle.")
                )
                return
            }
            await open(id: entry.id, url: fileURL, expecting: fixture.format)

        case .remote(let item):
            guard let downloadURL = item.downloadURL else {
                fail(
                    id: entry.id,
                    .couldNotOpen("\(item.title) has no download URL in the catalog.")
                )
                return
            }
            await open(id: entry.id, url: downloadURL, expecting: item.format)
        }
    }

    /// Opens an arbitrary URL, synthesising an id from it. Prefer
    /// `open(_:fixturesDirectory:)`, which carries a real library id.
    func open(url: URL, expecting expected: BookFormat?) async {
        await open(id: url.absoluteString, url: url, expecting: expected)
    }

    private func open(id: String, url: URL, expecting expected: BookFormat?) async {
        isOpening = true
        failure = nil
        defer { isOpening = false }

        do {
            let result = try await Self.open(url: url, expecting: expected)
            opened = Opened(id: id, publication: result.publication, format: result.format)
        } catch {
            fail(id: id, error)
        }
    }

    func close() {
        opened = nil
    }

    private func fail(id: String, _ error: Error) {
        let message: String
        if let failure = error as? Failure {
            message = failure.errorDescription ?? ""
        } else {
            message = String(describing: error)
        }
        self.failure = OpenFailure(id: id, message: message)
        opened = nil
    }

    // MARK: - The Readium flow

    /// The three steps from https://readium.org/ios/quick_start.html, wrapped in
    /// one `async` function so callers never see Readium's `Result` wrappers.
    private static func open(
        url: URL,
        expecting expected: BookFormat?
    ) async throws -> (publication: Publication, format: BookFormat) {
        // 1. Dependencies. An HTTP client is required even for local files,
        //    because publications may reference remote resources.
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        // 2. Fetch the bytes. `AbsoluteURL` is Readium's typed URL, so a URL
        //    that is neither `file://` nor `http(s)://` fails here rather than
        //    deep inside the parser.
        guard let absolute = url.fileURL ?? url.httpURL else {
            throw Failure.notAbsoluteURL(url)
        }

        let asset = try await assetRetriever
            .retrieve(url: absolute)
            .get()

        // 3. Parse into a `Publication`.
        let publication = try await PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        .open(asset: asset, allowUserInteraction: true)
        .get()

        // 4. Decide what it is from the *publication profile*, not the asset's
        //    media type. A bare `.wav` sniffs as `FormatSpecification.wav`; only
        //    after parsing does it conform to `Profile.audiobook`. There is no
        //    `FormatSpecification.audiobook` to compare against.
        guard let format = BookFormat(readiumPublication: publication) else {
            throw Failure.unsupportedPublication(url.lastPathComponent ?? "file")
        }
        if let expected, expected != format {
            throw Failure.formatMismatch(expected: expected, actual: format)
        }

        return (publication, format)
    }
}

// MARK: - Bridging `BookFormat` to Readium

extension BookFormat {

    /// The publication profile Readium reports for this format.
    var readiumProfile: Publication.Profile {
        switch self {
        case .epub: return .epub
        case .pdf: return .pdf
        case .audiobook: return .audiobook
        }
    }

    /// Best-effort mapping from a parsed publication back to ours.
    init?(readiumPublication publication: Publication) {
        if publication.conforms(to: .epub) { self = .epub; return }
        if publication.conforms(to: .pdf) { self = .pdf; return }
        if publication.conforms(to: .audiobook) { self = .audiobook; return }
        return nil
    }
}

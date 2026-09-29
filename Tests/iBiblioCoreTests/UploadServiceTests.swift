import XCTest
@testable import iBiblioCore

final class UploadServiceTests: XCTestCase {

    private let endpoint = URL(string: "https://api.example.test/v1/books")!
    private let catalogEndpoint = URL(string: "https://api.example.test/v1/catalog")!

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ibiblio-upload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Helpers

    private func makeFile(name: String, contents: String = "payload") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeService(
        maxFileSizeInBytes: Int64 = 1024 * 1024,
        acceptedFormats: Set<BookFormat> = Set(BookFormat.allCases)
    ) -> UploadService {
        UploadService(
            configuration: UploadService.Configuration(
                uploadEndpoint: endpoint,
                maxFileSizeInBytes: maxFileSizeInBytes,
                acceptedFormats: acceptedFormats
            ),
            httpClient: StubHTTPClient()
        )
    }

    /// `StubHTTPClient.stub` is actor-isolated, so registering a reply is itself
    /// an `await`. Wrapping it in a bare `Task` would race the request that
    /// follows and make these tests intermittently fail with a 404.
    private func stub(_ http: StubHTTPClient, _ url: URL, with reply: StubHTTPClient.Reply) async {
        await http.stub(url, with: reply)
    }

    private func bookJSON(id: String = "srv-1", title: String = "Server Title", format: String = "epub") -> String {
        """
        {"id":"\(id)","title":"\(title)","format":"\(format)","sizeInBytes":7}
        """
    }

    // MARK: - Validation

    func testUnsupportedExtensionIsRejectedBeforeAnyNetworkCall() async throws {
        let file = try makeFile(name: "notes.txt")
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )

        do {
            _ = try await service.upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? UploadError, .unsupportedFormat("notes.txt"))
            let requests = await http.recordedRequests
            XCTAssertTrue(requests.isEmpty, "validation must happen before the request")
        }
    }

    func testFormatNotInAcceptedSetIsRejected() async throws {
        let file = try makeFile(name: "book.epub")
        let service = makeService(acceptedFormats: [.pdf])

        do {
            _ = try await service.upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? UploadError, .unsupportedFormat("book.epub"))
        }
    }

    func testEmptyFileIsRejected() async throws {
        let file = temporaryDirectory.appendingPathComponent("empty.epub")
        try Data().write(to: file)

        do {
            _ = try await makeService().upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? UploadError, .emptyFile)
        }
    }

    func testOversizedFileIsRejected() async throws {
        let file = try makeFile(name: "big.pdf", contents: String(repeating: "x", count: 100))
        let service = makeService(maxFileSizeInBytes: 50)

        do {
            _ = try await service.upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? UploadError, .fileTooLarge(bytes: 100, limit: 50))
        }
    }

    func testMissingFileIsRejected() async {
        let file = temporaryDirectory.appendingPathComponent("ghost.epub")

        do {
            _ = try await makeService().upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            guard case UploadError.fileNotReadable = error else {
                return XCTFail("expected fileNotReadable, got \(error)")
            }
        }
    }

    // MARK: - Happy path

    func testUploadsEachSupportedFormat() async throws {
        for format in BookFormat.allCases {
            let http = StubHTTPClient()
            let service = UploadService(
                configuration: UploadService.Configuration(uploadEndpoint: endpoint),
                httpClient: http
            )
            let file = try makeFile(name: "sample.\(format == .audiobook ? "wav" : format.rawValue)")
            await stub(http, endpoint, with: .text(bookJSON(format: format.rawValue), statusCode: 201))

            let item = try await service.upload(fileURL: file, title: "T", author: "A")
            XCTAssertEqual(item.id, "srv-1")
            XCTAssertEqual(item.format, format)

            let request = try await requireFirstRequest(http)
            XCTAssertEqual(request.method, .post)
            XCTAssertEqual(request.url, endpoint)
            XCTAssertTrue(
                request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true,
                request.headers["Content-Type"] ?? "nil"
            )
        }
    }

    func testRequestBodyContainsTitleAuthorFormatAndFile() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "book.epub", contents: "EPUBBYTES")
        await stub(http, endpoint, with: .text(bookJSON(), statusCode: 201))

        _ = try await service.upload(fileURL: file, title: "Dune", author: "Frank Herbert")

        let request = try await requireFirstRequest(http)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)

        XCTAssertTrue(body.contains("name=\"title\""))
        XCTAssertTrue(body.contains("Dune"))
        XCTAssertTrue(body.contains("name=\"author\""))
        XCTAssertTrue(body.contains("Frank Herbert"))
        XCTAssertTrue(body.contains("name=\"format\""))
        XCTAssertTrue(body.contains("epub"))
        XCTAssertTrue(body.contains("filename=\"book.epub\""))
        XCTAssertTrue(body.contains("Content-Type: application/epub+zip"))
        XCTAssertTrue(body.contains("EPUBBYTES"))
    }

    func testTitleDefaultsToFileNameWhenOmitted() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "The Hobbit.epub")
        await stub(http, endpoint, with: .text(bookJSON()))

        _ = try await service.upload(fileURL: file)

        let request = try await requireFirstRequest(http)
        XCTAssertTrue(
            String(decoding: request.body ?? Data(), as: UTF8.self).contains("The Hobbit")
        )
    }

    func testAuthorIsOmittedWhenEmpty() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.pdf")
        await stub(http, endpoint, with: .text(bookJSON(format: "pdf")))

        _ = try await service.upload(fileURL: file, title: "T", author: "")

        let request = try await requireFirstRequest(http)
        XCTAssertFalse(String(decoding: request.body ?? Data(), as: UTF8.self).contains("name=\"author\""))
    }

    func testContentLengthMatchesTheBodyLength() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.pdf", contents: String(repeating: "y", count: 300))
        await stub(http, endpoint, with: .text(bookJSON(format: "pdf")))

        _ = try await service.upload(fileURL: file, title: "T")

        let request = try await requireFirstRequest(http)
        XCTAssertEqual(request.headers["Content-Length"], String(request.body?.count ?? -1))
    }

    func testAuthorizationHeaderIsAttachedWhenTokenSupplied() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.epub")
        await stub(http, endpoint, with: .text(bookJSON()))

        let token = AuthToken(accessToken: "tok-123", expiresAt: Date().addingTimeInterval(3600))
        _ = try await service.upload(fileURL: file, token: token)

        let request = try await requireFirstRequest(http)
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok-123")
    }

    // MARK: - Response handling

    func testServerErrorIsMapped() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.epub")
        await stub(http, endpoint, with: .text(#"{"message":"file too large on server"}"#, statusCode: 413))

        do {
            _ = try await service.upload(fileURL: file)
            XCTFail("expected a throw")
        } catch {
            guard case UploadError.serverRejected(let status, let message) = error else {
                return XCTFail("expected serverRejected, got \(error)")
            }
            XCTAssertEqual(status, 413)
            XCTAssertTrue(message.contains("file too large"), message)
        }
    }

    /// A 200 with a body we cannot decode should not lose the upload.
    func testUndecodableSuccessResponseFallsBackToLocalMetadata() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "fallback.pdf", contents: "0123456789")
        await stub(http, endpoint, with: .text("OK", statusCode: 200))

        let item = try await service.upload(fileURL: file, title: "Local", author: "Nobody")
        XCTAssertFalse(item.id.isEmpty)
        XCTAssertEqual(item.title, "Local")
        XCTAssertEqual(item.format, .pdf)
        XCTAssertEqual(item.sizeInBytes, 10)
    }

    // MARK: - Progress

    func testStateSequenceReachesCompleted() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.epub")
        await stub(http, endpoint, with: .text(bookJSON()))

        let recorder = UploadStateRecorder()
        _ = try await service.upload(fileURL: file) { state in
            await recorder.append(state)
        }

        let states = await recorder.snapshot()
        XCTAssertEqual(states.first, .validating)
        XCTAssertEqual(states.last?.isTerminal, true)
        if case .completed = states.last {} else { XCTFail("expected .completed, got \(String(describing: states.last))") }
    }

    func testProgressFractionsAreMonotonicWithinBounds() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.epub")
        await stub(http, endpoint, with: .text(bookJSON()))

        let recorder = UploadStateRecorder()
        _ = try await service.upload(fileURL: file) { await recorder.append($0) }

        for state in await recorder.snapshot() {
            let fraction = state.fraction
            XCTAssertTrue((0...1).contains(fraction), "\(fraction) out of range for \(state)")
        }
    }

    func testProgressFractionsNeverGoBackwards() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        let file = try makeFile(name: "b.epub")
        await stub(http, endpoint, with: .text(bookJSON()))

        let recorder = UploadStateRecorder()
        _ = try await service.upload(fileURL: file) { await recorder.append($0) }

        var previous = -1.0
        for state in await recorder.snapshot() {
            XCTAssertGreaterThanOrEqual(state.fraction, previous, "fraction decreased at \(state)")
            previous = state.fraction
        }
    }

    func testEveryStateHasANonEmptyUserFacingMessage() async throws {
        let states: [UploadState] = [
            .idle,
            .validating,
            .readingFile,
            .uploading(fraction: 0),
            .uploading(fraction: 0.5),
            .uploading(fraction: 1),
            .serverProcessing,
            .completed(BookItem(id: "1", title: "Dune", format: .epub)),
            .failed("Disk full"),
        ]

        for state in states {
            XCTAssertFalse(
                state.message.trimmingCharacters(in: .whitespaces).isEmpty,
                "empty message for \(state)"
            )
        }
    }

    func testUploadMessageReportsThePercentage() {
        XCTAssertEqual(UploadState.uploading(fraction: 0.5).message, "Uploading… 50%")
        XCTAssertEqual(UploadState.uploading(fraction: 0).message, "Uploading… 0%")
        XCTAssertEqual(UploadState.uploading(fraction: 1).message, "Uploading… 100%")
    }

    func testFailureMessageIsPassedThroughUnchanged() {
        // The core owns the wording so the app never has to translate it.
        XCTAssertEqual(UploadState.failed("Disk full").message, "Disk full")
    }

    func testIsFailureOnlyMatchesTheFailedCase() {
        XCTAssertTrue(UploadState.failed("nope").isFailure)
        for state in [
            UploadState.idle,
            .validating,
            .readingFile,
            .uploading(fraction: 0.5),
            .serverProcessing,
            .completed(BookItem(id: "1", title: "Dune", format: .epub)),
        ] {
            XCTAssertFalse(state.isFailure, "\(state) should not read as a failure")
        }
    }

    func testIsFailureAndIsTerminalAgree() {
        XCTAssertTrue(UploadState.failed("nope").isFailure)
        XCTAssertTrue(UploadState.failed("nope").isTerminal)
        XCTAssertFalse(UploadState.idle.isTerminal)
        XCTAssertFalse(UploadState.uploading(fraction: 0.9).isTerminal)
    }

    func testCompletedMessageNamesTheBook() {
        let item = BookItem(id: "1", title: "Dune", format: .epub)
        XCTAssertEqual(UploadState.completed(item).message, "Added Dune")
    }

    // MARK: - Catalog

    func testFetchCatalogParsesEnvelope() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        await stub(http, catalogEndpoint, with: .text("""
        {"books":[{"id":"1","title":"A","format":"epub"},{"id":"2","title":"B","format":"pdf"}]}
        """))

        let books = try await service.fetchCatalog()
        XCTAssertEqual(books.map(\.title), ["A", "B"])
    }

    func testFetchCatalogAcceptsBareArray() async throws {
        let http = StubHTTPClient()
        let service = UploadService(
            configuration: UploadService.Configuration(uploadEndpoint: endpoint),
            httpClient: http
        )
        await stub(http, catalogEndpoint, with: .text(#"[{"id":"1","title":"A","format":"audiobook"}]"#))

        let books = try await service.fetchCatalog()
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.format, .audiobook)
    }
}

import XCTest
@testable import iBiblioCore

final class MultipartFormDataTests: XCTestCase {

    func testBoundaryIsUniquePerInstance() {
        XCTAssertNotEqual(MultipartFormData().boundary, MultipartFormData().boundary)
    }

    func testContentTypeHeader() {
        let form = MultipartFormData(boundary: "XYZ")
        XCTAssertEqual(form.contentTypeHeaderValue, "multipart/form-data; boundary=XYZ")
    }

    func testFieldPartHasNoFilenameOrContentType() {
        let form = MultipartFormData(boundary: "B")
        var mutable = form
        mutable.appendField("title", "Dune")

        let body = String(decoding: mutable.encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"title\""))
        XCTAssertTrue(body.contains("\r\n\r\nDune\r\n"))
        XCTAssertFalse(body.contains("filename="))
        XCTAssertFalse(body.contains("Content-Type:"))
    }

    func testFilePartIncludesFilenameAndContentType() {
        var form = MultipartFormData(boundary: "B")
        form.appendFile(
            name: "file",
            fileName: "book.epub",
            mimeType: "application/epub+zip",
            data: Data("PK".utf8)
        )

        let body = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"book.epub\""))
        XCTAssertTrue(body.contains("Content-Type: application/epub+zip"))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    /// The estimate is used for the `Content-Length` header, so it must be exact
    /// or the server will hang waiting for bytes that never arrive.
    func testEstimatedLengthMatchesActualEncoding() {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.appendField("title", "A somewhat long book title")
        form.appendField("author", "Ada Lovelace")
        form.appendFile(
            name: "file",
            fileName: "sample.pdf",
            mimeType: "application/pdf",
            data: Data(repeating: 0x42, count: 4096)
        )
        form.appendFile(
            name: "cover",
            fileName: "cover.jpg",
            mimeType: "image/jpeg",
            data: Data(repeating: 0xFF, count: 17)
        )

        XCTAssertEqual(form.estimatedEncodedLength(), form.encoded().count)
    }

    func testEmptyFormIsJustTheTerminator() {
        let form = MultipartFormData(boundary: "B")
        XCTAssertEqual(String(decoding: form.encoded(), as: UTF8.self), "--B--\r\n")
        XCTAssertEqual(form.estimatedEncodedLength(), form.encoded().count)
    }

    func testQuotesInFileNameAreEscaped() {
        var form = MultipartFormData(boundary: "B")
        form.appendFile(name: "file", fileName: "we\"ird.epub", mimeType: "a/b", data: Data())
        XCTAssertTrue(String(decoding: form.encoded(), as: UTF8.self).contains("filename=\"we%22ird.epub\""))
    }

    func testBinaryDataSurvivesEncoding() {
        let bytes = Data((0...255).map { UInt8($0) })
        var form = MultipartFormData(boundary: "B")
        form.appendFile(name: "file", fileName: "b.bin", mimeType: "application/octet-stream", data: bytes)

        XCTAssertTrue(form.encoded().containsSubsequence(bytes))
    }
}

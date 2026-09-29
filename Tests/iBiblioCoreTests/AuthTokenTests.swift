import XCTest
@testable import iBiblioCore

final class AuthTokenTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    func testExpiryUsesLeeway() {
        let token = AuthToken(
            accessToken: "a",
            expiresAt: reference.addingTimeInterval(20)
        )
        // 20s of life, 30s of leeway -> already unusable.
        XCTAssertTrue(token.isExpired(at: reference))
        XCTAssertFalse(token.isUsable(at: reference))
    }

    func testIsUsableWellBeforeExpiry() {
        let token = AuthToken(accessToken: "a", expiresAt: reference.addingTimeInterval(3600))
        XCTAssertFalse(token.isExpired(at: reference))
        XCTAssertTrue(token.isUsable(at: reference))
    }

    func testAuthorizationHeaderValue() {
        let token = AuthToken(accessToken: "abc", tokenType: "Bearer", expiresAt: reference)
        XCTAssertEqual(token.authorizationHeaderValue, "Bearer abc")
    }

    func testCanBeRefreshed() {
        XCTAssertTrue(AuthToken(accessToken: "a", refreshToken: "r", expiresAt: reference).canBeRefreshed)
        XCTAssertFalse(AuthToken(accessToken: "a", expiresAt: reference).canBeRefreshed)
    }

    // MARK: - Token endpoint parsing

    private func tokenBody(
        accessToken: String = "at",
        refreshToken: String? = "rt",
        tokenType: String? = "Bearer",
        expiresIn: Double? = 3600,
        extra: String = ""
    ) -> Data {
        var parts: [String] = ["\"access_token\":\"\(accessToken)\""]
        if let refreshToken { parts.append("\"refresh_token\":\"\(refreshToken)\"") }
        if let tokenType { parts.append("\"token_type\":\"\(tokenType)\"") }
        if let expiresIn { parts.append("\"expires_in\":\(expiresIn)") }
        parts.append(extra)
        return Data("{\(parts.joined(separator: ","))}".utf8)
    }

    func testParsesTokenEndpointResponse() throws {
        let token = try AuthToken.parse(
            tokenEndpointResponse: tokenBody(),
            receivedAt: reference
        )
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.tokenType, "Bearer")
        XCTAssertEqual(token.expiresAt, reference.addingTimeInterval(3600))
    }

    func testExpiresInIsRelativeToReceiptTime() throws {
        let token = try AuthToken.parse(
            tokenEndpointResponse: tokenBody(expiresIn: 60),
            receivedAt: reference
        )
        XCTAssertEqual(token.expiresAt.timeIntervalSince(reference), 60, accuracy: 0.001)
    }

    func testMissingExpiresInFallsBackToDefault() throws {
        let token = try AuthToken.parse(
            tokenEndpointResponse: tokenBody(expiresIn: nil),
            receivedAt: reference
        )
        XCTAssertEqual(
            token.expiresAt.timeIntervalSince(reference),
            AuthToken.defaultLifetime,
            accuracy: 0.001
        )
    }

    func testMissingTokenTypeDefaultsToBearer() throws {
        let token = try AuthToken.parse(
            tokenEndpointResponse: tokenBody(tokenType: nil),
            receivedAt: reference
        )
        XCTAssertEqual(token.tokenType, "Bearer")
    }

    func testMalformedBodyThrowsInvalidTokenResponse() {
        XCTAssertThrowsError(
            try AuthToken.parse(tokenEndpointResponse: Data("not json".utf8))
        ) { error in
            guard case AuthError.invalidTokenResponse = error else {
                return XCTFail("expected invalidTokenResponse, got \(error)")
            }
        }
    }

    func testMissingAccessTokenThrows() {
        XCTAssertThrowsError(
            try AuthToken.parse(tokenEndpointResponse: Data("{\"token_type\":\"Bearer\"}".utf8))
        )
    }

    // MARK: - Codable round trip

    func testCodableRoundTrip() throws {
        let original = AuthToken(
            accessToken: "at",
            refreshToken: "rt",
            tokenType: "Bearer",
            expiresAt: reference,
            scope: "openid profile",
            idToken: "it"
        )
        let data = try JSONEncoder.json.encode(original)
        let decoded = try JSONDecoder.json.decode(AuthToken.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - id_token introspection

    /// Builds an unsigned JWT for testing. The demo never verifies signatures —
    /// see `AuthToken.subjectFromIDToken()`.
    private func makeIDToken(claims: [String: String]) -> String {
        func segment(_ object: [String: String]) -> String {
            let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return Base64URL.encode(json)
        }
        let header = segment(["alg": "none", "typ": "JWT"])
        let payload = segment(claims)
        return "\(header).\(payload).signature"
    }

    func testExtractsSubjectFromIDToken() {
        let token = AuthToken(
            accessToken: "at",
            expiresAt: reference,
            idToken: makeIDToken(claims: ["sub": "user-42", "name": "Ada Lovelace", "email": "ada@example.com"])
        )
        XCTAssertEqual(token.subjectFromIDToken(), "user-42")
        XCTAssertEqual(token.claim("email"), "ada@example.com")
    }

    func testUserProfileFallsBackToSubject() {
        let token = AuthToken(accessToken: "at", expiresAt: reference)
        let profile = token.userProfile()
        XCTAssertEqual(profile.subject, "reader")
        XCTAssertEqual(profile.displayName, "reader")
    }

    func testMalformedIDTokenIsIgnored() {
        let token = AuthToken(accessToken: "at", expiresAt: reference, idToken: "garbage")
        XCTAssertNil(token.subjectFromIDToken())
        XCTAssertEqual(token.userProfile().subject, "reader")
    }
}

final class BookFormatTests: XCTestCase {

    func testDetectFromFileName() {
        XCTAssertEqual(BookFormat.detect(fileName: "book.epub"), .epub)
        XCTAssertEqual(BookFormat.detect(fileName: "paper.PDF"), .pdf)
        XCTAssertEqual(BookFormat.detect(fileName: "track.mp3"), .audiobook)
        XCTAssertEqual(BookFormat.detect(fileName: "narrated.audiobook"), .audiobook)
        XCTAssertEqual(BookFormat.detect(fileName: "bundle.zip"), .audiobook)
        XCTAssertEqual(BookFormat.detect(fileName: "scan.wav"), .audiobook)
    }

    func testDetectFromPath() {
        XCTAssertEqual(BookFormat.detect(fileName: "/a/b/c/story.epub"), .epub)
    }

    func testUnknownAndMissingExtensionsReturnNil() {
        XCTAssertNil(BookFormat.detect(fileName: "notes.txt"))
        XCTAssertNil(BookFormat.detect(fileName: "noextension"))
        XCTAssertNil(BookFormat.detect(fileName: "trailing."))
    }

    func testDetectFromMIMEType() {
        XCTAssertEqual(BookFormat.detect(mimeType: "application/epub+zip"), .epub)
        XCTAssertEqual(BookFormat.detect(mimeType: "application/pdf"), .pdf)
        XCTAssertEqual(BookFormat.detect(mimeType: "audio/mpeg"), .audiobook)
        XCTAssertEqual(BookFormat.detect(mimeType: "audio/wav"), .audiobook)
        XCTAssertEqual(BookFormat.detect(mimeType: "APPLICATION/PDF"), .pdf)
        XCTAssertEqual(BookFormat.detect(mimeType: "application/pdf; charset=binary"), .pdf)
        XCTAssertNil(BookFormat.detect(mimeType: "text/html"))
    }

    func testEveryFormatHasAUniqueRawValue() {
        XCTAssertEqual(Set(BookFormat.allCases.map(\.rawValue)).count, 3)
    }
}

final class BookItemTests: XCTestCase {

    func testFormattedSizeAndDuration() {
        let item = BookItem(
            id: "1",
            title: "T",
            format: .audiobook,
            sizeInBytes: 5_368_709,
            durationSeconds: 3725
        )
        XCTAssertEqual(item.formattedDuration, "62:05")
        XCTAssertNotNil(item.formattedSize)
    }

    func testFormattedHelpersReturnNilWhenAbsent() {
        let item = BookItem(id: "1", title: "T", format: .epub)
        XCTAssertNil(item.formattedSize)
        XCTAssertNil(item.formattedDuration)
    }

    func testCatalogEnvelopeDecodes() throws {
        let json = Data("""
        {"books":[
          {"id":"a","title":"E","format":"epub"},
          {"id":"b","title":"P","format":"pdf"},
          {"id":"c","title":"A","format":"audiobook"}
        ]}
        """.utf8)
        let envelope = try JSONDecoder.json.decode(BookItem.CatalogEnvelope.self, from: json)
        XCTAssertEqual(envelope.books.count, 3)
        XCTAssertEqual(envelope.books.map(\.format), [.epub, .pdf, .audiobook])
    }
}

import XCTest
@testable import iBiblioCore

final class PKCETests: XCTestCase {

    func testChallengeIsBase64URLOfSHA256() {
        // RFC 7636 Appendix B test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(PKCEPair.challenge(for: verifier), expected)
    }

    func testGeneratedPairIsInternallyConsistent() {
        let pair = PKCEPair.generate()
        XCTAssertEqual(pair.challenge, PKCEPair.challenge(for: pair.verifier))
        XCTAssertTrue(PKCEPair.isValidVerifier(pair.verifier))
    }

    func testGeneratedVerifiersAreUnique() {
        let verifiers = (0..<64).map { _ in PKCEPair.generate().verifier }
        XCTAssertEqual(Set(verifiers).count, verifiers.count, "verifiers must not repeat")
    }

    func testVerifierLengthIsExactlyTheRFCMinimum() {
        XCTAssertEqual(PKCEPair.generate().verifier.count, PKCEPair.minimumVerifierLength)
    }

    /// RFC 7636 §4.1: 43..128 characters from the unreserved set.
    func testVerifierGrammar() {
        XCTAssertFalse(PKCEPair.isValidVerifier(String(repeating: "a", count: 42)))
        XCTAssertTrue(PKCEPair.isValidVerifier(String(repeating: "a", count: 43)))
        XCTAssertTrue(PKCEPair.isValidVerifier(String(repeating: "a", count: 128)))
        XCTAssertFalse(PKCEPair.isValidVerifier(String(repeating: "a", count: 129)))
        // 13 unreserved characters padded to the 43-character minimum.
        XCTAssertTrue(PKCEPair.isValidVerifier("abcABC123-._~" + String(repeating: "a", count: 30)))
        XCTAssertFalse(PKCEPair.isValidVerifier("has spaces in it"))
        XCTAssertFalse(PKCEPair.isValidVerifier("has/slash"))
    }
}

final class SecureRandomTests: XCTestCase {

    func testProducesRequestedCount() {
        XCTAssertEqual(SecureRandom.bytes(count: 32).count, 32)
        XCTAssertEqual(SecureRandom.bytes(count: 0).count, 0)
    }

    func testOutputIsNotConstant() {
        let values = (0..<16).map { _ in SecureRandom.hexString(byteCount: 16) }
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testHexStringLength() {
        XCTAssertEqual(SecureRandom.hexString(byteCount: 16).count, 32)
    }
}

final class URLEncodedFormTests: XCTestCase {

    func testEncodesUnreservedCharactersUnchanged() {
        var form = URLEncodedForm()
        form.add("key", "abcXYZ019-._~")
        XCTAssertEqual(form.encodedString, "key=abcXYZ019-._~")
    }

    func testEscapesReservedAndNonASCIICharacters() {
        var form = URLEncodedForm()
        form.add("q", "a b&c=d+e/f?g#h")
        XCTAssertEqual(form.encodedString, "q=a%20b%26c%3Dd%2Be%2Ff%3Fg%23h")
    }

    func testEscapesPlusExplicitly() {
        // A bare '+' would be read back as a space.
        var form = URLEncodedForm()
        form.add("k", "a+b")
        XCTAssertEqual(form.encodedString, "k=a%2Bb")
    }

    func testRoundTripsThroughDecode() {
        let value = "söme wîrd/value?with=stuff&more"
        var form = URLEncodedForm()
        form.add("field", value)
        let decoded = URLEncodedForm.decode(form.encodedString)
        XCTAssertEqual(decoded["field"], value)
    }

    func testDecodeHandlesPlusAsSpace() {
        XCTAssertEqual(URLEncodedForm.decode("a=hello+world")["a"], "hello world")
    }

    func testDecodeHandlesValuelessKeys() {
        let decoded = URLEncodedForm.decode("flag&a=1")
        XCTAssertEqual(decoded["flag"], "")
        XCTAssertEqual(decoded["a"], "1")
    }
}

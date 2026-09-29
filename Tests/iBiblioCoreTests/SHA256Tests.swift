import XCTest
@testable import iBiblioCore

/// Pins the hand-rolled SHA-256 to the published FIPS 180-4 / NIST vectors.
///
/// This is the only reason `iBiblioCore` can compute an RFC 7636 `code_challenge`
/// without pulling in CryptoKit (Apple-only) or CryptoSwift (a dependency in the
/// package that must stay trivially buildable on Windows).
final class SHA256Tests: XCTestCase {

    func testKnownVectors() {
        // NIST FIPS 180-4 examples.
        XCTAssertEqual(
            SHA256.hexDigest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hexDigest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hexDigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    /// Exercises all three padding branches: needs 0, 1 and 2 extra blocks.
    func testPaddingBoundaries() {
        // 55 bytes fits in one block with the length field in the same block.
        XCTAssertEqual(
            SHA256.hexDigest(String(repeating: "a", count: 55)),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
        )
        // 56 bytes forces a second block.
        XCTAssertEqual(
            SHA256.hexDigest(String(repeating: "a", count: 56)),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
        // 64 bytes is exactly one full block.
        XCTAssertEqual(
            SHA256.hexDigest(String(repeating: "a", count: 64)),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
    }

    func testDigestLengthIsAlwaysThirtyTwoBytes() {
        for length in [0, 1, 55, 56, 63, 64, 65, 1000] {
            XCTAssertEqual(
                SHA256.hash([UInt8](repeating: 0x41, count: length)).count,
                32,
                "length \(length)"
            )
        }
    }

    func testHashingDataMatchesHashingBytes() {
        let data = Data("The quick brown fox jumps over the lazy dog".utf8)
        XCTAssertEqual(SHA256.hash(data), SHA256.hash([UInt8](data)))
    }
}

final class Base64URLTests: XCTestCase {

    func testRoundTrip() throws {
        for byteCount in [0, 1, 15, 16, 31, 32, 64] {
            let data = Data((0..<byteCount).map { UInt8(($0 &* 7 &+ 3) & 0xFF) })
            let encoded = Base64URL.encode(data)
            XCTAssertEqual(try XCTUnwrap(Base64URL.decode(encoded)), data, "byteCount \(byteCount)")
        }
    }

    func testEncodingIsURLSafeAndUnpadded() {
        // 0xFB 0xFF 0xFE encodes to "++//" in standard base64.
        let data = Data([0xFB, 0xFF, 0xFE])
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(encoded, "-__-")
    }

    func testInvalidLengthIsRejected() {
        // A base64 string whose length % 4 == 1 can never be valid.
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("ABCDE"))
    }
}

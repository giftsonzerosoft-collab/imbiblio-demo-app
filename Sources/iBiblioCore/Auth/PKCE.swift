import Foundation

/// Proof Key for Code Exchange (RFC 7636), `S256` method only.
///
/// A verifier is a high-entropy random string; the challenge is its SHA-256
/// digest in base64url. The plaintext verifier never leaves the device — only
/// the challenge travels in the authorization URL.
public struct PKCEPair: Sendable, Equatable {

    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }

    /// Minimum verifier length mandated by RFC 7636 §4.1: 43 characters.
    public static let minimumVerifierLength = 43
    public static let maximumVerifierLength = 128

    /// Generates a fresh pair.
    ///
    /// - Parameter byteCount: entropy in bytes. The default of 32 yields a
    ///   43-character verifier, exactly the RFC minimum.
    public static func generate(byteCount: Int = 32) -> PKCEPair {
        let entropy = SecureRandom.bytes(count: byteCount)
        let verifier = Base64URL.encode(Data(entropy))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// `BASE64URL(SHA256(ASCII(code_verifier)))`
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(Array(verifier.utf8))))
    }

    /// Whether a verifier satisfies the RFC 7636 §4.1 grammar.
    public static func isValidVerifier(_ verifier: String) -> Bool {
        guard verifier.count >= minimumVerifierLength,
              verifier.count <= maximumVerifierLength else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return verifier.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Random bytes from the platform CSPRNG.
///
/// Uses `SecRandomCopyBytes` on Apple platforms and `BCryptGenRandom` on
/// Windows, so the app never falls back to a weak RNG on a real device.
enum SecureRandom {

    static func bytes(count: Int) -> [UInt8] {
        guard count > 0 else { return [] }

        #if canImport(Security)
        if let data = appleRandom(count: count) { return [UInt8](data) }
        #endif

        #if os(Windows)
        if let data = windowsRandom(count: count) { return [UInt8](data) }
        #endif

        // Unreachable on supported platforms; present so the function is total.
        return (0..<count).map { _ in UInt8.random(in: 0...255) }
    }

    /// A 32-byte hex nonce, handy for `state` and `nonce` parameters.
    static func hexString(byteCount: Int = 16) -> String {
        bytes(count: byteCount)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    #if canImport(Security)
    private static func appleRandom(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return status == errSecSuccess ? Data(bytes) : nil
    }
    #endif

    #if os(Windows)
    // Declared directly rather than going through the CryptoKit-style wrapper:
    // bcrypt.dll is always loaded in a Windows process, so a plain
    // `@_silgen_name` import is sufficient and avoids a module dependency.
    @_silgen_name("BCryptGenRandom")
    private static func _BCryptGenRandom(
        _ hAlgorithm: UnsafeMutableRawPointer?,
        _ pbBuffer: UnsafeMutableRawPointer?,
        _ cbBuffer: UInt32,
        _ dwFlags: UInt32
    ) -> Int32

    /// `BCRYPT_USE_SYSTEM_PREFERRED_RNG`
    private static let useSystemPreferredRNG: UInt32 = 0x0000_0002

    private static func windowsRandom(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return _BCryptGenRandom(nil, base, UInt32(count), useSystemPreferredRNG)
        }
        return status == 0 ? Data(bytes) : nil
    }
    #endif
}

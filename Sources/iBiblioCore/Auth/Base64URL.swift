import Foundation

/// base64url encoding (RFC 4648 §5) — the encoding PKCE requires.
enum Base64URL {

    static func encode(_ data: Data) -> String {
        var string = data.base64EncodedString()
        string = string.replacingOccurrences(of: "+", with: "-")
        string = string.replacingOccurrences(of: "/", with: "_")
        while string.hasSuffix("=") {
            string.removeLast()
        }
        return string
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Restore padding. Length % 4 == 1 is not a valid base64 length.
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

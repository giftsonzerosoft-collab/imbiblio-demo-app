import Foundation

/// `application/x-www-form-urlencoded` serialisation and parsing.
///
/// Hand-rolled because `URLComponents.queryItems` cannot be trusted to
/// percent-encode consistently across Foundation versions, and the OAuth token
/// endpoint is strict about it. Also used to decode the redirect callback.
public struct URLEncodedForm: Sendable, Equatable {

    public private(set) var pairs: [(name: String, value: String)] = []

    public init() {}

    public mutating func add(_ name: String, _ value: String) {
        pairs.append((name, value))
    }

    public func encoded() -> Data {
        let string = pairs
            .map { "\(FormEncoding.escape($0.name))=\(FormEncoding.escape($0.value))" }
            .joined(separator: "&")
        return Data(string.utf8)
    }

    public var encodedString: String {
        String(decoding: encoded(), as: UTF8.self)
    }

    /// Written by hand: the backing store is an array of tuples, and tuple
    /// members are not `Equatable`-synthesisable.
    public static func == (lhs: URLEncodedForm, rhs: URLEncodedForm) -> Bool {
        lhs.pairs.count == rhs.pairs.count &&
            zip(lhs.pairs, rhs.pairs).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    /// Decodes a query string. Later duplicates win, matching `URLComponents`.
    public static func decode(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first else { continue }
            let name = FormEncoding.unescape(String(rawName))
            let value = parts.count > 1 ? FormEncoding.unescape(String(parts[1])) : ""
            result[name] = value
        }
        return result
    }
}

enum FormEncoding {

    /// Percent-encodes everything except the RFC 3986 unreserved set.
    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // `+` means space in form encoding, so it must itself be escaped.
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func unescape(_ value: String) -> String {
        let plusDecoded = value.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }
}

import Foundation

/// `multipart/form-data` encoder (RFC 7578).
///
/// Hand-rolled to keep `iBiblioCore` dependency-free and therefore buildable on
/// Windows. It streams through an `OutputStream`, so a large audiobook never has
/// to be held twice in memory.
public struct MultipartFormData: Sendable {

    public struct Part: Sendable {
        public var name: String
        public var fileName: String?
        public var mimeType: String?
        public var data: Data

        public init(name: String, fileName: String? = nil, mimeType: String? = nil, data: Data) {
            self.name = name
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }

        /// A plain text field.
        public static func field(_ name: String, _ value: String) -> Part {
            Part(name: name, data: Data(value.utf8))
        }

        /// A binary file part. The caller supplies the bytes.
        public static func file(
            name: String,
            fileName: String,
            mimeType: String,
            data: Data
        ) -> Part {
            Part(name: name, fileName: fileName, mimeType: mimeType, data: data)
        }
    }

    public let boundary: String
    public private(set) var parts: [Part] = []

    public init(boundary: String? = nil) {
        self.boundary = boundary ?? "Boundary+\(SecureRandom.hexString(byteCount: 16))"
    }

    public mutating func append(_ part: Part) {
        parts.append(part)
    }

    public mutating func appendField(_ name: String, _ value: String) {
        parts.append(.field(name, value))
    }

    public mutating func appendFile(
        name: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) {
        parts.append(.file(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    public var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    // MARK: - Serialisation

    public func encoded() -> Data {
        var result = Data()
        for part in parts {
            result.append(Data("--\(boundary)\r\n".utf8))

            var disposition = "Content-Disposition: form-data; name=\"\(escapeQuotes(part.name))\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(escapeQuotes(fileName))\""
            }
            result.append(Data((disposition + "\r\n").utf8))

            if let mimeType = part.mimeType {
                result.append(Data("Content-Type: \(mimeType)\r\n".utf8))
            }
            result.append(Data("\r\n".utf8))
            result.append(part.data)
            result.append(Data("\r\n".utf8))
        }
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    /// Total byte count of `encoded()`, computed without building the payload.
    /// Used for upload progress without buffering.
    public func estimatedEncodedLength() -> Int {
        var total = 0
        for part in parts {
            total += boundary.utf8.count + 4          // "--" + boundary + CRLF
            total += "Content-Disposition: form-data; name=\"\(escapeQuotes(part.name))\"".utf8.count
            if let fileName = part.fileName {
                total += "; filename=\"\(escapeQuotes(fileName))\"".utf8.count
            }
            total += 2                                  // CRLF
            if let mimeType = part.mimeType {
                total += "Content-Type: \(mimeType)\r\n".utf8.count
            }
            total += 2                                  // blank line CRLF
            total += part.data.count
            total += 2                                  // trailing CRLF
        }
        total += boundary.utf8.count + 6                // "--" + boundary + "--" + CRLF
        return total
    }

    private func escapeQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22")
    }
}

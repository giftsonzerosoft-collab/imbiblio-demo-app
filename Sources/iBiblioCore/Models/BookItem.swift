import Foundation

/// A book as returned by the (mock or real) catalog API.
public struct BookItem: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var title: String
    public var author: String?
    public var format: BookFormat
    public var downloadURL: URL?
    public var coverURL: URL?
    public var sizeInBytes: Int64?
    public var durationSeconds: Double?

    public init(
        id: String,
        title: String,
        author: String? = nil,
        format: BookFormat,
        downloadURL: URL? = nil,
        coverURL: URL? = nil,
        sizeInBytes: Int64? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.downloadURL = downloadURL
        self.coverURL = coverURL
        self.sizeInBytes = sizeInBytes
        self.durationSeconds = durationSeconds
    }

    public var formattedSize: String? {
        guard let sizeInBytes, sizeInBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    public var formattedDuration: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let total = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Catalog responses

extension BookItem {

    /// Response body of `GET /catalog`.
    public struct CatalogEnvelope: Decodable, Sendable {
        public var books: [BookItem]
        public init(books: [BookItem]) { self.books = books }
    }
}

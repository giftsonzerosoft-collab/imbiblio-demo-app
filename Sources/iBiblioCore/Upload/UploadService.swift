import Foundation

/// Uploads a PDF / EPUB / audiobook to the catalog backend as `multipart/form-data`.
///
/// The whole service is transport- and store-agnostic, so the full flow —
/// validation, file reading, encoding, request construction, response decoding
/// and error mapping — is unit-tested on Windows. Readium plays no part in the
/// *upload* direction: it is only involved when the uploaded file is later
/// opened for reading.
public actor UploadService {

    public struct Configuration: Sendable {
        public var uploadEndpoint: URL
        public var maxFileSizeInBytes: Int64
        public var acceptedFormats: Set<BookFormat>

        public init(
            uploadEndpoint: URL,
            maxFileSizeInBytes: Int64 = 512 * 1024 * 1024,
            acceptedFormats: Set<BookFormat> = Set(BookFormat.allCases)
        ) {
            self.uploadEndpoint = uploadEndpoint
            self.maxFileSizeInBytes = maxFileSizeInBytes
            self.acceptedFormats = acceptedFormats
        }
    }

    private let configuration: Configuration
    private let httpClient: HTTPClient
    private let fileManager: FileManager

    public init(
        configuration: Configuration,
        httpClient: HTTPClient,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.fileManager = fileManager
    }

    // MARK: - Upload

    /// Validates, reads and uploads `fileURL`.
    ///
    /// - Parameter onState: awaited as the upload advances, so implementations
    ///   may hop to `@MainActor` before touching UI.
    /// - Returns: the catalog entry the server created.
    @discardableResult
    public func upload(
        fileURL: URL,
        title: String? = nil,
        author: String? = nil,
        token: AuthToken? = nil,
        onState: @Sendable @escaping (UploadState) async -> Void = { _ in }
    ) async throws -> BookItem {

        // 1. Validate -----------------------------------------------------
        await onState(.validating)

        let fileName = fileURL.lastPathComponent
        guard let format = BookFormat.detect(fileName: fileName) else {
            throw UploadError.unsupportedFormat(fileName)
        }
        guard configuration.acceptedFormats.contains(format) else {
            throw UploadError.unsupportedFormat(fileName)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw UploadError.fileNotReadable(fileURL.path)
        }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw UploadError.fileNotReadable(fileURL.path)
        }
        guard size > 0 else { throw UploadError.emptyFile }
        guard size <= configuration.maxFileSizeInBytes else {
            throw UploadError.fileTooLarge(bytes: size, limit: configuration.maxFileSizeInBytes)
        }

        // 2. Read ---------------------------------------------------------
        await onState(.readingFile)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw UploadError.fileNotReadable(error.localizedDescription)
        }

        // 3. Encode + POST -------------------------------------------------
        var form = MultipartFormData()
        form.appendField("title", title ?? fileURL.deletingPathExtension().lastPathComponent)
        if let author, !author.isEmpty {
            form.appendField("author", author)
        }
        form.appendField("format", format.rawValue)
        form.appendFile(
            name: "file",
            fileName: fileName,
            mimeType: format.defaultMIMEType,
            data: data
        )

        await onState(.uploading(fraction: 0))

        var request = HTTPRequest(
            method: .post,
            url: configuration.uploadEndpoint,
            headers: [
                "Content-Type": form.contentTypeHeaderValue,
                "Content-Length": String(form.estimatedEncodedLength()),
                "Accept": "application/json"
            ],
            body: form.encoded()
        )
        request = request.authorized(with: token)

        await onState(.serverProcessing)

        let response = try await httpClient.send(request)
        guard response.isSuccess else {
            let message = (try? response.decoded(ServerErrorEnvelope.self))?.message
                ?? response.bodyAsString
            throw UploadError.serverRejected(statusCode: response.statusCode, message: message)
        }

        let item: BookItem
        do {
            item = try response.decoded(BookItem.self)
        } catch {
            // Some servers answer 200 with a bare id; tolerate that.
            item = BookItem(
                id: UUID().uuidString,
                title: title ?? fileName,
                author: author,
                format: format,
                sizeInBytes: size
            )
        }

        await onState(.completed(item))
        return item
    }

    // MARK: - Catalog

    /// `GET` the catalog.
    public func fetchCatalog(token: AuthToken? = nil) async throws -> [BookItem] {
        let catalogURL = configuration.uploadEndpoint
            .deletingLastPathComponent()
            .appendingPathComponent("catalog")

        var request = HTTPRequest(method: .get, url: catalogURL, headers: ["Accept": "application/json"])
        request = request.authorized(with: token)

        let response = try await httpClient.send(request)
        guard response.isSuccess else {
            throw UploadError.serverRejected(statusCode: response.statusCode, message: response.bodyAsString)
        }

        if let envelope = try? response.decoded(BookItem.CatalogEnvelope.self) {
            return envelope.books
        }
        return (try? response.decoded([BookItem].self)) ?? []
    }

    // MARK: - Private

    private struct ServerErrorEnvelope: Decodable {
        let message: String
    }
}

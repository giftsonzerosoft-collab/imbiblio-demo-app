import Foundation

/// `TokenStore` backed by a JSON file.
///
/// Used on Windows and macOS, and as the fallback whenever the Keychain is
/// unavailable. The file is written atomically with restrictive permissions.
public actor FileTokenStore: TokenStore {

    private let fileURL: URL
    private var cache: AuthToken?

    /// - Parameter directory: where to place the file. Defaults to the
    ///   user caches directory, which is writable on every platform and does
    ///   not get backed up to iCloud.
    public init(directory: URL? = nil, fileName: String = "ibiblio-token.json") {
        let base = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base.appendingPathComponent(fileName, isDirectory: false)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var storageURL: URL { fileURL }

    public func load() async throws -> AuthToken? {
        if let cache { return cache }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return nil }
            let token = try JSONDecoder.json.decode(AuthToken.self, from: data)
            cache = token
            return token
        } catch {
            // A corrupt store must not be fatal — drop it and start clean.
            try? FileManager.default.removeItem(at: fileURL)
            cache = nil
            return nil
        }
    }

    public func save(_ token: AuthToken) async throws {
        do {
            let data = try JSONEncoder.json.encode(token)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])

            #if os(Windows)
            // POSIX permissions are unavailable; nothing to tighten.
            #else
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            #endif

            cache = token
        } catch {
            throw AuthError.tokenStoreFailure(error.localizedDescription)
        }
    }

    public func clear() async throws {
        cache = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

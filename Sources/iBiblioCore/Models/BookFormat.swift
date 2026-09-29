import Foundation

/// The three publication kinds this demo supports.
///
/// Deliberately declared here (and not in the Readium layer) so that format
/// detection, upload validation and unit tests all work on Windows. The mapping
/// from `BookFormat` to a Readium `Profile` lives in
/// `App/Sources/Reader/BookFormat+Readium.swift`.
public enum BookFormat: String, Codable, Sendable, CaseIterable, Equatable {
    case epub
    case pdf
    case audiobook

    public var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .audiobook: return "Audiobook"
        }
    }

    /// SF Symbol used in the UI. Resolved by the App layer, kept here as a plain
    /// string so `iBiblioCore` stays free of UIKit.
    public var symbolName: String {
        switch self {
        case .epub: return "book.closed"
        case .pdf: return "doc.richtext"
        case .audiobook: return "headphones"
        }
    }

    /// Extensions accepted for this format, lowercased and without the dot.
    public var acceptedExtensions: Set<String> {
        switch self {
        case .epub: return ["epub"]
        case .pdf: return ["pdf"]
        // Readium supports Readium Audiobook, zipped audiobooks and standalone
        // audio files; the demo fixture is a standalone .wav.
        case .audiobook: return ["audiobook", "zip", "wav", "mp3", "m4a", "aac", "mp4"]
        }
    }

    /// Detects a format from a file name or path.
    ///
    /// Zipped archives (`.zip`, `.audiobook`) are reported as audiobooks, which
    /// is what they are in the Readium world for this demo.
    public static func detect(fileName: String) -> BookFormat? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        for format in BookFormat.allCases where format.acceptedExtensions.contains(ext) {
            return format
        }
        return nil
    }

    /// Detects a format from a MIME type reported by a server.
    public static func detect(mimeType: String) -> BookFormat? {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""

        switch normalized {
        case "application/epub+zip":
            return .epub
        case "application/pdf":
            return .pdf
        case "audio/mpeg", "audio/mp3", "audio/mp4", "audio/aac", "audio/wav",
             "audio/x-wav", "audio/wave", "audio/vnd.wave", "audio/x-pn-wav":
            return .audiobook
        default:
            return nil
        }
    }

    /// Default `Content-Type` sent when uploading this format.
    public var defaultMIMEType: String {
        switch self {
        case .epub: return "application/epub+zip"
        case .pdf: return "application/pdf"
        // A zipped audiobook's real type depends on its contents.
        case .audiobook: return "application/octet-stream"
        }
    }

    /// Everything needed to list supported uploads in the picker.
    public static var supportedExtensions: [String] {
        allCases.flatMap { Array($0.acceptedExtensions) }.sorted()
    }
}

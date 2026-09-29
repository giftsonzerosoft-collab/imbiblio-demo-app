import Foundation

/// Errors from the upload pipeline.
public enum UploadError: Error, Sendable, Equatable {
    case fileNotReadable(String)
    case unsupportedFormat(String)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case emptyFile
    case offline
    case serverRejected(statusCode: Int, message: String)
}

/// Observable state of one upload.
public enum UploadState: Sendable, Equatable {
    case idle
    case validating
    case readingFile
    case uploading(fraction: Double)
    case serverProcessing
    case completed(BookItem)
    case failed(String)

    public var isTerminal: Bool {
        if case .completed = self { return true }
        if case .failed = self { return true }
        return false
    }

    /// True when the upload ended in failure. Lets a view pick the error
    /// styling without matching on `.failed` and ignoring its message.
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isRunning: Bool {
        switch self {
        case .validating, .readingFile, .uploading, .serverProcessing: return true
        default: return false
        }
    }

    /// 0...1 for the progress view.
    public var fraction: Double {
        switch self {
        case .idle: return 0
        case .validating, .readingFile: return 0.05
        case .uploading(let fraction): return 0.05 + (fraction * 0.7)
        case .serverProcessing: return 0.9
        case .completed: return 1
        case .failed: return 0
        }
    }

    /// Short, user-facing description. Lives here so the wording is unit-tested
    /// alongside the state machine and the app does not duplicate the strings.
    public var message: String {
        switch self {
        case .idle: return "Waiting to upload"
        case .validating: return "Checking the file…"
        case .readingFile: return "Reading the file…"
        case .uploading(let fraction):
            return "Uploading… \(Int(fraction * 100))%"
        case .serverProcessing: return "Finishing up on the server…"
        case .completed(let item): return "Added \(item.title)"
        case .failed(let message): return message
        }
    }
}

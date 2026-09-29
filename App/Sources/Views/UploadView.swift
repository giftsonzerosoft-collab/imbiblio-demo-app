import iBiblioCore
import SwiftUI
import UniformTypeIdentifiers

/// Picks a file and uploads it as `multipart/form-data`.
///
/// The whole flow below is `iBiblioCore` code exercised through a thin SwiftUI
/// shell: format detection, size validation, multipart encoding, progress
/// reporting and server-error mapping are all unit-tested on Windows.
struct UploadView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var isChoosingFile = false
    @State private var fileURL: URL?
    @State private var title = ""
    @State private var author = ""
    @State private var importError: String?
    @State private var scopedURL: URL?

    private var selectedFormat: BookFormat? {
        fileURL.flatMap { BookFormat.detect(fileName: $0.lastPathComponent) }
    }

    private var canUpload: Bool {
        fileURL != nil && selectedFormat != nil && environment.uploadState?.isRunning != true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Button {
                        isChoosingFile = true
                    } label: {
                        Label(
                            fileURL?.lastPathComponent ?? "Choose EPUB, PDF or audiobook",
                            systemImage: fileURL == nil ? "doc.badge.plus" : "doc.fill"
                        )
                    }
                    .accessibilityIdentifier("upload.chooseFile")

                    if let format = selectedFormat {
                        LabeledContent("Format", value: format.displayName)
                    } else if fileURL != nil {
                        Label("Unsupported file type", systemImage: "xmark.octagon.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("upload.unsupported")
                    }

                    if let size = fileSizeDescription {
                        LabeledContent("Size", value: size)
                    }
                }

                Section("Metadata") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("upload.title")
                    TextField("Author", text: $author)
                        .accessibilityIdentifier("upload.author")
                }

                if let state = environment.uploadState {
                    Section("Progress") {
                        UploadProgressView(state: state)
                    }
                }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("upload.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        Task { await performUpload() }
                    }
                    .disabled(!canUpload)
                    .accessibilityIdentifier("upload.confirm")
                }
            }
            .fileImporter(
                isPresented: $isChoosingFile,
                allowedContentTypes: allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // A picked file is security-scoped: the sandbox grant has to
                    // be claimed before it can be read, and held until the upload
                    // finishes. Releasing it here would make `Data(contentsOf:)`
                    // fail with a permissions error.
                    releaseScope()
                    if url.startAccessingSecurityScopedResource() {
                        scopedURL = url
                    }
                    fileURL = url
                    if title.isEmpty {
                        title = url.deletingPathExtension().lastPathComponent
                    }
                case .failure(let error):
                    environment.clearUploadState()
                    importError = SessionStore.describe(error)
                }
            }
            .alert(
                "Could not read the file",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .onChange(of: environment.uploadState) { _, state in
                guard let state, state.isTerminal else { return }
                releaseScope()
                if case .completed = state {
                    dismiss()
                }
            }
            .onDisappear { releaseScope() }
        }
    }

    /// Gives back the sandbox grant taken out in the importer callback.
    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    /// Built from each format's accepted *extensions* rather than its MIME type.
    ///
    /// `BookFormat.audiobook.defaultMIMEType` is `application/octet-stream`,
    /// which would let the user pick literally any file; the extension list is
    /// what Readium can actually open.
    private var allowedTypes: [UTType] {
        var types: Set<UTType> = []
        for format in BookFormat.allCases {
            for ext in format.acceptedExtensions {
                if let type = UTType(filenameExtension: ext) {
                    types.insert(type)
                }
            }
        }
        return Array(types)
    }

    private var fileSizeDescription: String? {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func performUpload() async {
        guard let fileURL else { return }
        _ = await environment.upload(
            fileURL: fileURL,
            title: title.isEmpty ? nil : title,
            author: author.isEmpty ? nil : author
        )
        // Success dismisses via the `onChange` handler above; failure leaves the
        // sheet open with `environment.uploadState` set to `.failed(message)`.
    }
}

// MARK: - Progress

private struct UploadProgressView: View {

    let state: UploadState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // `UploadState.message` already carries the failure text, so the
                // detail row below only shows what the headline does not.
                Text(state.message)
                    .font(.footnote)
                    .foregroundStyle(state.isFailure ? .red : .primary)
                Spacer()
                if case .completed = state {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if state.isFailure {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else {
                    Text("\(Int(state.fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("upload.status")

            if case .uploading(let fraction) = state {
                ProgressView(value: fraction)
            } else if case .completed(let item) = state {
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    UploadView()
        .environmentObject(AppEnvironment())
}

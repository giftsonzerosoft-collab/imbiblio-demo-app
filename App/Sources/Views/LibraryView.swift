import iBiblioCore
import SwiftUI

/// The library: remote catalog entries plus the publications bundled with the
/// app, with upload available from the toolbar.
struct LibraryView: View {

    @EnvironmentObject private var environment: AppEnvironment
    let user: SessionUser

    @State private var isPresentingUpload = false

    var body: some View {
        NavigationStack {
            List {
                if let message = environment.library.errorMessage {
                    Section {
                        Label(message, systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.offlineNotice")
                    }
                }

                Section {
                    if environment.library.entries.isEmpty && !environment.library.isLoading {
                        ContentUnavailableView(
                            "No publications",
                            systemImage: "books.vertical",
                            description: Text("Upload an EPUB, PDF or audiobook to get started.")
                        )
                    } else {
                        ForEach(environment.library.entries) { entry in
                            NavigationLink {
                                ReaderLoader(entry: entry)
                            } label: {
                                LibraryRow(entry: entry)
                            }
                            .accessibilityIdentifier("library.row.\(entry.id)")
                        }
                    }
                } header: {
                    Text("Publications")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text("Signed in as \(user.displayName)")
                        Button("Sign Out", role: .destructive) {
                            Task { await environment.signOut() }
                        }
                        .accessibilityIdentifier("library.signOut")
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingUpload = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("library.upload")
                }
            }
            .refreshable { await environment.library.reload(token: await environment.validToken()) }
            .task {
                await environment.library.reload(token: await environment.validToken())
            }
            .sheet(isPresented: $isPresentingUpload) {
                UploadView()
                    .environmentObject(environment)
            }
            .overlay {
                if environment.library.isLoading && environment.library.entries.isEmpty {
                    ProgressView()
                }
            }
        }
        .accessibilityIdentifier("library.screen")
    }
}

// MARK: - Row

private struct LibraryRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.format.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body)
                if let author = entry.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(entry.format.rawValue.uppercased())
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Loaders

/// Opens a library entry, then hands the publication to Readium.
///
/// One loader for both sources: the only difference is whether the bytes come
/// from the bundle or over the network, and `ReaderCoordinator` already handles
/// that. Duplicating this view per source is how the two copies drifted.
private struct ReaderLoader: View {

    @EnvironmentObject private var environment: AppEnvironment
    let entry: LibraryEntry

    var body: some View {
        Group {
            if let opened = environment.reader.opened, opened.id == entry.id {
                ReaderDestination(opened: opened)
            } else if let failure = environment.reader.failure, failure.id == entry.id {
                ReaderFailureView(message: failure.message) {
                    Task { await open() }
                }
            } else {
                ProgressView(entry.isFixture ? "Opening…" : "Downloading…")
                    .task { await open() }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func open() async {
        await environment.reader.open(
            entry,
            fixturesDirectory: environment.library.fixturesDirectory
        )
    }
}

/// Routes to the right renderer for the detected format.
struct ReaderDestination: View {

    let opened: ReaderCoordinator.Opened

    var body: some View {
        switch opened.format {
        case .audiobook:
            AudiobookReaderView(publication: opened.publication, title: opened.title)
        case .epub, .pdf:
            ReaderContainerView(publication: opened.publication, format: opened.format)
                .ignoresSafeArea()
        }
    }
}

struct ReaderFailureView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not open", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader.retry")
        }
    }
}

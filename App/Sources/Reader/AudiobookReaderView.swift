import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI

/// Playback UI for an audiobook.
///
/// `AudioNavigator` is a `Navigator`, not a `UIViewController`, so unlike EPUB
/// and PDF it cannot simply be handed to a `UIViewControllerRepresentable`.
/// Instead this view owns the navigator and listens to its delegate for state.
struct AudiobookReaderView: View {

    @StateObject private var model: AudiobookModel

    init(publication: Publication, title: String) {
        _model = StateObject(wrappedValue: AudiobookModel(publication: publication, title: title))
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("audiobook.artwork")

            VStack(spacing: 6) {
                Text(model.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let author = model.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("audiobook.title")

            if let duration = model.duration, duration > 0 {
                Slider(
                    value: $model.position,
                    in: 0...max(duration, 0.1),
                    onEditingChanged: { editing in
                        if !editing { model.seek(to: model.position) }
                    }
                )
                .accessibilityIdentifier("audiobook.scrubber")

                HStack {
                    Text(Self.format(model.position))
                    Spacer()
                    Text(Self.format(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            HStack(spacing: 32) {
                Button { model.skip(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .accessibilityIdentifier("audiobook.skipBack")
                .accessibilityLabel("Skip back 10 seconds")

                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                .accessibilityIdentifier("audiobook.playPause")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Button { model.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                }
                .accessibilityIdentifier("audiobook.skipForward")
                .accessibilityLabel("Skip forward 30 seconds")
            }
            .font(.title2)
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(32)
        .navigationTitle("Audiobook")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.start() }
        .onDisappear { model.pause() }
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Owns the `AudioNavigator` and republishes its playback state to SwiftUI.
@MainActor
final class AudiobookModel: NSObject, ObservableObject {

    let navigator: AudioNavigator
    let title: String
    let author: String?

    @Published var position: Double = 0
    @Published private(set) var duration: Double?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false

    init(publication: Publication, title: String) {
        self.navigator = AudioNavigator(publication: publication, initialLocation: nil)
        self.title = publication.metadata.title ?? title
        self.author = publication.metadata.authors.first?.name
        super.init()
        navigator.delegate = self
    }

    func start() {
        navigator.play()
    }

    func pause() {
        navigator.pause()
    }

    func togglePlayPause() {
        navigator.playPause()
    }

    func skip(by seconds: Double) {
        Task { await navigator.seek(by: seconds) }
    }

    func seek(to seconds: Double) {
        Task { await navigator.seek(to: seconds) }
    }
}

extension AudiobookModel: AudioNavigatorDelegate {

    func navigator(_ navigator: AudioNavigator, playbackDidChange info: MediaPlaybackInfo) {
        isLoading = (info.state == .loading)
        isPlaying = (info.state == .playing)
        if let infoDuration = info.duration, infoDuration > 0 {
            duration = infoDuration
        }
        if !info.time.isNaN, info.time >= 0 {
            position = info.time
        }
    }
}

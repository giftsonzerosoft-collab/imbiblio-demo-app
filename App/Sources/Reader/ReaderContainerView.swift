import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

/// Hosts the Readium navigator for an opened publication.
///
/// One representable, three shapes:
///   * EPUB     -> `EPUBNavigatorViewController` (WKWebView + Readium CSS)
///   * PDF      -> `PDFNavigatorViewController` (PDFKit via Readium)
///   * Audio    -> `AudioNavigator` is a `Navigator`, not a `UIViewController`,
///                 so it is driven by `AudiobookReaderView` instead.
///
/// Both view controllers are `MainActor`-bound and must be retained for as long
/// as they are on screen, which is what this struct's lifetime guarantees.
struct ReaderContainerView: UIViewControllerRepresentable {

    let publication: Publication
    let format: BookFormat

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let controller: UIViewController
            switch format {
            case .epub:
                controller = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: nil
                )
            case .pdf:
                controller = try PDFNavigatorViewController(
                    publication: publication,
                    initialLocation: nil
                )
            case .audiobook:
                // Not reachable: `LibraryView` routes audio to `AudiobookReaderView`.
                return UIViewController()
            }
            // Tag the rendered view so UI tests can wait on it. The navigators are
            // opaque to XCUITest otherwise.
            controller.loadViewIfNeeded()
            controller.view.accessibilityIdentifier = "reader.\(format.rawValue)View"
            return controller
        } catch {
            return ErrorViewController(error: error)
        }
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // The navigators own their own state; there is nothing to push down.
    }
}

/// A view controller that shows a failure inline instead of presenting an alert
/// from inside `makeUIViewController`, where there is no presenter yet.
private final class ErrorViewController: UIViewController {

    private let error: Error

    init(error: Error) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.text = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

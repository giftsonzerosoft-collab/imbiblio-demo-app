// swift-tools-version: 5.10
//
// iBiblioCore — the platform-agnostic core of the iBiblio demo app.
//
// CRITICAL ARCHITECTURAL RULE:
// This package must NOT depend on Readium (or anything else Apple-only), because
// it is built and unit-tested on Windows with the open-source Swift toolchain.
// Readium's swift-toolkit declares `platforms: [.iOS("15.0")]` and links UIKit,
// CoreServices, PDFKit, WebKit and AVFoundation, none of which exist on Windows.
// It cannot be resolved or compiled here, and adding it would break
// `swift build` / `swift test` on Windows for the *entire* package.
//
// Everything Readium-specific lives in App/Sources/Reader and is only compiled
// by the Xcode app target on macOS. See README.md, "Why two packages".
//
// The tools version is pinned to 5.10 (not 6.x) on purpose: 5.10 is understood
// by every Xcode from 15.4 upwards, and it matches the tools version used by
// Readium 3.11.0 itself. A 6.x tools version would refuse to even parse on a Mac
// running Xcode 16.4 (Swift 6.0).

import PackageDescription

let package = Package(
    name: "iBiblioCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "iBiblioCore", targets: ["iBiblioCore"])
    ],
    targets: [
        .target(
            name: "iBiblioCore",
            path: "Sources/iBiblioCore"
        ),
        .testTarget(
            name: "iBiblioCoreTests",
            dependencies: ["iBiblioCore"],
            path: "Tests/iBiblioCoreTests"
        )
    ]
)

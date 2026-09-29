# iBiblio — Readium + OIDC demo

A Swift demo that signs in with **OAuth 2.0 / OIDC (Authorization Code + PKCE)**
and reads **EPUB, PDF and audiobook** publications with
[Readium](https://github.com/readium/swift-toolkit).

It is deliberately split in two, because the two halves have opposite
constraints:

| | `iBiblioCore` | `App` |
|---|---|---|
| What | auth, networking, models, upload | SwiftUI screens, Readium readers |
| Dependencies | none (Foundation only) | `iBiblioCore` + Readium 3.11.0 |
| Runs on | Windows, Linux, macOS, iOS | iOS 17+ only |
| Tested by | `swift test` — 118 tests | XCTest + XCUITest on a simulator |

Readium links UIKit, PDFKit, WebKit and AVFoundation, so it **cannot** compile on
Windows. Keeping every byte of business logic in `iBiblioCore` means the
interesting code is developed and verified in VS Code, and the Mac is only
needed to open Xcode.

---

## Layout

```
Package.swift              # iBiblioCore — builds and tests on Windows
Sources/iBiblioCore/
  Auth/                    # OIDC, PKCE, SHA-256, Base64URL, token storage
  Networking/              # HTTPClient protocol, URLSession + stub clients
  Models/                  # AuthToken, BookItem, BookFormat
  Session/                 # SessionStore: restore / sign in / refresh / sign out
  Upload/                  # multipart/form-data encoder + UploadService
Tests/iBiblioCoreTests/    # 118 unit tests, no Readium, no network
App/
  project.yml              # XcodeGen manifest (the .xcodeproj is generated)
  Sources/Support/         # Info.plist, AppConfiguration, AppEnvironment
  Sources/Library/         # catalog + bundled fixtures
  Sources/Reader/          # the ONLY files that import Readium
  Sources/Views/           # SwiftUI screens
  Tests/                   # XCTest for the app's own pure logic
  UITests/                 # XCUITests
  Resources/Fixtures/      # generated sample.epub / .pdf / .wav
Scripts/
  swift.ps1                # loads the MSVC environment, then runs Swift
  normalize-line-endings.ps1
  generate_fixtures.py     # writes the sample publications (stdlib only)
```

---

## Running the core on Windows

```powershell
# Once per machine, if SwiftPM cannot find the Windows SDK.
.\Scripts\swift.ps1 build
.\Scripts\swift.ps1 test
```

`Scripts/swift.ps1` exists because the Windows toolchain needs the Visual Studio
build environment loaded before `swift build` can find `stdlib.h`. Without it you
get `error: 'stdlib.h' file not found`.

On macOS or Linux the wrapper is unnecessary:

```bash
swift test
```

## Running the app on macOS

```bash
brew install xcodegen          # once
python3 Scripts/generate_fixtures.py
cd App && xcodegen generate && open iBiblioDemo.xcodeproj
```

Then pick the `iBiblioDemo` scheme and a simulator. There is nothing to
configure: with no issuer supplied the app starts in **demo mode**, where
`MockAuthProvider` signs you in without a network round-trip.

### Running the app for real

```bash
# In App/, after `xcodegen generate`, edit the iBiblioDemo scheme's Run
# arguments, or launch with:
xcrun simctl launch booted com.example.ibiblio.demo \
  -authMode oidc \
  -oidcIssuer https://your-issuer.example.com \
  -oidcClientID ibiblio-demo \
  -oidcRedirectURI ibiblio://oauth/callback
```

The redirect URI must match the `CFBundleURLSchemes` entry in
`App/Sources/Support/Info.plist` (`ibiblio`). Any of the launch arguments can also
be supplied as environment variables (`OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`BACKEND_BASE_URL`, `CATALOG_URL`).

| Argument | Values |
|---|---|
| `-authMode` | `oidc`, `mock`, `mockFailing` |
| `-oidcIssuer` | issuer URL; OIDC endpoints are derived as `<issuer>/authorize` and `<issuer>/token` |
| `-oidcClientID` | public client id |
| `-oidcRedirectURI` | must be registered with the provider |
| `-backendBaseURL` | base URL for `POST <base>/upload` |
| `-catalogURL` | `GET` endpoint returning `{"books":[…]}` or a bare array |

`mockFailing` makes sign-in throw, which is how the UI tests cover the error
state.

---

## What the demo shows

**Sign-in.** `OIDCAuthProvider` builds the authorization URL, generates a
43-character PKCE verifier (`S256`), and validates `state` on the callback
before exchanging the code. The verifier is a base64url string; the challenge
is `BASE64URL(SHA256(verifier))`. SHA-256 and Base64URL are implemented from
scratch so the core has no dependencies, and both are pinned to RFC test vectors
in `SHA256Tests`.

**Token storage.** `KeychainTokenStore` on device, `FileTokenStore` and
`InMemoryTokenStore` for tests. `SessionStore` is an actor, so two concurrent
requests cannot both trigger a refresh. It refreshes proactively on launch only
when the token is *hard* expired, and otherwise on first use, so cold start does
no network work for a token that still has minutes left.

**Upload.** `MultipartFormData` encodes `title`, `author`, `format` and the file
as `multipart/form-data`, and `estimatedEncodedLength()` reports the byte count
without building the payload. Validation (extension, size, readability) happens
before any bytes are read.

**Reading.** `ReaderCoordinator` performs Readium's three steps — `AssetRetriever`
fetches the bytes, `PublicationOpener` parses them — then
`ReaderContainerView` picks a renderer:

* EPUB → `EPUBNavigatorViewController` (WKWebView + Readium CSS)
* PDF → `PDFNavigatorViewController` (PDFKit)
* audiobook → `AudioNavigator`, which is a `Navigator` and *not* a
  `UIViewController`, so it is driven by a SwiftUI view instead

Fixtures are generated by `Scripts/generate_fixtures.py` using only the Python
standard library: a real OCF-compliant EPUB, a two-page PDF 1.4 file, and a 16-bit
PCM WAV. The EPUB's `mimetype` entry is written first and stored uncompressed, as
the spec requires.

---

## Continuous integration

* `.github/workflows/core.yml` — `swift build` + `swift test` on Windows, Ubuntu
  and macOS. Windows uses the MSVC wrapper.
* `.github/workflows/ios.yml` — generates the Xcode project, resolves Readium,
  builds and runs the XCTest + XCUITests on an iOS simulator. macOS runners are
  free on public repositories, so the Readium half is verified before you have a
  Mac.

---

## Notes and limitations

* The app's deployment target is **iOS 17.0**, not the 15.0 that Readium itself
  declares. The UI uses `ContentUnavailableView`, the `.topBarLeading`/
  `.topBarTrailing` toolbar placements and two-argument `onChange(of:)`, all of
  which are iOS 17 APIs. Declaring the real floor beats scattering
  `if #available` through every view.
* Readium 3.11.0 is pinned with `exactVersion`. Its `HTTPClient` protocol is
  streaming-only, so the app uses Readium's own `DefaultHTTPClient` for reading
  and `iBiblioCore.URLSessionHTTPClient` for backend calls; the two are never
  mixed.
* `AppConfiguration` derives `/authorize` and `/token` from the issuer.
  Providers that use different paths (Keycloak, Auth0 tenants) need
  `OIDCConfiguration`'s explicit endpoints instead.
* The ID token is decoded **without verifying its signature** — fine for showing
  a display name, not for authorization decisions. A production app must validate
  it against the issuer's JWKS.
* No DRM. `ReadiumLCP` is not linked.
* `ReaderCoordinator` decides what a file is from the **publication profile**
  (`Publication.Profile.epub` / `.pdf` / `.audiobook`), not from the asset's
  media type. A bare `.wav` sniffs as `FormatSpecification.wav`; only after
  parsing does it conform to `Profile.audiobook`. There is no
  `FormatSpecification.audiobook` to compare against — that distinction is the
  single easiest Readium API to get wrong.

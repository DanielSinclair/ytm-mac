# Contributing to ytm-mac

Issues and pull requests are welcome. ytm-mac aims to stay small: it should keep behaving like a native Mac app while adding as little UI and code as possible. Before adding a feature, check whether the web player or macOS already provides it.

## Build from source

Requirements: macOS 14+, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen                      # generates ytm-mac.xcodeproj (gitignored)
open ytm-mac.xcodeproj        # run the ytm-mac scheme
```

A command-line build that needs no signing:

```sh
xcodebuild -project ytm-mac.xcodeproj -scheme ytm-mac \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Project layout

| Path | Purpose |
|---|---|
| `Sources/App/main.swift` | App delegate, window, WKWebView setup, menus and keyboard shortcuts |
| `Sources/App/CookieImport.swift` | Finds browser profiles and imports their login with SweetCookieKit |
| `Sources/App/Onboarding.swift` | SwiftUI sheet for choosing a browser on first launch |
| `Sources/App/NowPlaying.swift` | Now Playing and media-key bridge (MediaPlayer framework) |
| `Sources/App/inject.js` | Script injected into the page: playback bridge, player commands, layout CSS, window dragging |
| `Support/Info.plist` | Bundle metadata |
| `project.yml` | XcodeGen spec (the target, the scheme, and the SweetCookieKit package) |
| `fastlane/Fastfile` | Release automation |

### How the pieces talk

- **Page to app**: `inject.js` posts messages through two `WKScriptMessageHandler`s.
  - `ytm` carries playback state (title, artist, artwork, position, playing) and feeds `NowPlaying`.
  - `ytmWindow` carries window gestures (`drag`, `zoom`).
- **App to page**: native commands call `window.__ytm.<command>()` (`play`, `pause`, `toggle`, `next`, `previous`, `seek`, `volume`, `settings`) with `evaluateJavaScript`.
- **When the page changes its markup**: page selectors live only in `inject.js`, so that is the file to update.

## Releases

Releases are built locally; CI doesn't need any secrets.

### One-time setup

- **Xcode**: sign in to Xcode with an Apple ID on the team that owns the Developer ID certificate. The certificate is managed by Apple in the cloud, so there's no `.p12` file to export.
- **Notarization**: [`asc`](https://github.com/rorkai/App-Store-Connect-CLI) needs an App Store Connect API key (`asc auth login …`).
- **GitHub**: `gh auth login`.
- **Homebrew tap**: `brew tap danielsinclair/tap`.
- **Ruby gems**: `bundle install`.

### Cut a release

```sh
xcodegen
bundle exec fastlane release version:X.Y.Z
```

The `release` lane:

1. Builds two archives with `gym` and exports them as Developer ID: `arm64` and `universal`.
2. Notarizes each with `asc notarization submit --wait`, then staples it. The `arm64` build goes first: both builds contain the same Apple silicon code, and the build notarized last is the one that has passed Gatekeeper.
3. Checks both with `spctl` and stops if Gatekeeper rejects either one.
4. Zips them as `dist/ytm-mac-X.Y.Z-{arm64,universal}.zip`.
5. Publishes a GitHub release with `set_github_release`, using the token from `gh auth token`.
6. Updates `danielsinclair/tap` with `brew bump-cask-pr --write-only --commit` and pushes it.

A version containing a `-` (for example `0.2.0-rc1`) is published as a prerelease and skips the tap. Use `bundle exec fastlane package version:X.Y.Z` to build and notarize without publishing anything.

## Code style

- **Swift**: plain AppKit plus SwiftUI for the onboarding sheet. No third-party dependencies beyond SweetCookieKit.
- **JavaScript**: one self-contained script, with no build step.
- **Comments**: explain *why* something is done, not *what* it does.

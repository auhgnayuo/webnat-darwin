# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-05-12

### Changed

- Raised minimum platforms to **iOS 13.0** and **macOS 10.15** (Swift Package, CocoaPods podspec, and docs) to match Swift concurrency usage and WebKit initialization behavior.
- `Webnat.initialize` now gates `WKWebpagePreferences.allowsContentJavaScript` with `#available(iOS 14.0, macOS 11.0, *)` and falls back to `javaScriptEnabled` on iOS 13 / macOS 10.15.
- `Message.from(dict:)` now treats `NSNull` as an explicit JSON null placeholder (kept inside arrays / dictionaries), and **skips** unrecognized elements inside collections instead of failing the whole container. Previously an unknown or null element would cause the entire surrounding `param` to be dropped.
- `ScriptMessageHandler` is now annotated `@MainActor` to match WebKit's documented main-thread delivery for `WKScriptMessageHandler` callbacks and to satisfy Swift 6 strict-concurrency checks.

### Fixed

- Avoids calling `allowsContentJavaScript` on macOS versions before **11.0** where the property is unavailable (while still supporting **macOS 10.15** via `javaScriptEnabled`).
- `BroadcastWebnat.listen(name:)` now uses an internal handle that finishes the stream and gates further `yield`s once `onTermination` fires, preventing late post-cancellation deliveries from a stale `Continuation` and cleaning empty listener slots.

### Added

- Substantially expanded unit tests (now ~70 cases) covering `Error` helpers, `Webnat.of` / `initialize` idempotence, full `MethodWebnat` lifecycle (replace, off, web abort, connection close during pending RPC, send-error forwarding, post-completion notify, async success / throw / cancel / nil-connection), `Connection` send forwarding, `RawWebnat` dedupe + non-raw filtering, `BroadcastWebnat` fan-out + filtering, `JavaScriptAliveKeeper` start / stop / delay, and Message decode edge cases (NSNull placeholder, skip unknowns, missing required subfields).

## [1.0.3] - 2026-05-09

### Added

- Added unit tests for message serialization and RPC lifecycle paths (`timeout`, `cancel`, `notify`, `unimplemented`, nil-connection failure).
- Added maintainer docs (`CONTRIBUTING.md`) and release notes tracking in this changelog.

### Changed

- Renamed repository references from `webnat-os` to `webnat-darwin` across package metadata and docs.
- Updated README / README_CN examples and install snippets to `1.0.3`.
- Normalized comments and API docs to match current behavior (`WKScriptMessage.body` dictionary-only handling, lifecycle ownership in `Webnat`).

### Fixed

- Aligned async `method` connection resolution with callback API (`connection ?? connections.values.first`).
- Prevented unnecessary timeout scheduling for non-finite / non-positive timeouts in callback RPC path.
- Broadcast-to-all now iterates a snapshot (`Array(connections.values)`) to reduce re-entrancy mutation risks.
- Improved JSON decoding bridge in `Message.from(dict:)` for Swift 6 strict-concurrency compatibility.

## [1.0.2] - 2026-03-06

### Added

- `url` property on `Connection`.

### Changed

- Release metadata and version bump to 1.0.2.

## [1.0.0] - 2026-02-28

### Added

- Initial public release: Webnat bridge for `WKWebView` (raw, broadcast, and method/RPC-style messaging, iframe forwarding, timeouts and cancellation).

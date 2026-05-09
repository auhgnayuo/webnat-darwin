# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

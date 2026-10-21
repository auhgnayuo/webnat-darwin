# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] - 2026-10-21

This is a coordinated **major / breaking release** across Web, Electron, Darwin, Android and OHOS. Upgrade both sides of the bridge together; migration and manual publishing instructions are in `RELEASING.md`. Contract fixtures v1 are frozen for this release.

### Shared contract / regression gates

- Added versioned golden message, rejection and error fixtures shared by all five implementations, digest verification and a cross-repository drift/interop gate.
- Unified error aliases, code 0, signed 32-bit / whole-string parsing and empty/null message behavior. Web errors now inherit Error.
- PR test workflows now execute tests rather than build-only checks. OHOS SDK execution requires an approved isolated self-hosted runner; device tests remain distinct from local tests.

- Native-to-Web scripts now parse quoted JSON text before receive instead of evaluating JSON as JavaScript object literals. This preserves __proto__ data fields and keeps the strict Web decoder compatible.

### Changed (Breaking)

- Business payloads now decode to native Swift nullable dictionaries / arrays (`[String: Sendable?]` / `[Sendable?]`); JSON null and missing fields become nil, with nested keys and positions preserved. NSNull no longer reaches business callbacks.
- `Message.toDictionary()` now throws for invalid JSON business values. Date, Data, Set, custom objects, direct NSNull / Foundation containers, non-string keys and non-finite numbers are rejected. Decoder failures reject the whole message instead of skipping unknown elements.
- `Connection.attributes` is now `[String: Sendable?]?` and contains JSON data only. Native WebKit metadata moved from `attributes["frameInfo"]` to `Connection.frameInfo`.

### Fixed

- A reply with `error: null` is now successful instead of losing its result and producing an unknown error.
- Normalize automatic Objective-C block bridging of method results / notifications before encoding without silently coercing invalid objects.

### Refactored

- Moved recursive JSON encoding / decoding into standalone `toJsonValue` / `fromJsonValue` helpers, retaining integer precision and numeric / Boolean distinction.

### Tests

- Added shared-contract regression coverage for every message payload, nullable containers, illegal values, cycles, business callbacks, metadata and RPC error handling. Updated old NSNull / skip-policy expectations.

### Fixed

- Preserve JSON numeric `0`/`1` as numbers instead of decoding them as booleans. Distinguish CFBoolean before numeric NSNumber bridging, retain integral precision, and cover nested JSONSerialization round trips.

## [1.4.0] - 2026-10-13

### Added

- **`webViewWebContentProcessDidTerminate()`**: tells Webnat that the web content process behind the web view has exited (crash, or the web view is about to be released); Webnat then ends the page's connections itself. Same semantics on Android, Darwin, OHOS and Electron. The method is named after each platform's own hook: `webViewWebContentProcessDidTerminate` on Darwin, `onRenderProcessGone` on Android and Electron, `onRenderExited` on OHOS. The host calls it from its own `webViewWebContentProcessDidTerminate(_:)` and before it releases the web view.

### Fixed

- A message that cannot be serialized no longer crashes the app: `JSONSerialization` raises an Objective-C exception for non-JSON values (`Date`, `NaN`, custom types) that Swift `do/catch` cannot catch. Webnat now validates first and fails the send with `serializationFailed`, so `method` fails at once.
- A method result that cannot be serialized is answered with a `serializationFailed` error reply instead of being dropped.
- A method handler that completes synchronously no longer leaves its cancel / close hooks registered forever.

## [1.2.0] - 2026-07-02

### Added

- **`Webnat.method` broadcast**: when called without an explicit `connection`, the method call is now **broadcast to all connections** (main frame + every iframe) instead of an arbitrary first connection. The first connection to send a *meaningful* signal — a `notify`, a successful `reply`, or a real business error — wins; the remaining sub-calls are immediately `abort`ed and only the winner's notifications / final result are forwarded.
- **Elimination semantics for broadcast**: `unimplemented` (`-1010`) and `closed` (`-1004`) replies never win the race; they only remove that connection from the candidate pool. If *all* connections are eliminated, the call fails with `closed` (when any connection closed) otherwise `unimplemented`. Timeout / cancellation apply at the group level and abort all in-flight sub-calls (sub-calls carry no individual timeout). This is designed for the common "pass-through to iframe" case where only one frame registers a given handler.

### Note

- Passing an explicit `connection` keeps the previous single-connection behavior unchanged.

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

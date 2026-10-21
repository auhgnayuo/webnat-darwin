# Webnat

[![Swift](https://img.shields.io/badge/Swift-5.7-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2013%2B%20%7C%20macOS%2010.15%2B-lightgrey.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager)
[![CocoaPods](https://img.shields.io/badge/CocoaPods-Git%20podspec-ff69b4.svg)](https://guides.cocoapods.org/syntax/podfile.html#pod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/auhgnayuo/webnat-darwin?label=release)](https://github.com/auhgnayuo/webnat-darwin/releases)

[中文文档](./README_CN.md)

A lightweight WebView–Native bridge for iOS and macOS, built on WebKit’s `WKWebView` and `WKScriptMessageHandler`.

**You need a Web implementation:** use [webnat-web](https://github.com/auhgnayuo/webnat-web) (or a compatible client) in the page loaded by the web view. This repo is the Native side only.

## Requirements

| | Version |
|--|--|
| Swift | 5.7+ |
| iOS | 13.0+ |
| macOS | 10.15+ |
| Xcode | 14+ recommended (Swift 6–friendly toolchains) |

**Threading:** `Webnat` and related APIs are main-thread oriented (`@MainActor`). Call `initialize`, `of`, listeners, and sends from the main thread unless your app’s architecture already guarantees the same execution context as the web view.

**Concurrency:** `async`/`await` method calls, `AsyncStream` broadcast listening, and related APIs use Swift concurrency, which this package targets at **iOS 13+** and **macOS 10.15+** (build with a Swift 5.7+ toolchain; Xcode applies the usual runtime back-deployment for these OS versions).

## Features

- **Multi-platform** — iOS 13+ and macOS 10.15+
- **iframe support** — message forwarding between the main frame and iframes
- **Three modes** — raw messages, broadcast, and RPC-style methods
- **Timeout and cancellation** — built-in timeout and cooperative cancel
- **Concurrency** — ready for Swift 6 language mode in dependent projects

## Example app

Open [`Example/Example.xcodeproj`](Example/Example.xcodeproj) in Xcode. Run the **Example** target and load a page that uses **webnat-web** so connections and messages have a peer to talk to.

## Installation

Pin versions to a [Git tag](https://github.com/auhgnayuo/webnat-darwin/releases) that exists on this repo. Release tags should match `Sources/Webnat/Version.swift` and `Webnat.podspec`.

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/auhgnayuo/webnat-darwin.git", from: "2.0.0")
]
```

In Xcode: **File → Add Package Dependencies…** → enter `https://github.com/auhgnayuo/webnat-darwin.git` → add the **Webnat** product.

### CocoaPods

From [CocoaPods trunk](https://cocoapods.org/pods/Webnat) (after the maintainer has pushed that version):

```ruby
pod 'Webnat', '2.0.0'
```

Or track this repository directly:

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :tag => 'v2.0.0'
```

Track a branch:

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :branch => 'main'
```

Then `pod install`. For `:tag`, use `v` followed by `s.version` for the tag in `Webnat.podspec`. Maintainer checklist (lint, tagging): [CONTRIBUTING.md](./CONTRIBUTING.md).

## Related projects

| Platform | Repository |
|----------|------------|
| Web (JavaScript/TypeScript) | [webnat-web](https://github.com/auhgnayuo/webnat-web) |
| Android (Kotlin) | [webnat-android](https://github.com/auhgnayuo/webnat-android) |
| HarmonyOS (ArkTS) | [webnat-ohos](https://github.com/auhgnayuo/webnat-ohos) |

## 2.0.0 Data Contract and Migration

Payloads, method results, and notifications accept only JSON-compatible values: strings, booleans,
finite numbers, string-keyed dictionaries, arrays, and nulls, recursively. `Sendable?` is a carrier,
not a promise that any Sendable / Codable object can be encoded.

Use `[String: Sendable?]` / `[Sendable?]` for nullable dictionary values / array elements.
Incoming JSON null and missing payload fields both become native nil, never NSNull.
Null dictionary keys and array positions are preserved, as are empty string keys.
Top-level nil payloads / results still omit their fields; nested nil encodes as JSON null.

Date, Data, Set, custom objects, and directly supplied NSNull / Foundation containers are rejected.
Convert custom objects to dictionaries / arrays explicitly. Foundation / Objective-C block bridging
is handled internally; invalid values are rejected, not stringified or silently dropped.

`Message.toDictionary()` now throws: use `try`. Invalid decoded payloads cause `Message.from(dict:)`
to reject the entire message. `Connection.attributes` is now `[String: Sendable?]?` and contains only
JSON business data. Move access to `attributes["frameInfo"]` to the separate `connection.frameInfo` property.

```swift
let param: [String: Sendable?] = [
    "nickname": nil,
    "items": [1, nil, 3] as [Sendable?]
]
webnat.raw(param, connection: connection)
let dictionary = try Message.raw(to: connection.id, param: param).toDictionary()
```

## Usage

### 1. Initialization

```swift
import Webnat
import WebKit

let configuration = WKWebViewConfiguration()
Webnat.initialize(webViewConfiguration: configuration)
let webView = WKWebView(frame: .zero, configuration: configuration)
let webnat = Webnat.of(webView)
```

### 2. Wait for a Web-side connection

Connections are started from **JavaScript**. Native code reads `webnat.connections`.

```swift
let connections = webnat.connections
print("Active connections: \(connections.count)")

if let connection = connections["connection-id"] {
    print("Connection found:", connection.id)
    print("Attributes:", connection.attributes ?? [:])
}
```

### 3. Send and receive messages

```swift
// Raw
webnat.raw("Hello from Native!", connection: connection)

let rawListener: RawBlockListener = { raw, connection in
    print("From \(connection.id):", raw)
}
webnat.onRaw(listener: rawListener)

// Broadcast
webnat.broadcast(name: "userLoggedIn", param: ["userId": 123], connection: connection)

let broadcastListener: BroadcastBlockListener = { param, connection in
    print("Broadcast from \(connection.id):", param ?? "nil")
}
webnat.onBroadcast(name: "userLoggedIn", listener: broadcastListener)

// Stream broadcasts (Swift concurrency)
if #available(iOS 13.0, macOS 10.15, *) {
    Task {
        for await (param, connection) in webnat.listenBroadcast(name: "userLoggedIn") {
            print("Broadcast from \(connection.id):", param ?? "nil")
        }
    }
}

// Call a Web-side method (callback; works on all supported platforms)
webnat.method(
    "getUserInfo",
    param: ["userId": 123],
    timeout: 5.0,
    connection: connection
) { result, error in
    if let error = error {
        print("Error:", error)
    } else {
        print("User info:", result ?? "nil")
    }
}

// Same call with async/await (Swift concurrency)
if #available(iOS 13.0, macOS 10.15, *) {
    Task {
        do {
            let result = try await webnat.method(
                "getUserInfo",
                param: ["userId": 123],
                timeout: 5.0,
                connection: connection
            )
            print("User info:", result ?? "nil")
        } catch {
            print("Error:", error)
        }
    }
}

// Register a method for the Web to invoke
let methodListener: MethodBlockListener = { param, callback, notify, connection in
    let userId = param?["userId"] as? Int ?? 0

    notify(["progress": 50])

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        callback(["userId": userId, "name": "User"], nil)
    }

    return {
        // Cancellation logic
    }
}
webnat.onMethod(name: "getUserInfo", listener: methodListener)
```

### 4. Send failures and handler errors

- A failed send is visible to the caller that waits for it: `method` fails at once with `serializationFailed` when the parameter cannot be serialized (a `Date`, `NaN` or a custom type is no longer a crash), and with `closed` when the web view is gone or the connection is closed. An error reported by `evaluateJavaScript` fails the call with that error. `raw` and `broadcast` stay fire-and-forget.
- A method handler reports failure through `callback(nil, error)` (a Swift closure cannot throw). A result that cannot be serialized is answered with `serializationFailed`, so the caller never waits for its timeout because of it.

### 5. Page crash and teardown

When a page unloads normally, the Web SDK sends CLOSE and Webnat ends that connection. A crashed web content process or a released web view never gets to send it, so forward the event to Webnat: call `webnat.webViewWebContentProcessDidTerminate()` from your `webViewWebContentProcessDidTerminate(_:)`, and once more before you release the web view. Webnat then ends the page's connections itself: pending `method` calls fail with `closed` and running method handlers are cancelled. Nothing is sent to the page, and Webnat stays usable, so a reloaded page opens new connections as usual.

```swift
func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    Webnat.of(webView).webViewWebContentProcessDidTerminate()
}
```

## Privacy

The package ships [`Sources/Webnat/PrivacyInfo.xcprivacy`](Sources/Webnat/PrivacyInfo.xcprivacy) as a resource. When you integrate via SPM or CocoaPods, include it in the app bundle as required by Apple’s privacy manifest rules.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](LICENSE)

## Shared regression contracts

See `contracts/README.md` for versioned golden fixtures and `contracts/CI.md` for test gates and runner setup.

## Release

Manual release instructions and migration notes: `RELEASING.md`. Upgrade the Web SDK and native bridge together to 2.0.0.

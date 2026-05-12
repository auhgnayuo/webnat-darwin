# Webnat

[![Swift](https://img.shields.io/badge/Swift-5.5-orange.svg)](https://swift.org)
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
| Swift | 5.5+ |
| iOS | 13.0+ |
| macOS | 10.15+ |
| Xcode | 14+ recommended (Swift 6–friendly toolchains) |

**Threading:** `Webnat` and related APIs are main-thread oriented (`@MainActor`). Call `initialize`, `of`, listeners, and sends from the main thread unless your app’s architecture already guarantees the same execution context as the web view.

**Concurrency:** `async`/`await` method calls, `AsyncStream` broadcast listening, and related APIs use Swift concurrency, which this package targets at **iOS 13+** and **macOS 10.15+** (build with a Swift 5.5+ toolchain; Xcode applies the usual runtime back-deployment for these OS versions).

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
    .package(url: "https://github.com/auhgnayuo/webnat-darwin.git", from: "1.1.0")
]
```

In Xcode: **File → Add Package Dependencies…** → enter `https://github.com/auhgnayuo/webnat-darwin.git` → add the **Webnat** product.

### CocoaPods

From [CocoaPods trunk](https://cocoapods.org/pods/Webnat) (after the maintainer has pushed that version):

```ruby
pod 'Webnat', '1.1.0'
```

Or track this repository directly:

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :tag => '1.1.0'
```

Track a branch:

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :branch => 'main'
```

Then `pod install`. For `:tag`, keep the tag aligned with `s.version` in `Webnat.podspec`. Maintainer checklist (lint, tagging): [CONTRIBUTING.md](./CONTRIBUTING.md).

## Related projects

| Platform | Repository |
|----------|------------|
| Web (JavaScript/TypeScript) | [webnat-web](https://github.com/auhgnayuo/webnat-web) |
| Android (Kotlin) | [webnat-android](https://github.com/auhgnayuo/webnat-android) |
| HarmonyOS (ArkTS) | [webnat-ohos](https://github.com/auhgnayuo/webnat-ohos) |

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

## Privacy

The package ships [`Sources/Webnat/PrivacyInfo.xcprivacy`](Sources/Webnat/PrivacyInfo.xcprivacy) as a resource. When you integrate via SPM or CocoaPods, include it in the app bundle as required by Apple’s privacy manifest rules.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

[MIT](LICENSE)

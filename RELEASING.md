# Darwin 2.0.1 release

Git tag: **v2.0.1**. Sources/Webnat/Version.swift and Webnat.podspec declare 2.0.1. The podspec source
uses `v#{s.version}`; do not use the historical bare `2.0.0` tag. SwiftPM requires no registry publication.
Swift compiler / package tools minimum is 5.7; Swift 5 and Swift 6 language modes remain supported.
Minimum OS versions remain iOS 13 and macOS 10.15.

## Verification

```bash
./scripts/test.sh
pod lib lint Webnat.podspec --allow-warnings
# After v2.0.1 is pushed (fetches the actual tag rather than the local tree):
pod spec lint Webnat.podspec --allow-warnings
```

## Swift Package Manager / Git-based CocoaPods

Pushing the release commit and v2.0.1 tag already makes the version available; no extra publish command.

```swift
.package(url: "https://github.com/auhgnayuo/webnat-darwin.git", from: "2.0.1")
```

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :tag => 'v2.0.1'
```

## Optional CocoaPods trunk distribution

If your account owns/maintains the Webnat pod and trunk accepts new versions, run:

```bash
pod trunk me
pod spec lint Webnat.podspec --allow-warnings
pod trunk push Webnat.podspec --allow-warnings
```

Trunk authentication and owner permission are required. Git-based distribution remains usable without
trunk. After a successful trunk publication users can write `pod 'Webnat', '2.0.1'`.

Migration: Message.toDictionary() now throws; use `try`. Nullable payload containers are
[String: Sendable?] / [Sendable?]. Connection.frameInfo replaces attributes["frameInfo"].

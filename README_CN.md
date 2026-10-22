# Webnat

[![Swift](https://img.shields.io/badge/Swift-5.7-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2013%2B%20%7C%20macOS%2010.15%2B-lightgrey.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager)
[![CocoaPods](https://img.shields.io/badge/CocoaPods-Git%20podspec-ff69b4.svg)](https://guides.cocoapods.org/syntax/podfile.html#pod)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Release](https://img.shields.io/github/v/release/auhgnayuo/webnat-darwin?label=release)](https://github.com/auhgnayuo/webnat-darwin/releases)

[English](./README.md)

Webnat 是用于 iOS / macOS 上 `WKWebView` 与 Native 通信的 Swift 库，基于 `WKScriptMessageHandler`。

**需要 Web 端实现：**页面中请使用 [webnat-web](https://github.com/auhgnayuo/webnat-web)（或兼容协议的前端）。本仓库只提供 Native 侧能力。

## 环境要求

| | 版本 |
|--|--|
| Swift | 5.7+ |
| iOS | 13.0+ |
| macOS | 10.15+ |
| Xcode | 建议 14+（便于 Swift 6 工具链） |

**线程：** `Webnat` 及相关 API 以主线程为主（`@MainActor`）。请在主线程调用 `initialize`、`of`、监听与发送，或与 WebView 生命周期一致的队列上调用。

**并发：** `async`/`await`、`AsyncStream` 等基于 Swift 并发；本包最低系统为 **iOS 13+**、**macOS 10.15+**（使用 Swift 5.7+ 工具链编译；Xcode 会对上述系统做并发运行时回退）。不需要 async 时仍可使用带 `callback` 的 `method` 重载。

## 特性

- **多平台** — iOS 13+、macOS 10.15+
- **iframe** — 主框架与 iframe 间消息转发
- **三种模式** — 原始消息、广播、类 RPC 方法调用
- **超时与取消** — 内置超时与协作式取消
- **并发** — 适配宿主工程中的 Swift 6 语言模式

## 示例工程

用 Xcode 打开 [`Example/Example.xcodeproj`](Example/Example.xcodeproj)，运行 **Example** 目标。请加载已集成 **webnat-web** 的页面，否则没有对端建立连接。

## 安装

版本请绑定本仓库上存在的 [Git tag](https://github.com/auhgnayuo/webnat-darwin/releases)。发版时 tag 应与 `Sources/Webnat/Version.swift`、`Webnat.podspec` 中的版本一致。

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/auhgnayuo/webnat-darwin.git", from: "2.0.1")
]
```

在 Xcode 中：**File → Add Package Dependencies…** → 填入 `https://github.com/auhgnayuo/webnat-darwin.git` → 添加 **Webnat** 产品。

### CocoaPods

[CocoaPods 公有源（Trunk）](https://cocoapods.org/pods/Webnat)（在维护者已推送该版本之后）：

```ruby
pod 'Webnat', '2.0.1'
```

或直接引用本仓库：

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :tag => 'v2.0.1'
```

跟分支：

```ruby
pod 'Webnat', :git => 'https://github.com/auhgnayuo/webnat-darwin.git', :branch => 'main'
```

然后执行 `pod install`。使用 `:tag` 时请使用 `v` 加上 `Webnat.podspec` 的 `s.version`。维护者发版与校验见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 相关项目

| 平台 | 仓库 |
|------|------|
| Web (JavaScript/TypeScript) | [webnat-web](https://github.com/auhgnayuo/webnat-web) |
| Android (Kotlin) | [webnat-android](https://github.com/auhgnayuo/webnat-android) |
| HarmonyOS (ArkTS) | [webnat-ohos](https://github.com/auhgnayuo/webnat-ohos) |

## 2.0.1 数据约定与迁移

2.0.1 开始区分字段缺失与显式 JSON null。已发布的 2.0.0 合同 v1 保持不变。

参数、方法结果和通知接受 JSON 兼容的字符串、布尔值、有限数字、字符串键字典、数组和显式空值。
Swift 中 `nil` 表示顶层字段缺失，`NSNull()` 表示显式 JSON null。字典中的 nil 值会省略；数组中的 nil
位置会编码为 JSON null，不改变数组长度。显式 `NSNull` 在各层级均保留。

`Date`、`Data`、`Set`、自定义对象、非字符串字典键、非有限数字、循环引用及除 `NSNull` 外的 Foundation
容器仍然非法。请使用 `NSNull()` 表示 JSON null，并用普通 Swift 字典 / 数组承载数据。缺失的 RPC 结果仍为 nil；
显式 JSON null 结果为 `NSNull()`。

`Message.toDictionary()` 对非法业务数据抛错；非法接收数据会拒绝整条消息。

## 基本使用

### 1. 初始化

```swift
import Webnat
import WebKit

let configuration = WKWebViewConfiguration()
Webnat.initialize(webViewConfiguration: configuration)
let webView = WKWebView(frame: .zero, configuration: configuration)
let webnat = Webnat.of(webView)
```

### 2. 等待 Web 端建立连接

连接由 **JavaScript 主动发起**，Native 通过 `webnat.connections` 访问。

```swift
let connections = webnat.connections
print("当前有 \(connections.count) 个连接")

if let connection = connections["connection-id"] {
    print("找到连接:", connection.id)
    print("连接属性:", connection.attributes ?? [:])
}
```

### 3. 发送和接收消息

```swift
// 原始消息
webnat.raw("Hello from Native!", connection: connection)

let rawListener: RawBlockListener = { raw, connection in
    print("From \(connection.id):", raw)
}
webnat.onRaw(listener: rawListener)

// 广播
webnat.broadcast(name: "userLoggedIn", param: ["userId": 123], connection: connection)

let broadcastListener: BroadcastBlockListener = { param, connection in
    print("Broadcast from \(connection.id):", param ?? "nil")
}
webnat.onBroadcast(name: "userLoggedIn", listener: broadcastListener)

// 流式监听广播（Swift 并发）
if #available(iOS 13.0, macOS 10.15, *) {
    Task {
        for await (param, connection) in webnat.listenBroadcast(name: "userLoggedIn") {
            print("Broadcast from \(connection.id):", param ?? "nil")
        }
    }
}

// 调用 Web 端方法（回调；兼容所支持的平台）
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

// async/await（Swift 并发）
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

// 注册方法供 Web 调用
let methodListener: MethodBlockListener = { param, callback, notify, connection in
    let userId = param?["userId"] as? Int ?? 0

    notify(["progress": 50])

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        callback(["userId": userId, "name": "User"], nil)
    }

    return {
        // 取消时的清理
    }
}
webnat.onMethod(name: "getUserInfo", listener: methodListener)
```

### 4. 发送失败与 handler 错误

- 发送失败会让等待它的调用方知道：参数无法序列化时（`Date`、`NaN`、自定义类型不再让进程崩溃），`method` 立即以 `serializationFailed` 失败；WebView 已不存在或连接已关闭时以 `closed` 失败。`evaluateJavaScript` 报告的错误会让调用以该错误失败。`raw`、`broadcast` 仍是发出即忘。
- method handler 通过 `callback(nil, error)` 报告失败（Swift 闭包不能 throw）。结果无法序列化时，回复 `serializationFailed`，调用方不会因此一直等到超时。

### 5. 页面崩溃与销毁

页面正常卸载时，Web SDK 会发送 CLOSE，Webnat 随之结束该连接。Web 内容进程崩溃或 WebView 被释放时页面没有机会发送，请把事件转给 Webnat：在你的 `webViewWebContentProcessDidTerminate(_:)` 里调用 `webnat.webViewWebContentProcessDidTerminate()`，释放 WebView 之前也调用一次。Webnat 会自行结束该页面的所有连接：待完成的 `method` 调用以 `closed` 失败，正在执行的 method handler 收到取消。不会向页面发送任何消息，Webnat 仍可继续使用，页面重新加载后会照常建立新连接。

```swift
func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    Webnat.of(webView).webViewWebContentProcessDidTerminate()
}
```

## 隐私清单

库内包含 [`Sources/Webnat/PrivacyInfo.xcprivacy`](Sources/Webnat/PrivacyInfo.xcprivacy)。通过 SPM 或 CocoaPods 集成时，资源会随产物进入应用；请按 Apple 对隐私清单的要求随包提交。

## 参与贡献

见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 协议

[MIT](LICENSE)

## 共享回归契约

五端自动消费同一份版本化报文 / 错误解析样例。说明见 `contracts/README.md`；测试门禁、SDK runner 和真机边界见 `contracts/CI.md`。

## 发布

本次统一为 2.0.1 / v2.0.1。请同步升级 Web SDK 与 Native 桥；手动发布命令与迁移说明见 `RELEASING.md`。

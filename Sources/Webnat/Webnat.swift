//
//  Webnat.swift
//  Webnat
//
//  Created by Auhgnayuo on 2025/11/7.
//
import WebKit

/// Webnat - Native 与 Web 之间的双向通信框架
///
/// 提供三种通信模式：
/// 1. **Raw（原始消息）**：最基础的消息传递，不做任何额外处理
/// 2. **Broadcast（广播）**：发布-订阅模式，支持事件通知
/// 3. **Method（方法调用）**：RPC 模式，支持远程方法调用和返回值
///
/// ## 使用示例
///
/// ```swift
/// // 1. 初始化 WebView 配置（须在创建 WKWebView 之前）
/// let config = WKWebViewConfiguration()
/// Webnat.initialize(webViewConfiguration: config)
/// let webView = WKWebView(frame: .zero, configuration: config)
///
/// // 2. 获取 Webnat 实例
/// let webnat = Webnat.of(webView)
///
/// // 3. 注册方法处理器
/// webnat.onMethod(name: "getUserInfo") { param, callback, notify, connection in
///     callback(["name": "John"], nil)
///     return {}
/// }
///
/// // 4. 调用 Web 端方法
/// webnat.method("showAlert", param: ["message": "Hello"]) { result, error in
///     print("Result: \(result ?? "nil")")
/// }
/// ```
///
/// ## 线程安全
///
/// 所有 API 必须在主线程（MainActor）上调用。
@MainActor
@objcMembers
public class Webnat: NSObject {
    /// 初始化 WKWebView 配置，注册脚本消息处理器
    ///
    /// 此方法必须在创建 WKWebView 之前调用，用于：
    /// - 启用 JavaScript 执行
    /// - 注册消息处理器，接收来自 Web 端的消息
    ///
    /// - Parameter webViewConfiguration: 要配置的 WKWebViewConfiguration 实例
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// let config = WKWebViewConfiguration()
    /// Webnat.initialize(webViewConfiguration: config)
    /// let webView = WKWebView(frame: .zero, configuration: config)
    /// ```
    public static func initialize(webViewConfiguration: WKWebViewConfiguration) {
        // `allowsContentJavaScript` is iOS 14+ / macOS 11+; keep iOS 13 / macOS 10.15 on `javaScriptEnabled`.
        if #available(iOS 14.0, macOS 11.0, *) {
            webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            webViewConfiguration.preferences.javaScriptEnabled = true
        }
        
        let prefix = "Webnat"
        let userAgent = "\(prefix)/\(WebnatVersion)"
        let existingUserAgent = webViewConfiguration.applicationNameForUserAgent ?? ""
        let components = existingUserAgent.components(separatedBy: " ")
            .filter { !$0.isEmpty && !$0.starts(with: prefix) }
        let updatedComponents = [userAgent] + components
        webViewConfiguration.applicationNameForUserAgent = updatedComponents.joined(separator: " ")
        
        webViewConfiguration.userContentController.removeScriptMessageHandler(forName: namespace)
        // 每个 configuration 使用独立的无状态 handler 实例，由 `WKUserContentController` 持有；`remove` + `add` 与 `Webnat.of` 路由配合即可。
        webViewConfiguration.userContentController.add(ScriptMessageHandler(), name: namespace)
    }
    
    /// 获取或创建与指定 WebView 关联的 Webnat 实例
    ///
    /// 使用关联对象（Associated Object）机制，确保每个 WKWebView 实例都有唯一的 Webnat 实例
    /// 如果已存在则直接返回，否则创建新实例并关联到 WebView
    ///
    /// - Parameter webView: 目标 WKWebView 实例
    /// - Returns: 与该 WebView 关联的 Webnat 实例
    public static func of(_ webView: WKWebView) -> Webnat {
        var v = objc_getAssociatedObject(webView, &AssociatedKeys.webnat) as? Webnat
        if v != nil {
            return v!
        }
        v = Webnat()
        objc_setAssociatedObject(webView, &AssociatedKeys.webnat, v, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return v!
    }
    
    /// 消息命名空间常量，用于注册 WKScriptMessageHandler
    static private var namespace = "__native_webnat__"
    
    /// 私有初始化方法，使用 `of(_:)` 方法获取实例
    override
    private init() {
        super.init()
    }
    
    /// 当前活跃的连接字典
    ///
    /// key: 连接 ID（由 Web 端生成）
    /// value: Connection 实例
    ///
    /// 每个 WKWebView 可以有多个连接（主框架 + 多个 iframe）
    public private(set) var connections: [String: Connection] = [:]
    
    /// 原始消息处理器
    private let rawWebnat = RawWebnat()
    
    /// 广播消息处理器
    private lazy var broadcastWebnat = BroadcastWebnat()
    
    /// 方法调用处理器
    private let methodWebnat = MethodWebnat()
    
    /// JavaScript 保活管理器
    ///
    /// 用于在 WebView 失活时保持 JavaScript 执行环境活跃
    /// 通过定期发送空消息来防止系统挂起 JS 执行
    private lazy var javaScriptAliveKeeper: JavaScriptAliveKeeper = .init(timerInterval: 1 / 5.0) {
        [weak self] in
        guard let self else {
            return
        }
        guard let connection = connections.first?.value else {
            return
        }
        rawWebnat.raw(nil, connection: connection)
    }
   
    /// 注册原始消息监听器
    ///
    /// 可以注册多个监听器，所有监听器都会收到相同的消息。
    /// 如果同一个监听器引用已存在，则先移除旧的再添加新的。
    ///
    /// - Parameter listener: 消息监听回调
    ///   - param: 接收到的消息内容，可以是任意可序列化的对象
    ///   - connection: 消息来源的连接对象
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// webnat.onRaw { param, connection in
    ///     print("Received raw message: \(param ?? "nil")")
    /// }
    /// ```
    public func onRaw(listener: @escaping RawBlockListener) {
        rawWebnat.on(listener: listener)
    }
    
    /// 移除原始消息监听器
    ///
    /// 使用引用相等性（===）来匹配监听器，只有完全相同的引用才会被移除。
    ///
    /// - Parameter listener: 要移除的监听器（必须与注册时的引用完全相同）
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// let listener: RawBlockListener = { param, connection in
    ///     print("Message: \(param ?? "nil")")
    /// }
    /// webnat.onRaw(listener: listener)
    /// // ... 使用后移除
    /// webnat.offRaw(listener: listener)
    /// ```
    public func offRaw(listener: @escaping RawBlockListener) {
        rawWebnat.off(listener: listener)
    }
    
    /// 发送原始消息到指定连接
    ///
    /// 将消息包装为 Message 格式后发送到 Web 端。
    ///
    /// - Parameters:
    ///   - raw: 消息体，可以是任意可序列化的对象（String、Int、Dictionary、Array 等），可选
    ///   - connection: 目标连接，如果连接已关闭则不会发送
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// if let connection = webnat.connections.values.first {
    ///     webnat.raw(["key": "value"], connection: connection)
    /// }
    /// ```
    public func raw(_ raw: Sendable?, connection: Connection) {
        rawWebnat.raw(raw, connection: connection)
    }

    /// 订阅广播消息
    ///
    /// 注册指定事件名称的监听器，当收到对应事件的广播时触发回调。
    /// 可以注册多个监听器监听同一事件，所有监听器都会收到通知。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称，用于标识不同的事件类型
    ///   - listener: 接收到广播时的回调函数
    ///     - param: 广播携带的参数，可以是任意可序列化的对象，可选
    ///     - connection: 消息来源的连接对象
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// webnat.onBroadcast(name: "userLogin") { param, connection in
    ///     if let userInfo = param as? [String: Any] {
    ///         print("User logged in: \(userInfo)")
    ///     }
    /// }
    /// ```
    public func onBroadcast(name: String, listener: @escaping BroadcastBlockListener) {
        broadcastWebnat.on(name: name, listener: listener)
    }
    
    /// 取消订阅广播消息
    ///
    /// 移除指定事件名称下的特定监听器，使用引用相等性（===）进行匹配。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称
    ///   - listener: 要移除的监听器（必须与注册时的引用完全相同）
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// let listener: BroadcastBlockListener = { param, connection in
    ///     print("Event: \(param ?? "nil")")
    /// }
    /// webnat.onBroadcast(name: "event", listener: listener)
    /// // ... 使用后移除
    /// webnat.offBroadcast(name: "event", listener: listener)
    /// ```
    public func offBroadcast(name: String, listener: @escaping BroadcastBlockListener) {
        broadcastWebnat.off(name: name, listener: listener)
    }
    
    /// 订阅广播消息（异步流方式）
    ///
    /// 通过异步流（AsyncStream）方式订阅广播事件，适用于 Swift Concurrency 场景。
    /// 当对应事件被广播时，新的 `(Sendable?, Connection)` 元组会 yield 到流中。
    /// 流关闭时，会自动注销相关监听器，避免内存泄漏。
    ///
    /// - Parameter name: 广播事件名称
    /// - Returns: 监听广播事件的异步事件流（AsyncStream）
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// Task {
    ///     for await (param, connection) in webnat.listenBroadcast(name: "update") {
    ///         print("Received update: \(param ?? "nil")")
    ///     }
    /// }
    /// ```
    @available(iOS 13.0, macOS 10.15, *)
    public func listenBroadcast(name: String) -> AsyncStream<(Sendable?, Connection)> {
        return broadcastWebnat.listen(name: name)
    }
    
    /// 广播消息
    ///
    /// 向指定连接或所有连接发送广播消息。如果 `connection` 为 `nil`，则向所有当前活跃的连接广播。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称，用于标识事件类型
    ///   - param: 广播参数，可以是任意可序列化的对象，可选
    ///   - connection: 目标连接，如果为 `nil` 则广播到所有连接
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// // 广播到所有连接
    /// webnat.broadcast(name: "dataUpdated", param: ["timestamp": Date().timeIntervalSince1970])
    ///
    /// // 广播到指定连接
    /// if let connection = webnat.connections.values.first {
    ///     webnat.broadcast(name: "notification", param: "Hello", connection: connection)
    /// }
    /// ```
    public func broadcast(
        name: String,
        param: Sendable? = nil,
        connection: Connection? = nil,
    ) {
        if let connection {
            broadcastWebnat.broadcast(name: name, param: param, connection: connection)
        } else {
            for connection in Array(connections.values) {
                broadcastWebnat.broadcast(name: name, param: param, connection: connection)
            }
        }
    }
    
    /// 注册方法处理器
    ///
    /// 注册方法监听器以响应来自 Web 端的方法调用请求。
    ///
    /// **重要**：每个方法名称只能有一个处理器，重复注册会覆盖之前的处理器。
    ///
    /// - Parameters:
    ///   - name: 方法名称，用于标识要处理的方法
    ///   - listener: 方法处理器回调
    ///     - param: 方法调用时传入的参数，可以是任意可序列化的对象，可选
    ///     - callback: 方法执行完成后的回调，用于返回结果或错误
    ///       - result: 方法执行结果，成功时传入，失败时为 `nil`
    ///       - error: 错误信息，失败时传入，成功时为 `nil`
    ///     - notify: 通知回调，用于在方法执行过程中发送进度或状态更新
    ///       - param: 通知内容，可以是进度信息、中间结果等
    ///     - connection: 调用来源的连接对象
    ///   - Returns: 取消函数，用于在方法执行过程中取消操作
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// webnat.onMethod(name: "getUserInfo") { param, callback, notify, connection in
    ///     // 发送进度通知
    ///     notify(["progress": 50])
    ///
    ///     // 执行完成后返回结果
    ///     callback(["name": "John", "age": 30], nil)
    ///
    ///     // 返回取消函数
    ///     return {
    ///         // 清理资源
    ///     }
    /// }
    /// ```
    public func onMethod(name: String, listener: @escaping MethodBlockListener) {
        methodWebnat.on(name: name, listener: listener)
    }
    
    /// 移除方法处理器
    ///
    /// 移除指定方法名称的处理器。使用引用相等性（===）进行匹配。
    ///
    /// - Parameters:
    ///   - name: 方法名称
    ///   - listener: 要移除的方法处理器（必须与注册时的引用完全相同）
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// let handler: MethodBlockListener = { param, callback, notify, connection in
    ///     callback("result", nil)
    ///     return {}
    /// }
    /// webnat.onMethod(name: "myMethod", listener: handler)
    /// // ... 使用后移除
    /// webnat.offMethod(name: "myMethod", listener: handler)
    /// ```
    public func offMethod(name: String, listener: @escaping MethodBlockListener) {
        methodWebnat.off(name: name, listener: listener)
    }
    
    /// 调用 Web 端方法（回调版本）
    ///
    /// 执行远程方法调用，支持超时和取消。这是一个异步操作，结果通过回调返回。
    ///
    /// **执行流程**：
    /// 1. 生成唯一调用 ID
    /// 2. 设置超时定时器（如果指定）
    /// 3. 注册完成回调和通知回调
    /// 4. 发送调用请求到 Web 端
    /// 5. 等待结果、超时或被取消
    /// 6. 清理资源并触发回调
    ///
    /// > 未指定 `connection`（广播）时，上述流程会对每个连接各执行一次，并按「谁先返回用谁的」
    /// > 竞赛裁决，详见下方 `connection` 参数说明。
    ///
    /// - Parameters:
    ///   - method: 要调用的方法名称
    ///   - param: 方法参数，可以是任意可序列化的对象，可选
    ///   - timeout: 超时时间（秒），默认值为 `.greatestFiniteMagnitude`（表示永不超时，不会注册定时器）
    ///     有限且大于 `0` 时，超时后会自动取消调用并返回超时错误
    ///   - onNotification: 收到通知时的回调函数，用于接收方法执行过程中的进度或状态更新
    ///     - param: 通知内容，可以是进度信息、中间结果等
    ///   - callback: 完成回调，接收方法执行结果或错误
    ///     - result: 方法执行结果，成功时传入，失败时为 `nil`
    ///     - error: 错误信息，失败时传入，成功时为 `nil`
    ///   - connection: 目标连接。传入具体连接时只调用该连接；为 `nil` 时**广播**给当前所有连接
    ///     （主框架 + 所有 iframe），并按「谁先返回用谁的」裁决：第一个发来 notify / 成功 / 真实业务错误的
    ///     连接获胜，其余被 `abort`；仅回 `unimplemented`/`closed` 的连接不参与获胜，全部如此时才失败。
    /// - Returns: 取消函数，调用此函数可以主动取消正在执行的方法调用
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// let cancel = webnat.method("calculate", param: ["x": 10, "y": 20], timeout: 5.0,
    ///     onNotification: { progress in
    ///         print("Progress: \(progress ?? "nil")")
    ///     },
    ///     callback: { result, error in
    ///         if let error = error {
    ///             print("Error: \(error)")
    ///         } else {
    ///             print("Result: \(result ?? "nil")")
    ///         }
    ///     }
    /// )
    ///
    /// // 如果需要取消
    /// // cancel()
    /// ```
    @discardableResult
    public func method(
        _ method: String,
        param: Sendable? = nil,
        timeout: TimeInterval = .greatestFiniteMagnitude,
        onNotification: MethodOnNotification? = nil,
        callback: MethodCallback? = nil,
        connection: Connection? = nil,
    ) -> MethodCancellation {
        let effectiveTimeout = Self.normalizedRPCTimeout(timeout)
        javaScriptAliveKeeper.increaseReference()

        // 指定了连接：沿用单连接直连语义
        if let connection {
            return methodWebnat.method(method, param: param, timeout: effectiveTimeout, onNotification: onNotification, callback: { [weak self] in
                callback?($0, $1)
                self?.javaScriptAliveKeeper.decreaseReference()
            }, connection: connection)
        }

        // 未指定连接：广播给所有连接（主框架 + 所有 iframe），谁先返回用谁的
        let call = BroadcastMethodCall(
            method: method,
            onNotification: onNotification,
            callback: callback,
            onFinished: { [weak self] in
                self?.javaScriptAliveKeeper.decreaseReference()
            }
        )
        return call.start(
            connections: Array(connections.values),
            methodWebnat: methodWebnat,
            param: param,
            timeout: effectiveTimeout
        )
    }
    
    /// 调用 Web 端方法（异步版本）
    ///
    /// 执行远程方法调用，支持超时和取消。使用 Swift Concurrency 的 `async/await` 语法。
    ///
    /// - Parameters:
    ///   - method: 要调用的方法名称
    ///   - param: 方法参数，可以是任意可序列化的对象，可选
    ///   - timeout: 超时时间（秒）。`nil`、非正数或非有限值（如 `.infinity`）均**不**注册超时定时器；仅有限且 `> 0` 时超时后会自动取消调用并抛出超时错误
    ///   - onNotification: 收到通知时的回调函数，用于接收方法执行过程中的进度或状态更新
    ///     - param: 通知内容，可以是进度信息、中间结果等
    ///   - connection: 目标连接。传入具体连接时只调用该连接；为 `nil` 时**广播**给当前所有连接
    ///     （主框架 + 所有 iframe），并按「谁先返回用谁的」裁决（详见回调版说明）
    /// - Returns: 方法执行结果，可以是任意可序列化的对象，可选
    /// - Throws: 方法执行错误，包括：
    ///   - 超时错误（`WebnatErrorCode.timeout`）
    ///   - 取消错误（`WebnatErrorCode.cancelled`）
    ///   - 连接关闭错误（`WebnatErrorCode.closed`）
    ///   - 其他执行错误
    ///
    /// ## 使用示例
    ///
    /// ```swift
    /// Task {
    ///     do {
    ///         let result = try await webnat.method("getData", param: ["id": 123], timeout: 10.0,
    ///             onNotification: { progress in
    ///                 print("Progress: \(progress ?? "nil")")
    ///             }
    ///         )
    ///         print("Result: \(result ?? "nil")")
    ///     } catch {
    ///         print("Error: \(error)")
    ///     }
    /// }
    /// ```
    @available(iOS 13.0, macOS 10.15, *)
    @discardableResult
    public func method(
        _ method: String,
        param: Sendable? = nil,
        timeout: TimeInterval? = nil,
        onNotification: MethodOnNotification? = nil,
        connection: Connection? = nil,
    ) async throws -> Sendable? {
        // 指定了连接：沿用单连接直连语义
        if let connection {
            javaScriptAliveKeeper.increaseReference()
            defer {
                javaScriptAliveKeeper.decreaseReference()
            }
            return try await methodWebnat.method(
                method,
                param: param,
                timeout: timeout,
                onNotification: onNotification,
                connection: connection
            )
        }

        // 未指定连接：广播竞赛。复用回调版（其内部已处理 JS 保活与竞赛裁决）
        let cbTimeout = timeout ?? .greatestFiniteMagnitude
        nonisolated(unsafe) var cancel: MethodCancellation?
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Sendable?, Error>) in
                    cancel = self.method(
                        method,
                        param: param,
                        timeout: cbTimeout,
                        onNotification: onNotification,
                        callback: { result, error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: result)
                            }
                        },
                        connection: nil
                    )
                }
            },
            onCancel: {
                Task { @MainActor in
                    cancel?()
                }
            },
            isolation: MainActor.shared
        )
    }

    /// 处理来自 Web 端的脚本消息
    ///
    /// 当 Web 端通过 `window.webkit.messageHandlers.__native_webnat__.postMessage()` 发送消息时，
    /// 此方法会被 `ScriptMessageHandler` 调用，负责解析消息并分发到相应的处理器。
    ///
    /// **重要说明**：
    /// - 本实现只处理 `WKScriptMessage.body` 为 `[String: Any]`（字典）的情况，与 `postMessage` 传入对象时 WebKit 的常见行为一致
    /// - 其他类型（如字符串、数字）会被忽略
    ///
    /// **支持的消息类型**：
    /// - `open`: 连接建立消息，创建新的 `Connection` 实例
    /// - `close`: 连接关闭消息，移除对应的 `Connection` 实例
    /// - `raw`: 原始消息，分发给 `RawWebnat`
    /// - `broadcast`: 广播消息，分发给 `BroadcastWebnat`
    /// - `invoke`: 方法调用请求，分发给 `MethodWebnat`
    /// - `reply`: 方法调用响应，分发给 `MethodWebnat`
    /// - `notify`: 方法调用通知，分发给 `MethodWebnat`
    /// - `abort`: 方法调用取消，分发给 `MethodWebnat`
    ///
    /// - Parameters:
    ///   - userContentController: 消息控制器
    ///   - message: 来自 Web 端的消息对象；仅当 `body` 可 cast 为 `[String: Any]` 时才会继续处理
    ///
    /// - Note: 此方法是内部方法，不应直接调用
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        javaScriptAliveKeeper.delay()
        
        guard let json = message.body as? [String: Any] else {
            return
        }
        
        // 使用 Message 类解析消息
        guard let msg = Message.from(dict: json) else {
            return
        }
        
        let from = msg.from
        
        // 处理连接打开消息
        if let open = msg.open {
            // 检查是否已存在相同 ID 的连接
            if connections.keys.contains(from) {
                return
            }
            
            // 提取连接元数据
            var attributes: [String: Any] = [:]
            if let param = open.param as? [String: Any] {
                attributes = param
            }
            attributes["frameInfo"] = message.frameInfo
            
            // 获取 webView 引用
            guard let webView = message.webView else {
                return
            }
            
            // 创建新的 Connection 实例
            let connection = Connection(id: from, attributes: attributes, url: webView.url) { [weak self, weak webView] messageToSend, completion in
                guard let self, let webView = webView else {
                    completion?(NSError.closed())
                    return
                }
                
                do {
                    // 将单条消息包成 JSON 数组字面量，供 `receive(...)` 展开为参数
                    let data = try JSONSerialization.data(withJSONObject: [messageToSend.toDictionary()])
                    guard let string = String(data: data, encoding: .utf8) else {
                        completion?(NSError.serializationFailed(messageToSend))
                        return
                    }

                    // 重置保活
                    self.javaScriptAliveKeeper.delay()

                    // 构造 JavaScript 代码调用 Web 端的 receive 方法
                    let js = "window.__web_webnat__.receive(...\(string))"
                                            
                    webView.evaluateJavaScript(js, completionHandler: { _, error in
                        if let error = error {
                            completion?(error)
                            return
                        }
                        completion?(nil)
                    })
                } catch let e {
                    completion?(e)
                }
            }
            onConnectionOpen(connection: connection)
            return
        }
        
        // 处理连接关闭消息
        if msg.close != nil {
            guard let connection = connections.removeValue(forKey: from) else {
                return
            }
            connection.closed = true
            onConnectionClose(connection: connection)
            return
        }
        
        // 处理其他消息类型（raw, broadcast, invoke, reply, notify, abort）
        guard let connection = connections[from] else {
            return
        }
        onConnectionReceive(connection: connection, message: msg)
    }
    
    /// 连接打开时的回调
    ///
    /// 当收到 Web 端的 "open" 消息时调用：**仅此处置入** `connections`，并通知各子模块。
    ///
    /// - Parameter connection: 新打开的连接
    ///
    /// - Note: 此方法是内部方法，不应直接调用
    private func onConnectionOpen(connection: Connection) {
        connections[connection.id] = connection
        rawWebnat.onConnectionOpen(connection: connection)
        broadcastWebnat.onConnectionOpen(connection: connection)
        methodWebnat.onConnectionOpen(connection: connection)
    }
  
    /// 连接关闭时的回调
    ///
    /// 当收到 Web 端的 "close" 消息时调用：连接已从 `connections` 中移除（见 `userContentController`），此处只通知子模块。
    ///
    /// - Parameter connection: 已关闭的连接
    ///
    /// - Note: 此方法是内部方法，不应直接调用
    private func onConnectionClose(connection: Connection) {
        rawWebnat.onConnectionClose(connection: connection)
        broadcastWebnat.onConnectionClose(connection: connection)
        methodWebnat.onConnectionClose(connection: connection)
    }

    /// 接收到消息时的回调
    ///
    /// 当收到 Web 端的普通消息（非 open/close）时调用，将消息分发到所有子处理器。
    ///
    /// - Parameters:
    ///   - connection: 消息来源连接
    ///   - message: 接收到的消息（已解析的 `Message` 对象）
    ///
    /// - Note: 此方法是内部方法，不应直接调用
    private func onConnectionReceive(connection: Connection, message: Message) {
        rawWebnat.onConnectionReceive(connection: connection, message: message)
        broadcastWebnat.onConnectionReceive(connection: connection, message: message)
        methodWebnat.onConnectionReceive(connection: connection, message: message)
    }

    /// 将回调版 `method` 的 `TimeInterval` 超时转为 `MethodWebnat` 所用的可选秒数：永不超时、非正数、非有限值均视为 `nil`（不注册定时器）。
    private static func normalizedRPCTimeout(_ timeout: TimeInterval) -> TimeInterval? {
        if timeout <= 0 || !timeout.isFinite { return nil }
        if timeout == .greatestFiniteMagnitude { return nil }
        return timeout
    }
}

private enum AssociatedKeys {
    @MainActor static var webnat: Void?
}

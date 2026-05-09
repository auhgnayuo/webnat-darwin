//
//  MethodWebnat.swift
//  Webnat
//
//  Created by Auhgnayuo on 2024/12/9.
//

import Foundation

/// 方法调用完成回调类型定义
///
/// 用于接收方法调用执行结果的回调类型，会在主线程上以 block 调用方式被执行。
///
/// - Parameters:
///   - result: 方法执行结果，可以是任意可序列化的对象，成功时传入，失败时为 `nil`
///   - error: 错误信息，失败时传入，成功时为 `nil`
public typealias MethodCallback = @MainActor @Sendable (_ result: Sendable?, _ error: Error?)->Void

/// 方法调用取消函数类型定义
///
/// 调用此函数可以取消正在执行的方法调用。
public typealias MethodCancellation = @MainActor @Sendable () -> Void

/// 方法调用通知类型定义
///
/// 用于接收方法执行过程中的通知（如进度、中间结果等），会在主线程上以 block 调用方式被执行。
///
/// - Parameter param: 方法执行途中的通知内容，可以是任意可序列化的对象，可选
public typealias MethodOnNotification = @MainActor @Sendable (_ param: Sendable?) -> Void

/// 方法监听器类型定义
///
/// 用于处理来自 Web 端的方法调用请求，会在主线程上以 block 调用方式被执行。
///
/// - Parameters:
///   - param: 方法调用时传入的参数，可以是任意可序列化的对象，可选
///   - callback: 方法执行完成后的回调，用于返回结果或错误
///     - result: 方法执行结果，成功时传入，失败时为 `nil`
///     - error: 错误信息，失败时传入，成功时为 `nil`
///   - notify: 通知回调，用于在方法执行过程中发送进度或状态更新
///     - param: 通知内容，可以是进度信息、中间结果等
///   - connection: 调用来源的连接对象
/// - Returns: 取消函数，用于在方法执行过程中取消操作
public typealias MethodBlockListener = @MainActor @Sendable @convention(block) ( _ param: Sendable?, _ callback: @escaping MethodCallback, _ notify: @escaping MethodOnNotification, _ connection: Connection) -> MethodCancellation

/// MethodWebnat - 方法调用消息传递器
///
/// 实现请求-响应模式的远程方法调用（RPC）机制。
///
/// 适用场景：
/// - 需要获取返回值的方法调用
/// - 异步操作（如文件读取、网络请求等）
/// - 需要超时控制的场景
/// - 需要主动取消的长时间操作
///
/// 特点：
/// - 支持双向方法调用（Native 调用 Web 和 Web 调用 Native）
/// - 基于回调的异步调用
/// - 支持超时控制
/// - 支持主动取消正在执行的方法
/// - 自动错误传递
/// - 每个调用有唯一 ID，支持并发多个调用
///
/// 消息格式：使用 `Message` 类型，包含 invoke、reply、notify、abort 等字段
/// - 调用请求：`{ from: string, to: string, invoke: { id: string, method: string, param?: Sendable } }`
/// - 调用结果：`{ from: string, to: string, reply: { id: string, result?: Sendable, error?: Sendable } }`
/// - 调用通知：`{ from: string, to: string, notify: { id: string, param?: Sendable } }`
/// - 取消请求：`{ from: string, to: string, abort: { id: string } }`

@MainActor
final class MethodWebnat {
    
    /// 方法监听器映射表
    /// key: 方法名称（String）
    /// value: 方法处理器 Listener
    /// 为每个已注册的方法名称维护一个对应的处理器，用于处理 Web 端的方法调用请求
    private var listeners: [String: Listener] = [:]

    /// 方法调用途中的通知（比如进度）
    /// key: 调用 ID
    /// value: 用于响应通知的回调函数（如进度、步骤变更等）
    private var onNotifications: [String: MethodOnNotification] = [:]
    
    /// 方法调用完成回调映射表
    /// key: 调用 ID（字符串，为本地发起或接收调用的唯一标识）
    /// value: 完成回调函数，收到结果或错误时调用
    private var onCompletes: [String: (_ result: Sendable?, _ error: Error?)->Void] = [:]

    /// 连接关闭时的清理回调映射表
    /// key: 连接 ID
    /// value: 该连接上所有待完成调用的清理回调，嵌套字典 key 为调用 ID，value 为清理回调 closure
    private var onCloses: [String: [String: ()->Void]] = [:]

    /// 方法调用取消函数映射表
    /// key: 调用 ID（这里是被调用方接收到的 ID）
    /// value: 取消函数（Closure），收到取消请求时执行
    private var aborts: [String: ()->Void] = [:]
    
    /// 注册方法处理器
    ///
    /// 注册方法监听器以响应来自 Web 端的方法调用请求。
    ///
    /// **重要**：每个方法名称只能有一个处理器，重复注册会覆盖之前的处理器。
    ///
    /// - Parameters:
    ///   - name: 方法名称，用于标识要处理的方法
    ///   - listener: 方法处理器，当收到对应方法的调用请求时会被调用
    func on(name: String, listener: @escaping MethodBlockListener) {
        listeners[name] = Listener(value: listener)
    }
    
    /// 移除方法处理器
    ///
    /// 从监听器映射表中移除指定名称和处理器的组合。
    ///
    /// - Parameters:
    ///   - name: 方法名称
    ///   - listener: 方法处理器
    func off(name: String, listener: @escaping MethodBlockListener) {
        if let l = listeners[name], (listener as AnyObject) === (l.value as AnyObject) {
            listeners.removeValue(forKey: name)
        }
    }

    /// 调用 Web 端方法（回调版本）
    ///
    /// 发起远程方法调用，支持超时和取消。这是一个异步操作，结果通过回调返回。
    ///
    /// **调用流程**：
    /// 1. 生成唯一调用 ID
    /// 2. 设置超时定时器（如有传入）
    /// 3. 注册完成回调和通知回调
    /// 4. 发送调用请求消息
    /// 5. 等待结果、超时或被取消
    /// 6. 清理回调和定时任务
    ///
    /// - Parameters:
    ///   - method: 要调用的方法名称
    ///   - param: 方法参数，可以是任意可序列化的对象，可选
    ///   - timeout: 超时时间（秒）；`nil` 或 `<= 0` 时不注册超时定时器。`> 0` 时超时后会自动取消调用并返回超时错误
    ///   - onNotification: 接收到途中的通知时回调，用于接收方法执行过程中的进度或状态更新
    ///     - param: 通知内容，可以是进度信息、中间结果等
    ///   - callback: 完成回调，接收方法执行结果或错误
    ///     - result: 方法执行结果，成功时传入，失败时为 `nil`
    ///     - error: 错误信息，失败时传入，成功时为 `nil`
    ///   - connection: 目标连接，如果为 `nil` 则报错
    /// - Returns: 取消函数，调用此函数可以主动取消正在执行的方法调用
    @discardableResult
    func method(
        _ method: String,
        param: Sendable? = nil,
        timeout: TimeInterval? = nil,
        onNotification: MethodOnNotification? = nil,
        callback: MethodCallback? = nil,
        connection: Connection? = nil,
    ) -> MethodCancellation {
        guard let connection else {
            callback?(nil, NSError.closed())
            return {}
        }
        // 生成唯一调用 ID
        let id = UUID().uuidString
        
        /// 注册超时任务（若需要），并返回用于 `cancel()` 的闭包。
        let cancelTimeout = {
            if let timeout, timeout > 0, timeout.isFinite {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else {
                        return
                    }
                    guard let onComplete = self.onCompletes[id] else {
                        return
                    }
                    // 触发超时回调
                    onComplete(nil, NSError.timeout())
                    // 发送取消请求
                    let message = Message.abort(to: connection.id, id: id)
                    connection.send(message)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
                return { item.cancel()}
            }
            return {}
        }()
        
        /// 用于取消连接关闭回调的 closure（即移除关闭事件的回调），避免泄漏
        let cancelClose = {[weak self] in
            guard let self else {
                return {}
            }
            // 注册连接关闭回调
            if onCloses[connection.id] == nil {
                onCloses[connection.id] = [:]
            }
            onCloses[connection.id]![id] = { [weak self] in
                guard let self else {
                    return
                }
                // 连接关闭时，返回错误
                self.onCompletes[id]?(nil, NSError.closed())
            }
            return { [weak self] in
                guard let self else {
                    return
                }
                onCloses[connection.id]?.removeValue(forKey: id)
                if onCloses[connection.id]?.isEmpty == true {
                    onCloses.removeValue(forKey: connection.id)
                }
            }
        }()
        
        /// 用于取消通知监听的 closure（即注销对应 id 的通知 callback），避免泄漏
        let cancelOnNotification = {[weak self] in
            guard let self else {
                return {}
            }
            
            // 注册通知回调
            onNotifications[id] = {
                onNotification?($0)
            }
            return {[weak self] in
                guard let self else {
                    return
                }
                onNotifications.removeValue(forKey: id)
            }
        }()
        
        // 注册完成回调（收到结果或错误时）
        onCompletes[id] = {[weak self] result, error in
            guard let self else {
                return
            }
            // 清理资源
            self.onCompletes.removeValue(forKey: id)
            cancelOnNotification()
            cancelClose()
            cancelTimeout()
            // 触发用户回调
            callback?(result, error)
        }
        
        // 发送调用请求
        let message = Message.invoke(to: connection.id, id: id, method: method, param: param)
        connection.send(message) { [weak self] error in
            guard let self else {
                return
            }
            // 如果发送失败，返回错误
            if let error = error {
                self.onCompletes[id]?(nil, error)
            }
        }
      
        /// 返回取消函数，支持主动取消本次 method 操作
        return { [weak self] in
            guard let self else {
                return
            }
            guard let onComplete = self.onCompletes[id] else {
                return
            }
            // 发送取消请求
            let message = Message.abort(to: connection.id, id: id)
            connection.send(message)
            // 触发取消回调
            onComplete(nil, NSError.cancelled())
        }
    }
    
    /// 调用 Web 端方法（异步版本）
    ///
    /// 执行远程方法调用，支持超时和取消。使用 Swift Concurrency 的 `async/await` 语法。
    ///
    /// - Parameters:
    ///   - method: 要调用的方法名称
    ///   - param: 方法参数，可以是任意可序列化的对象，可选
    ///   - timeout: 超时时间（秒）；`nil` 或 `<= 0` 时不注册超时。`> 0` 时超时后会自动取消调用并抛出超时错误
    ///   - onNotification: 用于监听途中的通知回调，用于接收方法执行过程中的进度或状态更新
    ///     - param: 通知内容，可以是进度信息、中间结果等
    ///   - connection: 目标连接；`nil` 时立即失败（`closed`）。由 `Webnat.method` 异步入口负责解析默认连接。
    /// - Returns: 方法执行结果，可以是任意可序列化的对象，可选
    /// - Throws: 方法执行错误，包括：
    ///   - 超时错误（`WebnatErrorCode.timeout`）
    ///   - 取消错误（`WebnatErrorCode.cancelled`）
    ///   - 连接关闭错误（`WebnatErrorCode.closed`）
    ///   - 其他执行错误
    @available(iOS 13.0.0, *)
    @discardableResult
    public func method(
        _ method: String,
        param: Sendable? = nil,
        timeout: TimeInterval? = nil,
        onNotification: MethodOnNotification? = nil,
        connection: Connection? = nil,
    ) async throws -> Sendable? {
        var cancel: MethodCancellation?
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    cancel = self.method(
                        method,
                        param: param,
                        timeout: timeout,
                        onNotification: onNotification,
                        callback: { result, error in
                            Task {@MainActor in
                                if let error = error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume(returning: result)
                                }
                            }
                        }, connection: connection
                    )
                }
            },
            onCancel: {
                // 协程被取消时，主动调用取消逻辑
                Task { @MainActor in
                    cancel?()
                }
            },
            isolation: MainActor.shared
        )
    }
    
    /// 连接打开时的回调
    ///
    /// 连接表由 `Webnat` 维护；此处为生命周期钩子，当前无额外逻辑。
    ///
    /// - Parameter connection: 新打开的连接对象（Connection 实例）
    func onConnectionOpen(connection: Connection) {

    }
    
    /// 连接关闭时的回调
    ///
    /// 触发该连接上所有**本模块发起的、尚未完成**的 RPC 清理逻辑（如向调用方补发关闭错误）；不负责从 `Webnat.connections` 中移除。
    ///
    /// - Parameter connection: 已关闭的连接对象（Connection 实例）
    func onConnectionClose(connection: Connection) {
        // 触发该连接上所有待完成调用的清理回调（如超时、主动取消、断开等，统一清理）
        let onCloses = onCloses[connection.id]
        // 执行所有该连接上的清理回调
        onCloses?.values.forEach { onClose in
            onClose()
        }
    }
    
    /// 接收到消息时的回调
    ///
    /// 处理四种类型的方法消息：
    /// 1. `reply`: 方法调用结果（收到我们发起的调用响应）
    /// 2. `invoke`: 方法调用请求（Web 端请求 Native 方法）
    /// 3. `abort`: 取消方法调用
    /// 4. `notify`: 方法途中的通知（如进度/信息）
    ///
    /// - Parameters:
    ///   - connection: 消息来源连接
    ///   - message: 接收到的消息（已解析的 `Message` 对象）
    func onConnectionReceive(connection: Connection, message: Message) {
        // 处理 reply 消息
        if let reply = message.reply {
            let id = reply.id
            if let error = reply.error {
                // 有错误，触发完成回调并传递错误
                onCompletes[id]?(nil, NSError.from(error))
            } else {
                // 成功，触发完成回调并传递结果
                onCompletes[id]?(reply.result, nil)
            }
            return
        }
        
        // 处理 notify 消息
        if let notify = message.notify {
            onNotifications[notify.id]?(notify.param)
            return
        }
        
        // 处理 abort 消息
        if let abort = message.abort {
            aborts[abort.id]?()
            return
        }
        
        // 处理 invoke 消息
        if let invoke = message.invoke {
            let id = invoke.id
            let method = invoke.method
            let param = invoke.param
            
            // 检查方法是否已注册
            guard let listener = listeners[method] else {
                // 方法未实现，返回错误
                let error = NSError.unimplemented(method)
                let replyMessage = Message.reply(to: connection.id, id: id, error: error.toJson())
                connection.send(replyMessage)
                return
            }
            
            var isCompleted = false
            
            /// 清理资源（取消所有与本次调用绑定的回调和状态）
            let clean = {[weak self]  in
                guard let self else {
                    return
                }
                // 清理资源
                self.aborts[id] = nil
                self.onCloses[connection.id]?.removeValue(forKey: id)
                if self.onCloses[connection.id]?.isEmpty == true {
                    self.onCloses.removeValue(forKey: connection.id)
                }
            }
            
            /// 向调用方主动推送途中的通知（如进度等）
            let notify = {(param: Sendable?) in
                guard isCompleted == false else {
                    return
                }
                let notifyMessage = Message.notify(to: connection.id, id: id, param: param)
                connection.send(notifyMessage)
            }
         
            /// 完成回调：向调用方发送最终的执行结果或错误
            let complete = {(result: Sendable?, error: Error?) in
                guard isCompleted == false else {
                    return
                }
                isCompleted = true
                clean()
                let replyMessage: Message
                if let error = error {
                    // 有错误，发送错误响应
                    replyMessage = Message.reply(to: connection.id, id: id, error: (error as NSError).toJson())
                } else {
                    // 成功，发送结果响应
                    replyMessage = Message.reply(to: connection.id, id: id, result: result)
                }
                connection.send(replyMessage)
            }
            
            if let l = listener.value as? MethodBlockListener {
                // 调用方法监听器，l 返回取消此次调用的 cancel closure
                let abort = l(param, {result, error in
                    guard isCompleted == false else {
                        return
                    }
                    complete(result, error)
                }, {
                    notify($0)
                }, connection)
                // 注册取消函数（收到取消请求时会触发此 closure，进行清理和调用用户的 abort 逻辑）
                aborts[id] = {
                    guard isCompleted == false else {
                        return
                    }
                    isCompleted = true
                    clean()
                    abort()
                }
                
                // 注册连接关闭回调（连接关闭时即视为调用被终止，需要清理与主动取消）
                if onCloses[connection.id] == nil {
                    onCloses[connection.id] = [:]
                }
                onCloses[connection.id]![id] = {
                    guard isCompleted == false else {
                        return
                    }
                    isCompleted = true
                    clean()
                    abort()
                }
            }
            return
        }
    }
}


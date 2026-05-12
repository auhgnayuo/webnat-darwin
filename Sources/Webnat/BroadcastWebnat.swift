//
//  BroadcastWebnat.swift
//  Webnat
//
//  Created by Auhgnayuo on 2024/12/9.
//

import Foundation

/// 广播消息监听器类型定义
///
/// 用于监听广播事件的回调类型，监听函数会在主线程上以 block 调用方式被执行。
///
/// - Parameters:
///   - param: 广播推送的参数，可以是任意可序列化的对象，若无参数则为 `nil`
///   - connection: 消息来源的连接对象
public typealias BroadcastBlockListener = @MainActor @Sendable @convention(block) (_ param: Sendable?,_ connection: Connection) -> Void

/// BroadcastWebnat - 广播消息传递器
///
/// 实现发布-订阅（pub/sub）模式的消息传递机制。
///
/// **适用场景**：
/// - 事件通知（如状态变更、数据更新等）
/// - 一对多的消息分发
/// - 不需要返回值的通知场景
///
/// **特点**：
/// - 按事件名称分类管理监听器
/// - 支持多个订阅者同时监听同一事件
/// - 可以向指定连接广播（多连接由 `Webnat.broadcast` 侧循环派发）
/// - 广播时不关心是否有订阅者的存在
///
/// **消息格式**：
/// - 使用 `Message` 类型，包含 `broadcast` 字段
/// - Message 格式：`{ from: string, to: string, broadcast: { name: string, param?: Sendable } }`
///
/// - Note: 这是内部类，不应直接使用，应通过 `Webnat` 类的 API 访问
@MainActor
final class BroadcastWebnat {
    
    /// 广播事件监听器映射表
    ///
    /// key: 广播事件名称
    /// value: 绑定在该事件名称上的监听器数组
    private var listeners: [String: [Listener]] = [:]

    /// 判断包装的 value 是否与给定的 block 监听器为同一引用
    private func isSameBlock(_ wrapper: Listener, as listener: BroadcastBlockListener) -> Bool {
        guard let value = wrapper.value as? BroadcastBlockListener else { return false }
        return (value as AnyObject) === (listener as AnyObject)
    }

    /// 注册（订阅）广播消息
    ///
    /// 注册指定事件名称的监听器，当收到对应事件的广播时触发回调。
    /// 若同一监听器对象已被注册，则会先移除后再添加，避免重复订阅。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称（字符串标识），用于标识不同的事件类型
    ///   - listener: 接收到广播时的回调函数，当对应事件被广播时会被调用
    func on(name: String, listener: @escaping BroadcastBlockListener) {
        // 如果该事件名称还没有监听器，创建新的监听器数组
        if listeners[name] == nil {
            listeners[name] = []
        }
        
        // 移除已存在的相同监听器（如果有的话，使用引用判等）
        listeners[name]!.removeAll { isSameBlock($0, as: listener) }
        
        // 添加新的监听器
        listeners[name]!.append(Listener(value: listener))
    }
    
    /// 取消订阅广播消息
    ///
    /// 将指定事件名称下的特定监听器移除，使用引用相等性（===）进行匹配。
    /// 若该事件下已无监听器，会移除对应 key，避免空数组残留。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称
    ///   - listener: 要移除的监听器（必须与注册时的引用完全相同）
    func off(name: String, listener: BroadcastBlockListener) {
        listeners[name]?.removeAll { isSameBlock($0, as: listener) }
        if listeners[name]?.isEmpty == true {
            listeners.removeValue(forKey: name)
        }
    }
    
    /// 订阅广播异步流（Swift Concurrency）
    ///
    /// 通过异步流（AsyncStream）方式订阅广播事件。
    /// 当对应事件被广播时，新的 `(Sendable?, Connection)` 元组会 yield 到流中。
    /// 流关闭时，会自动注销相关监听器，避免内存泄漏。
    ///
    /// - Parameter name: 广播事件名称
    /// - Returns: 监听广播事件的异步事件流（AsyncStream）
    @available(iOS 13.0, macOS 10.15, *)
    func listen(name: String) -> AsyncStream<(Sendable?, Connection)> {
        return AsyncStream { continuation in
            // 如果还没有监听器，创建一个监听器数组
            if listeners[name] == nil {
                listeners[name] = []
            }
            let handle = BroadcastAsyncStreamHandle(continuation)
            let l = Listener(value: handle)
            listeners[name]!.append(l)
            continuation.onTermination = { [weak self] _ in
                handle.finish()
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.listeners[name]?.removeAll(where: { $0 === l })
                    if self.listeners[name]?.isEmpty == true {
                        self.listeners.removeValue(forKey: name)
                    }
                }
            }
        }
    }
    
    /// 广播消息推送
    ///
    /// 向**单个**连接发送一条广播消息。未指定连接时的「全体广播」由 `Webnat` 遍历 `connections` 并多次调用本方法完成。
    ///
    /// - Parameters:
    ///   - name: 广播事件名称，用于标识事件类型
    ///   - param: 广播参数，可以是任意可序列化的对象，可选。若无参数，则消息不携带 `param` 字段
    ///   - connection: 目标连接；为 `nil` 时不发送（调用方应保证传入有效连接）
    func broadcast(name: String, param: Sendable? = nil, connection: Connection? = nil) {
        guard let connection else {
            return
        }
        
        let message = Message.broadcast(to: connection.id, name: name, param: param)
        connection.send(message)
    }
        
    /// 连接打开（建立）时的回调
    ///
    /// 连接表由 `Webnat` 维护；此处为生命周期钩子，当前无额外逻辑。
    ///
    /// - Parameters:
    ///   - connection: 新打开的连接对象（Connection 实例）
    func onConnectionOpen(connection: Connection) {
    }
    
    /// 连接关闭时的回调
    ///
    /// 连接表由 `Webnat` 维护；此处为生命周期钩子，当前无额外逻辑。
    ///
    /// - Parameters:
    ///   - connection: 已关闭的连接对象（Connection 实例）
    func onConnectionClose(connection: Connection) {
      
    }
    
    /// 接收到广播消息时的回调
    ///
    /// 用于分发 Web 或 Native 侧收到的广播消息。
    /// 按事件名称查找并依次回调所有已订阅的监听器（支持回调函数和 async stream）。
    ///
    /// - Parameters:
    ///   - connection: 消息来源连接
    ///   - message: 收到的消息（已解析的 `Message` 对象）
    @MainActor
    func onConnectionReceive(connection: Connection, message: Message) {
        // 检查是否为 broadcast 消息
        guard let broadcast = message.broadcast else {
            return
        }
        // 根据事件名称分发触发所有相关的监听器（block 或 async stream）
        let listeners = listeners[broadcast.name]
        listeners?.forEach { listener in
            if let l = listener.value as? BroadcastBlockListener {
                l(broadcast.param, connection)
            } else if #available(iOS 13.0, macOS 10.15, *),
                      let handle = listener.value as? BroadcastAsyncStreamHandle
            {
                handle.yield((broadcast.param, connection))
            }
        }
    }
}

// MARK: - AsyncStream broadcast sink

/// 包装 `AsyncStream` 的 continuation：终止时同步标记结束并 `finish()`，投递前检查标志，避免取消后长时间仍挂在 `listeners` 里且继续 yield（`onTermination` 与 `onConnectionReceive` 的竞态由标志 + 主线程 `finish` 收敛）。
private final class BroadcastAsyncStreamHandle: @unchecked Sendable {
    private let continuation: AsyncStream<(Sendable?, Connection)>.Continuation
    private let lock = NSLock()
    private var isFinished = false

    init(_ continuation: AsyncStream<(Sendable?, Connection)>.Continuation) {
        self.continuation = continuation
    }

    /// 在流终止时调用：幂等；`continuation.finish()` 派发到主队列以匹配 Webnat 的 MainActor 使用面。
    func finish() {
        var shouldFinish = false
        lock.lock()
        if !isFinished {
            isFinished = true
            shouldFinish = true
        }
        lock.unlock()
        guard shouldFinish else {
            return
        }
        let cont = continuation
        if Thread.isMainThread {
            cont.finish()
        } else {
            DispatchQueue.main.async {
                cont.finish()
            }
        }
    }

    /// 仅在 Main线程 / MainActor 上的 `onConnectionReceive` 调用。
    func yield(_ value: (Sendable?, Connection)) {
        lock.lock()
        let ended = isFinished
        lock.unlock()
        guard !ended else {
            return
        }
        continuation.yield(value)
    }
}

//
//  Connection.swift
//  Webnat
//
//  Created by Auhgnayuo on 2024/12/9.
//

import Foundation

/// 消息发送完成回调类型定义
///
/// 用于接收消息发送结果的回调类型，会在主线程上以 block 调用方式被执行。
///
/// - Parameter error: 发送失败时的错误信息，成功时为 `nil`
typealias SendCompletion = @MainActor @Sendable (Error?) -> Void

/// 消息发送函数类型定义
///
/// 用于封装实际的消息发送逻辑，会在主线程上以 block 调用方式被执行。
///
/// - Parameters:
///   - message: 要发送的消息，应该是可序列化的对象（通常是字典格式）
///   - completion: 发送完成回调，可选。成功时 `error` 为 `nil`，失败时包含错误信息
typealias SendMessage = @MainActor @Sendable (_ message: Message, _ completion: SendCompletion?) -> Void

/// Connection - 连接类
///
/// 表示 Native 与 Web 之间的单个连接。
///
/// 核心职责：
/// 1. 管理连接的生命周期状态
/// 2. 提供消息发送能力
/// 3. 关联 WKWebView 实例
/// 4. 携带连接的元数据（attributes）
///
/// 连接类型：
/// - 主框架连接：对应 Web 页面的主框架
/// - iframe 连接：对应 Web 页面中的 iframe
///
/// 每个 WKWebView 可以有多个连接（主框架 + 多个 iframe）
///
/// **并发**：实例仅在 MainActor 上创建与使用。公开监听器类型（如 `RawBlockListener`）带有 `@Sendable`，形参中的 `Connection` 必须满足 `Sendable` 约束，编译器才能通过；此处使用 `@unchecked Sendable` 是配合该类型系统的折中，**不表示**可以安全地传到任意并发域——仍须只在主线程、随 `Webnat` API 使用。

@MainActor
public class Connection: NSObject, @unchecked Sendable {
    /// 连接的唯一标识符
    ///
    /// 此 ID 由 Web 端生成，用于在消息传递中标识连接的来源和目标
    public let id: String

    /// 连接的元数据
    ///
    /// 在连接建立（open）时由 Web 端传递，包含连接的附加信息
    /// 例如：origin（来源）、isMainframe（是否为主框架）、frameInfo: WKFrameInfo
    public let attributes: [String: Any]?
    
    /// 当前连接的界面URL
    ///
    /// 在连接建立时当前的界面URL
    public let url: URL?
    /// 连接是否已关闭
    ///
    /// 当连接关闭后，发送消息会立即返回错误
    /// 仅 Connection 自身或内部 API 可修改其值，外部可只读
    public internal(set) var closed: Bool = false

    /// 消息发送函数
    ///
    /// 由创建 Connection 时注入，封装了实际的消息发送逻辑。
    /// 这个闭包通常负责实际与 Web 端通信的代码实现。
    private let sendMessage: SendMessage

    /// 初始化连接
    ///
    /// - Parameters:
    ///   - id: 连接 ID，由 Web 端生成，用于唯一标识一个连接
    ///   - attributes: 连接元数据，例如 source origin、frame 类型等，可以为 nil
    ///   - url: 当前界面的url
    ///   - sendMessage: 消息发送函数，负责具体实现消息发送逻辑的闭包
    init(id: String, attributes: [String: Any]?, url: URL?, sendMessage: @escaping SendMessage) {
        self.id = id
        self.attributes = attributes
        self.url = url
        self.sendMessage = sendMessage
        super.init()
    }

    /// 发送消息到 Web 端
    ///
    /// 如果连接已关闭，会立即通过 `completion` 返回错误，不会实际发送消息。
    /// 此方法是异步的，发送结果通过 `completion` 回调返回。
    ///
    /// - Parameters:
    ///   - message: 要发送的消息
    ///   - completion: 发送完成回调，可选。成功时 `error` 为 `nil`，失败时包含错误信息。
    ///     传 `nil` 表示不需要关注发送结果
    func send(_ message: Message, completion: SendCompletion? = nil) {
        if closed {
            // 如果连接已关闭，直接回调错误，不实际发送
            completion?(NSError.closed())
            return
        }
        // 通过注入的消息发送函数进行实际的消息发送
        sendMessage(message, completion)
    }
}

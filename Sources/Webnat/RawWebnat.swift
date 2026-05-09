//
//  RawWebnat.swift
//  Webnat
//
//  Created by Auhgnayuo on 2024/12/9.
//

import Foundation

/// 原始消息监听器类型定义
///
/// 用于监听原始消息的回调类型，监听函数会在主线程上以 block 调用方式被执行。
///
/// - Parameters:
///   - param: 接收到的消息体内容，可以是任意可序列化的对象，可选
///   - connection: 消息来源的连接对象
public typealias RawBlockListener = @MainActor @Sendable @convention(block) ( _ param: Sendable?, _ connection: Connection) -> Void

/// RawWebnat - 原始消息传递器
///
/// 提供最基础的消息发送和接收功能，不做任何额外处理。
///
/// **适用场景**：
/// - 简单的数据传输
/// - 不需要消息分类的场景
/// - 自定义消息格式的场景
///
/// **消息格式**：
/// - 使用 `Message` 类型，包含 `raw` 字段
/// - Message 格式：`{ from: string, to: string, raw: { param?: Sendable } }`
///
/// **特点**：
/// - 支持多个监听器同时监听
/// - 所有监听器都会收到相同的消息
/// - 消息体可以是任意可序列化的对象
///
/// - Note: 这是内部类，不应直接使用，应通过 `Webnat` 类的 API 访问
@MainActor
final class RawWebnat {

    /// 注册的监听器列表
    ///
    /// 保存所有已注册的原始消息监听器，当收到原始消息时会依次调用所有监听器。
    private var listeners: [RawBlockListener] = []

    /// 注册原始消息监听器
    ///
    /// 可以注册多个监听器，所有监听器都会收到相同的消息。
    /// 如果同一个监听器引用已存在，则先移除旧的再添加新的，避免重复。
    ///
    /// - Parameter listener: 消息监听回调，当收到原始消息时会被调用
    func on(listener: @escaping RawBlockListener) {
        // 移除已存在的相同监听器（如果有的话）
        listeners.removeAll(where: { existingListener in
            (existingListener as AnyObject) === (listener as AnyObject)
        })
        
        // 添加新的监听器
        listeners.append(listener)
    }
    
    /// 移除原始消息监听器
    ///
    /// 使用引用相等性（===）来匹配监听器，只有完全相同的引用才会被移除。
    ///
    /// - Parameter listener: 要移除的监听器（必须与注册时的引用完全相同）
    func off(listener: @escaping RawBlockListener) {
        listeners.removeAll { l in
            (l as AnyObject) === (listener as AnyObject)
        }
    }
    
    /// 发送原始消息到指定连接
    ///
    /// 使用 `Message` 类构造消息并发送到 Web 端。
    ///
    /// - Parameters:
    ///   - param: 消息体，可以是任意可序列化的对象（String、Int、Dictionary、Array 等）
    ///   - connection: 目标连接，如果连接已关闭则不会发送
    func raw(_ param: Sendable?, connection: Connection) {
        let message = Message.raw(to: connection.id, param: param)
        connection.send(message)
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
    /// 连接表由 `Webnat` 维护；此处为生命周期钩子，当前无额外逻辑。
    ///
    /// - Parameter connection: 已关闭的连接对象（Connection 实例）
    func onConnectionClose(connection: Connection) {
      
    }
    
    /// 接收到消息时的回调
    ///
    /// 当收到原始消息时，分发给所有注册的监听器。
    ///
    /// - Parameters:
    ///   - connection: 消息来源连接
    ///   - message: 接收到的消息（已解析的 `Message` 对象）
    func onConnectionReceive(connection: Connection, message: Message) {
        // 检查是否为 raw 消息
        guard let raw = message.raw else {
            return
        }
        
        // 分发给所有监听器
        let listeners = listeners
        for listener in listeners {
            listener(raw.param, connection)
        }
    }
}

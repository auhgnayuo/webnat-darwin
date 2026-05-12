//
//  Message.swift
//  Webnat
//
//  Created by Auhgnayuo on 2025/11/14.
//

import Foundation

/// 参数类型别名
///
/// 支持可序列化的数据类型，包括：
/// - 基本类型：`String`、`Int`、`Double`、`Bool`、`NSNull`
/// - 数组：`[Sendable]`
/// - 对象：`[String: Sendable]`
///
/// 用于消息的参数传递，支持嵌套结构。
public typealias Param = Sendable

/// 连接打开消息结构体
///
/// 用于建立连接时的初始化消息，可以携带初始化参数。
public struct Open {
    /// 可选的初始化参数，可以是任意可序列化的对象
    public let param: Sendable?
    
    public init(param: Sendable? = nil) {
        self.param = param
    }
}

/// 连接关闭消息结构体
///
/// 用于关闭连接时的消息，可以携带关闭原因等参数。
public struct Close {
    /// 可选的关闭参数（如关闭原因等），可以是任意可序列化的对象
    public let param: Sendable?
    
    public init(param: Sendable? = nil) {
        self.param = param
    }
}

/// 原始消息结构体
///
/// 用于发送任意原始数据，不经过任何特殊处理。
public struct Raw {
    /// 原始消息的参数数据，可以是任意可序列化的对象
    public let param: Sendable?
    
    public init(param: Sendable? = nil) {
        self.param = param
    }
}

/// 广播消息结构体
///
/// 用于向所有订阅者发送事件通知，支持事件名称和参数。
public struct Broadcast {
    /// 广播事件名称，用于标识不同的事件类型
    public let name: String
    /// 广播事件的参数数据，可以是任意可序列化的对象，可选
    public let param: Sendable?
    
    public init(name: String, param: Sendable? = nil) {
        self.name = name
        self.param = param
    }
}

/// 方法调用消息结构体
///
/// 用于远程方法调用（RPC），包含调用 ID、方法名和参数。
public struct Invoke {
    /// 调用 ID，用于匹配请求和响应，唯一标识一次方法调用
    public let id: String
    /// 要调用的方法名称
    public let method: String
    /// 方法调用的参数，可以是任意可序列化的对象，可选
    public let param: Sendable?
    
    public init(id: String, method: String, param: Sendable? = nil) {
        self.id = id
        self.method = method
        self.param = param
    }
}

/// 方法调用响应消息结构体
///
/// 用于返回方法调用的结果或错误，包含调用 ID、结果或错误信息。
public struct Reply {
    /// 调用 ID，用于匹配对应的请求
    public let id: String
    /// 方法调用的成功结果，可以是任意可序列化的对象（与 `error` 互斥）
    public let result: Sendable?
    /// 方法调用的错误信息，可以是任意可序列化的对象（与 `result` 互斥）
    public let error: Sendable?
    
    public init(id: String, result: Sendable? = nil, error: Sendable? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// 通知消息结构体
///
/// 用于在方法调用执行过程中向调用方发送进度通知或中间结果。
public struct Notify {
    /// 调用 ID，用于匹配对应的请求
    public let id: String
    /// 通知的参数数据，可以是任意可序列化的对象（如进度信息、中间结果等），可选
    public let param: Sendable?
    
    public init(id: String, param: Sendable? = nil) {
        self.id = id
        self.param = param
    }
}

/// 中止消息结构体
///
/// 用于取消正在执行的方法调用。
public struct Abort {
    /// 调用 ID，用于匹配要取消的请求
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
}

/// 消息类
///
/// 所有消息的统一格式，包含发送方、接收方和具体的消息类型。
/// 消息类型是互斥的，一条消息只能包含一种类型的消息体。
///
/// 支持的消息类型：
/// - `open`: 连接打开消息
/// - `close`: 连接关闭消息
/// - `raw`: 原始消息
/// - `broadcast`: 广播消息
/// - `invoke`: 方法调用消息
/// - `reply`: 方法调用响应消息
/// - `notify`: 通知消息
/// - `abort`: 中止消息
///
/// **并发**：实例仅在 MainActor 上创建与使用。内部 `SendMessage` 将 `Message` 作为 `@Sendable` 闭包参数类型，故标注 `@unchecked Sendable` 以满足 Swift 6 并发检查；**不表示**可跨隔离域随意传递，仍须随 `Webnat` / `Connection` 在主线程使用。
@MainActor
public class Message: @unchecked Sendable {
    /// Native 端的 UUID 标识符常量
    ///
    /// 用于标识消息来自 Native 端，值为 `"00000000-0000-0000-0000-000000000000"`。
    public static let NATIVE_UUID = "00000000-0000-0000-0000-000000000000"
    
    /// 消息魔数常量
    ///
    /// 用于验证消息格式，值为 `"WEBNAT"`。
    public static let MAGIC = "WEBNAT"
    
    /// 消息魔数，用于验证消息格式
    public let magic: String = Message.MAGIC
    
    /// 消息发送方的标识（连接 ID 或 `NATIVE_UUID`）
    public let from: String
    
    /// 消息接收方的标识（连接 ID 或 `NATIVE_UUID`）
    public let to: String
    
    /// 连接打开消息（与其他消息类型互斥）
    public let open: Open?
    
    /// 连接关闭消息（与其他消息类型互斥）
    public let close: Close?
    
    /// 原始消息（与其他消息类型互斥）
    public let raw: Raw?
    
    /// 广播消息（与其他消息类型互斥）
    public let broadcast: Broadcast?
    
    /// 方法调用消息（与其他消息类型互斥）
    public let invoke: Invoke?
    
    /// 方法调用响应消息（与其他消息类型互斥）
    public let reply: Reply?
    
    /// 通知消息（与其他消息类型互斥）
    public let notify: Notify?
    
    /// 中止消息（与其他消息类型互斥）
    public let abort: Abort?
    
    /// 初始化消息
    /// 
    /// - Parameters:
    ///   - from: 消息发送方的标识
    ///   - to: 消息接收方的标识
    ///   - open: 连接打开消息（与其他消息类型互斥）
    ///   - close: 连接关闭消息（与其他消息类型互斥）
    ///   - raw: 原始消息（与其他消息类型互斥）
    ///   - broadcast: 广播消息（与其他消息类型互斥）
    ///   - invoke: 方法调用消息（与其他消息类型互斥）
    ///   - reply: 方法调用响应消息（与其他消息类型互斥）
    ///   - notify: 通知消息（与其他消息类型互斥）
    ///   - abort: 中止消息（与其他消息类型互斥）
    public init(
        from: String,
        to: String,
        open: Open? = nil,
        close: Close? = nil,
        raw: Raw? = nil,
        broadcast: Broadcast? = nil,
        invoke: Invoke? = nil,
        reply: Reply? = nil,
        notify: Notify? = nil,
        abort: Abort? = nil
    ) {
        self.from = from
        self.to = to
        self.open = open
        self.close = close
        self.raw = raw
        self.broadcast = broadcast
        self.invoke = invoke
        self.reply = reply
        self.notify = notify
        self.abort = abort
    }
    
    // ==================== 连接管理 ====================
    
    /// 创建连接打开消息
    /// 
    /// - Parameters:
    ///   - from: 发送方标识
    ///   - param: 可选的初始化参数
    /// - Returns: Message 实例
    public static func open(from: String, param: Sendable? = nil) -> Message {
        return Message(from: from, to: Message.NATIVE_UUID, open: Open(param: param))
    }
    
    /// 创建连接关闭消息
    /// 
    /// - Parameters:
    ///   - from: 发送方标识
    ///   - param: 可选的关闭参数
    /// - Returns: Message 实例
    public static func close(from: String, param: Sendable? = nil) -> Message {
        return Message(from: from, to: Message.NATIVE_UUID, close: Close(param: param))
    }
    
    // ==================== Native 发送消息 ====================
    
    /// 创建 Native 发送的原始消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - param: 原始消息的参数数据
    /// - Returns: Message 实例
    public static func raw(to: String, param: Sendable? = nil) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, raw: Raw(param: param))
    }
    
    /// 创建 Native 发送的广播消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - name: 广播事件名称
    ///   - param: 广播事件的参数数据
    /// - Returns: Message 实例
    public static func broadcast(to: String, name: String, param: Sendable? = nil) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, broadcast: Broadcast(name: name, param: param))
    }
    
    /// 创建 Native 发送的方法调用消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - id: 调用 ID
    ///   - method: 方法名称
    ///   - param: 方法参数
    /// - Returns: Message 实例
    public static func invoke(to: String, id: String, method: String, param: Sendable? = nil) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, invoke: Invoke(id: id, method: method, param: param))
    }
    
    /// 创建 Native 发送的方法调用响应消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - id: 调用 ID
    ///   - result: 成功结果（与 error 互斥）
    ///   - error: 错误信息（与 result 互斥）
    /// - Returns: Message 实例
    public static func reply(to: String, id: String, result: Sendable? = nil, error: Sendable? = nil) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, reply: Reply(id: id, result: result, error: error))
    }
    
    /// 创建 Native 发送的通知消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - id: 调用 ID
    ///   - param: 通知的参数数据
    /// - Returns: Message 实例
    public static func notify(to: String, id: String, param: Sendable? = nil) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, notify: Notify(id: id, param: param))
    }
    
    /// 创建 Native 发送的中止消息
    /// 
    /// - Parameters:
    ///   - to: 接收方标识（连接 ID）
    ///   - id: 调用 ID
    /// - Returns: Message 实例
    public static func abort(to: String, id: String) -> Message {
        return Message(from: Message.NATIVE_UUID, to: to, abort: Abort(id: id))
    }
    
    // ==================== 序列化 ====================
    
    /// 将消息转换为字典格式（用于发送）
    ///
    /// 将 `Message` 对象转换为字典格式，便于序列化为 JSON 并发送到 Web 端。
    ///
    /// - Returns: 字典格式的消息，可以直接用于 JSON 序列化
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "magic": magic,
            "from": from,
            "to": to
        ]
        
        if let open = open {
            var openDict: [String: Any] = [:]
            if let param = open.param {
                openDict["param"] = param
            }
            dict["open"] = openDict
        }
        
        if let close = close {
            var closeDict: [String: Any] = [:]
            if let param = close.param {
                closeDict["param"] = param
            }
            dict["close"] = closeDict
        }
        
        if let raw = raw {
            var rawDict: [String: Any] = [:]
            if let param = raw.param {
                rawDict["param"] = param
            }
            dict["raw"] = rawDict
        }
        
        if let broadcast = broadcast {
            var broadcastDict: [String: Any] = ["name": broadcast.name]
            if let param = broadcast.param {
                broadcastDict["param"] = param
            }
            dict["broadcast"] = broadcastDict
        }
        
        if let invoke = invoke {
            var invokeDict: [String: Any] = [
                "id": invoke.id,
                "method": invoke.method
            ]
            if let param = invoke.param {
                invokeDict["param"] = param
            }
            dict["invoke"] = invokeDict
        }
        
        if let reply = reply {
            var replyDict: [String: Any] = ["id": reply.id]
            if let result = reply.result {
                replyDict["result"] = result
            }
            if let error = reply.error {
                replyDict["error"] = error
            }
            dict["reply"] = replyDict
        }
        
        if let notify = notify {
            var notifyDict: [String: Any] = ["id": notify.id]
            if let param = notify.param {
                notifyDict["param"] = param
            }
            dict["notify"] = notifyDict
        }
        
        if let abort = abort {
            dict["abort"] = ["id": abort.id]
        }
        
        return dict
    }

    /// `JSONSerialization` 等产生的 `Any?` 转为 `Sendable?`。
    ///
    /// 行为约定：
    /// - 输入为 `nil` 或缺失：返回 `nil`。
    /// - 输入为 `NSNull`：保留为 `NSNull()` 占位（语义上「显式 null」与「字段缺失」是不同的）。
    /// - 已识别的 JSON 基本类型：原样返回。
    /// - 集合内出现未识别的元素：**跳过**该元素（不再让整个集合失败）。
    /// - 顶层未识别类型：返回 `nil`。
    private static func sendable(fromJSON value: Any?) -> Sendable? {
        guard let value else { return nil }
        if value is NSNull { return NSNull() }
        return sendable(fromJSONObject: value)
    }

    private static func sendable(fromJSONObject value: Any) -> Sendable? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int64 as Int64:
            return int64
        case let uint as UInt:
            return uint
        case let double as Double:
            return double
        case let float as Float:
            return float
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number.doubleValue
        case let dict as [String: Any]:
            var out: [String: Sendable] = [:]
            out.reserveCapacity(dict.count)
            for (key, child) in dict {
                if let childSendable = sendable(fromJSON: child) {
                    out[key] = childSendable
                }
            }
            return out
        case let array as [Any]:
            var out: [Sendable] = []
            out.reserveCapacity(array.count)
            for child in array {
                if let childSendable = sendable(fromJSON: child) {
                    out.append(childSendable)
                }
            }
            return out
        case let dict as NSDictionary:
            guard let swiftDict = dict as? [String: Any] else { return nil }
            return sendable(fromJSONObject: swiftDict)
        case let array as NSArray:
            guard let swiftArray = array as? [Any] else { return nil }
            return sendable(fromJSONObject: swiftArray)
        default:
            return nil
        }
    }
    
    /// 从字典创建消息实例
    ///
    /// 从字典格式（通常来自 JSON 反序列化）创建 `Message` 对象。
    /// 如果字典格式无效（缺少必需字段、魔数不匹配等），则返回 `nil`。
    ///
    /// - Parameter dict: 字典格式的消息，通常来自 JSON 反序列化
    /// - Returns: `Message` 实例，如果字典格式无效则返回 `nil`
    public static func from(dict: [String: Any]) -> Message? {
        guard let magic = dict["magic"] as? String,
              magic == Message.MAGIC,
              let from = dict["from"] as? String,
              let to = dict["to"] as? String else {
            return nil
        }
        
        var open: Open?
        if let openDict = dict["open"] as? [String: Any] {
            open = Open(param: sendable(fromJSON: openDict["param"]))
        }
        
        var close: Close?
        if let closeDict = dict["close"] as? [String: Any] {
            close = Close(param: sendable(fromJSON: closeDict["param"]))
        }
        
        var raw: Raw?
        if let rawDict = dict["raw"] as? [String: Any] {
            raw = Raw(param: sendable(fromJSON: rawDict["param"]))
        }
        
        var broadcast: Broadcast?
        if let broadcastDict = dict["broadcast"] as? [String: Any],
           let name = broadcastDict["name"] as? String {
            broadcast = Broadcast(name: name, param: sendable(fromJSON: broadcastDict["param"]))
        }
        
        var invoke: Invoke?
        if let invokeDict = dict["invoke"] as? [String: Any],
           let id = invokeDict["id"] as? String,
           let method = invokeDict["method"] as? String {
            invoke = Invoke(id: id, method: method, param: sendable(fromJSON: invokeDict["param"]))
        }
        
        var reply: Reply?
        if let replyDict = dict["reply"] as? [String: Any],
           let id = replyDict["id"] as? String {
            reply = Reply(
                id: id,
                result: sendable(fromJSON: replyDict["result"]),
                error: sendable(fromJSON: replyDict["error"])
            )
        }
        
        var notify: Notify?
        if let notifyDict = dict["notify"] as? [String: Any],
           let id = notifyDict["id"] as? String {
            notify = Notify(id: id, param: sendable(fromJSON: notifyDict["param"]))
        }
        
        var abort: Abort?
        if let abortDict = dict["abort"] as? [String: Any],
           let id = abortDict["id"] as? String {
            abort = Abort(id: id)
        }
        
        return Message(
            from: from,
            to: to,
            open: open,
            close: close,
            raw: raw,
            broadcast: broadcast,
            invoke: invoke,
            reply: reply,
            notify: notify,
            abort: abort
        )
    }
}

//
//  BroadcastMethodCall.swift
//  Webnat
//
//  Created by Auhgnayuo on 2025/11/14.
//

import Foundation

/// BroadcastMethodCall - 广播式方法调用的竞赛协调器
///
/// 当 `Webnat.method` 未指定 `connection` 时，会把同一次方法调用**广播**给当前所有连接
/// （主框架 + 所有 iframe），并在这些子调用之间做「谁先返回用谁的」的竞赛裁决。
///
/// 典型使用场景是**透传 iframe**：正常情况下同一个方法只会有一个 frame 注册处理器，
/// 其余 frame 会立即回 `unimplemented`。协调器据此挑出真正实现该方法的 frame 作为结果来源。
///
/// ## 竞赛规则
///
/// 每个连接各自发起一次独立的单连接 RPC（各有独立的调用 ID，互不干扰），
/// 协调器根据它们的响应做出裁决：
///
/// - **胜者锁定**：第一个发来「有意义信号」的连接成为胜者，随后立即 `abort` 其余连接，
///   之后只透传胜者的 notify 与最终结果。
///   - 「有意义信号」= `notify`、成功 `reply`、或**真实业务错误**（错误码不是 `unimplemented`/`closed`）。
/// - **淘汰而非获胜**：`unimplemented(-1010)` 与 `closed(-1004)` 都不会「抢跑」成为胜者，
///   只是把该连接移出候选池。
///   - 当所有连接都被淘汰且从未出现胜者时，才最终失败：
///     若淘汰过程中出现过 `closed` 则返回 `closed`，否则返回 `unimplemented`。
/// - **已锁定的胜者中途失败**（如其连接关闭）：直接把该错误返回给调用方。
/// - **超时 / 取消**：作用于整组——`abort` 全部子调用，返回 `timeout` / `cancelled`。
///   子调用本身不设超时，超时统一由协调器组级管理。
///
/// - Note: 内部类，仅在 MainActor 上创建与使用。标注 `@unchecked Sendable` 以便被
///   `@Sendable` 的回调类型（如 `MethodCallback`）强引用捕获；**不表示**可跨隔离域使用。
@MainActor
final class BroadcastMethodCall: @unchecked Sendable {
    /// 被调用的方法名（仅用于构造最终的 `unimplemented` 错误信息）
    private let methodName: String
    /// 透传给调用方的通知回调（只透传胜者的 notify）
    private let userNotification: MethodOnNotification?
    /// 透传给调用方的完成回调（仅触发一次）
    private let userCallback: MethodCallback?
    /// 结束时的收尾钩子（如 JS 保活引用计数减一），保证与 `userCallback` 一样只触发一次
    private let onFinished: @MainActor () -> Void

    /// 是否已终结（终态到达后所有信号都被忽略）
    private var settled = false
    /// 胜者连接 ID；`nil` 表示尚未锁定胜者
    private var winnerId: String?
    /// 已被淘汰（回了 `unimplemented`/`closed`）的连接 ID 集合
    private var eliminated: Set<String> = []
    /// 淘汰过程中是否出现过 `closed`（决定候选池耗尽时返回哪种错误码）
    private var sawClosed = false
    /// 参与竞赛的连接总数（快照自发起时）
    private var total = 0
    /// 各子调用的取消句柄，key 为连接 ID；完成或被取消后从表中移除
    private var cancels: [String: MethodCancellation] = [:]
    /// 组级超时任务
    private var timeoutItem: DispatchWorkItem?

    /// 初始化协调器
    ///
    /// - Parameters:
    ///   - method: 方法名
    ///   - onNotification: 调用方的通知回调（可选）
    ///   - callback: 调用方的完成回调（可选）
    ///   - onFinished: 结束收尾钩子（只会被调用一次）
    init(
        method: String,
        onNotification: MethodOnNotification?,
        callback: MethodCallback?,
        onFinished: @escaping @MainActor () -> Void
    ) {
        self.methodName = method
        self.userNotification = onNotification
        self.userCallback = callback
        self.onFinished = onFinished
    }

    /// 启动广播调用
    ///
    /// - Parameters:
    ///   - connections: 参与竞赛的连接快照（发起时的所有连接）
    ///   - methodWebnat: 复用其单连接 RPC 能力
    ///   - param: 方法参数
    ///   - timeout: 组级超时（秒）；`nil`/非正数/非有限值均不注册超时
    /// - Returns: 取消函数，调用后 `abort` 全部子调用并以 `cancelled` 结束
    func start(
        connections: [Connection],
        methodWebnat: MethodWebnat,
        param: Sendable?,
        timeout: TimeInterval?
    ) -> MethodCancellation {
        total = connections.count

        // 没有任何连接：与旧的单连接行为一致，立即返回 closed
        if connections.isEmpty {
            finish(nil, NSError.closed())
            return {}
        }

        // 组级超时（子调用不再各自设置超时）
        if let timeout, timeout > 0, timeout.isFinite {
            let item = DispatchWorkItem { [weak self] in
                self?.finish(nil, NSError.timeout())
            }
            timeoutItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        // 对每个连接发起独立的单连接子调用
        for connection in connections {
            // 若在发起过程中已终结（如某连接同步 closed 触发全员淘汰，或真实错误抢跑），停止继续发起
            if settled {
                break
            }
            let connId = connection.id
            let cancel = methodWebnat.method(
                methodName,
                param: param,
                timeout: nil,
                onNotification: { param in
                    self.handleNotify(connId, param)
                },
                callback: { result, error in
                    self.handleComplete(connId, result, error)
                },
                connection: connection
            )
            if settled {
                // 该子调用在发起时已同步完成并触发了终结，取消句柄已无意义（幂等 no-op）
                cancel()
            } else {
                cancels[connId] = cancel
            }
        }

        return { [weak self] in
            self?.finish(nil, NSError.cancelled())
        }
    }

    /// 处理某连接的途中通知
    private func handleNotify(_ connId: String, _ param: Sendable?) {
        if settled {
            return
        }
        if let winnerId {
            // 已有胜者：只透传胜者的通知，落败者一律忽略
            if winnerId == connId {
                userNotification?(param)
            }
            return
        }
        // 尚无胜者：该连接凭「首个有意义信号」锁定为胜者
        winnerId = connId
        cancelLosers(except: connId)
        userNotification?(param)
    }

    /// 处理某连接的最终完成（成功或错误）
    private func handleComplete(_ connId: String, _ result: Sendable?, _ error: Error?) {
        if settled {
            return
        }
        // 该子调用已完成，从取消表中移除
        cancels.removeValue(forKey: connId)

        if let winnerId {
            if winnerId == connId {
                // 已锁定的胜者产出终态：直接作为最终结果
                finish(result, error)
            }
            // 落败者的迟到消息：忽略
            return
        }

        // 尚无胜者
        if let error, isEliminating(error) {
            eliminated.insert(connId)
            if (error as NSError).code == WebnatErrorCode.closed {
                sawClosed = true
            }
            // 全部连接都被淘汰且从未出现胜者：兜底失败
            if eliminated.count >= total {
                finish(nil, sawClosed ? NSError.closed() : NSError.unimplemented(methodName))
            }
            return
        }

        // 成功或真实业务错误：该连接抢跑获胜并直接终结
        winnerId = connId
        cancelLosers(except: connId)
        finish(result, error)
    }

    /// 判断错误是否属于「淘汰类」（不抢跑、不获胜，只移出候选池）
    private func isEliminating(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == WebnatErrorCode.unimplemented || code == WebnatErrorCode.closed
    }

    /// 取消除 `except` 外的所有子调用（给落败 frame 发 abort）
    private func cancelLosers(except: String) {
        let losers = cancels.filter { $0.key != except }
        for id in losers.keys {
            cancels.removeValue(forKey: id)
        }
        // 先从表中移除再逐个取消：取消可能同步回调 handleComplete，避免重入时重复处理
        for cancel in losers.values {
            cancel()
        }
    }

    /// 终结整组调用：幂等，仅触发一次用户回调与收尾钩子
    private func finish(_ result: Sendable?, _ error: Error?) {
        if settled {
            return
        }
        settled = true
        timeoutItem?.cancel()
        timeoutItem = nil
        // 取消所有剩余子调用（胜者的已完成，取消为 no-op；落败者收到 abort）
        let remaining = cancels
        cancels.removeAll()
        for cancel in remaining.values {
            cancel()
        }
        userCallback?(result, error)
        onFinished()
    }
}

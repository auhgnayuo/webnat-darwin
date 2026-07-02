//
//  WebnatTests.swift
//  Webnat
//
//  Created by auhgnayuo on 2025/11/14.
//

import XCTest
import WebKit
@testable import Webnat

// MARK: - Message serialization

@MainActor
final class MessageSerializationTests: XCTestCase {
    func testOpenRoundTrip() {
        let original = Message.open(from: "conn-a", param: ["n": 42, "s": "hi"])
        let dict = original.toDictionary()
        let parsed = Message.from(dict: dict)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.from, "conn-a")
        XCTAssertNotNil(parsed?.open)
    }

    func testCloseRoundTrip() {
        let original = Message.close(from: "conn-a", param: ["reason": "bye"])
        XCTAssertNotNil(Message.from(dict: original.toDictionary()))
    }

    func testRawRoundTrip() {
        let original = Message.raw(to: "conn-a", param: ["x": true])
        let parsed = Message.from(dict: original.toDictionary())
        XCTAssertNotNil(parsed?.raw)
    }

    func testBroadcastRoundTrip() {
        let original = Message.broadcast(to: "conn-a", name: "evt", param: [1, 2])
        let parsed = Message.from(dict: original.toDictionary())
        XCTAssertEqual(parsed?.broadcast?.name, "evt")
    }

    func testInvokeReplyNotifyAbortRoundTrip() {
        let invoke = Message.invoke(to: "peer", id: "i1", method: "m", param: ["k": "v"])
        XCTAssertNotNil(Message.from(dict: invoke.toDictionary())?.invoke)

        let reply = Message.reply(to: "peer", id: "i1", result: "ok")
        XCTAssertNotNil(Message.from(dict: reply.toDictionary())?.reply)

        let replyErr = Message.reply(to: "peer", id: "i1", error: NSError.unimplemented("x").toJson())
        XCTAssertNotNil(Message.from(dict: replyErr.toDictionary())?.reply?.error)

        let notify = Message.notify(to: "peer", id: "i1", param: 10)
        XCTAssertNotNil(Message.from(dict: notify.toDictionary())?.notify)

        let abort = Message.abort(to: "peer", id: "i1")
        XCTAssertNotNil(Message.from(dict: abort.toDictionary())?.abort)
    }

    func testFromRejectsWrongMagic() {
        var dict = Message.open(from: "x").toDictionary()
        dict["magic"] = "NOPE"
        XCTAssertNil(Message.from(dict: dict))
    }

    func testFromRejectsMissingFields() {
        XCTAssertNil(Message.from(dict: ["magic": Message.MAGIC]))
    }
}

// MARK: - MethodWebnat (mock Connection)

@MainActor
final class MethodWebnatTests: XCTestCase {
    private func makePeerConnection(
        id: String = "peer-1",
        onOutgoing: ((Message) -> Void)? = nil
    ) -> Connection {
        Connection(id: id, attributes: nil, url: nil) { message, completion in
            onOutgoing?(message)
            completion?(nil)
        }
    }

    func testNilConnectionCompletesWithClosed() {
        let rpc = MethodWebnat()
        let exp = expectation(description: "closed")
        _ = rpc.method(
            "any",
            param: nil,
            timeout: nil,
            onNotification: nil,
            callback: { _, error in
                XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.closed)
                exp.fulfill()
            },
            connection: nil
        )
        wait(for: [exp], timeout: 1)
    }

    func testRPCSuccessDeliversResult() {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            if let inv = outgoing.invoke {
                let reply = Message(
                    from: conn.id,
                    to: Message.NATIVE_UUID,
                    reply: Reply(id: inv.id, result: 99)
                )
                rpc.onConnectionReceive(connection: conn, message: reply)
            }
        }
        let exp = expectation(description: "result")
        _ = rpc.method(
            "add",
            param: nil,
            timeout: nil,
            onNotification: nil,
            callback: { result, error in
                XCTAssertNil(error)
                XCTAssertEqual(result as? Int, 99)
                exp.fulfill()
            },
            connection: conn
        )
        wait(for: [exp], timeout: 1)
    }

    func testRPCTimeout() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in
            // 故意不回复
        }
        let exp = expectation(description: "timeout")
        _ = rpc.method(
            "hang",
            param: nil,
            timeout: 0.2,
            onNotification: nil,
            callback: { _, error in
                XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.timeout)
                exp.fulfill()
            },
            connection: conn
        )
        wait(for: [exp], timeout: 2)
    }

    func testRPCUserCancel() {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            guard let inv = outgoing.invoke else { return }
            let invokeId = inv.id
            // 延迟回复，便于先 cancel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let reply = Message(
                    from: conn.id,
                    to: Message.NATIVE_UUID,
                    reply: Reply(id: invokeId, result: "late")
                )
                rpc.onConnectionReceive(connection: conn, message: reply)
            }
        }
        let exp = expectation(description: "cancelled")
        let cancel = rpc.method(
            "slow",
            param: nil,
            timeout: 10,
            onNotification: nil,
            callback: { _, error in
                XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.cancelled)
                exp.fulfill()
            },
            connection: conn
        )
        cancel()
        wait(for: [exp], timeout: 1)
    }

    func testUnimplementedNativeMethodSendsReply() {
        let rpc = MethodWebnat()
        var last: Message?
        var conn: Connection!
        conn = makePeerConnection(id: "p2") { msg in
            last = msg
        }
        let inv = Invoke(id: "rid", method: "missing", param: nil)
        let incoming = Message(from: conn.id, to: Message.NATIVE_UUID, invoke: inv)
        rpc.onConnectionReceive(connection: conn, message: incoming)
        XCTAssertNotNil(last?.reply)
        XCTAssertEqual(last?.reply?.id, "rid")
        XCTAssertNotNil(last?.reply?.error)
    }

    func testNotifyDelivered() {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            if let inv = outgoing.invoke {
                let note = Message(
                    from: conn.id,
                    to: Message.NATIVE_UUID,
                    notify: Notify(id: inv.id, param: "p")
                )
                rpc.onConnectionReceive(connection: conn, message: note)
                let reply = Message(
                    from: conn.id,
                    to: Message.NATIVE_UUID,
                    reply: Reply(id: inv.id, result: 0)
                )
                rpc.onConnectionReceive(connection: conn, message: reply)
            }
        }
        let expNotify = expectation(description: "notify")
        let expDone = expectation(description: "done")
        _ = rpc.method(
            "m",
            param: nil,
            timeout: nil,
            onNotification: { p in
                XCTAssertEqual(p as? String, "p")
                expNotify.fulfill()
            },
            callback: { _, error in
                XCTAssertNil(error)
                expDone.fulfill()
            },
            connection: conn
        )
        wait(for: [expNotify, expDone], timeout: 1, enforceOrder: true)
    }

    func testUnknownReplyIdIsIgnored() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in
            XCTFail("不应因未知 reply id 向连接发消息")
        }
        let reply = Message(from: conn.id, to: Message.NATIVE_UUID, reply: Reply(id: "no-such-invoke", result: 1))
        rpc.onConnectionReceive(connection: conn, message: reply)
    }

    func testUnknownNotifyIdDoesNotCrash() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in }
        let note = Message(from: conn.id, to: Message.NATIVE_UUID, notify: Notify(id: "ghost", param: "x"))
        rpc.onConnectionReceive(connection: conn, message: note)
    }

    func testDoubleNativeCallbackSendsSingleReply() {
        let rpc = MethodWebnat()
        var outgoing: [Message] = []
        var conn: Connection!
        conn = makePeerConnection { outgoing.append($0) }
        rpc.on(name: "dup") { _, callback, _, _ in
            callback(1, nil)
            callback(2, nil)
            return {}
        }
        let inv = Invoke(id: "rid", method: "dup", param: nil)
        let incoming = Message(from: conn.id, to: Message.NATIVE_UUID, invoke: inv)
        rpc.onConnectionReceive(connection: conn, message: incoming)
        let replies = outgoing.compactMap(\.reply)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.result as? Int, 1)
    }

    func testTimeoutZeroMeansNoTimerStillCompletesOnReply() {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            guard let inv = outgoing.invoke else { return }
            let reply = Message(
                from: conn.id,
                to: Message.NATIVE_UUID,
                reply: Reply(id: inv.id, result: "ok")
            )
            rpc.onConnectionReceive(connection: conn, message: reply)
        }
        let exp = expectation(description: "done")
        _ = rpc.method(
            "m",
            param: nil,
            timeout: 0,
            onNotification: nil,
            callback: { result, error in
                XCTAssertNil(error)
                XCTAssertEqual(result as? String, "ok")
                exp.fulfill()
            },
            connection: conn
        )
        wait(for: [exp], timeout: 1)
    }

    func testNonFiniteTimeoutDoesNotUseTimer() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in }
        let exp = expectation(description: "no timeout path")
        exp.isInverted = true
        _ = rpc.method(
            "hang",
            param: nil,
            timeout: .infinity,
            onNotification: nil,
            callback: { _, error in
                if (error as NSError?)?.code == WebnatErrorCode.timeout {
                    exp.fulfill()
                }
            },
            connection: conn
        )
        wait(for: [exp], timeout: 0.25)
    }

    func testRegisterMethodReplacesPrevious() {
        let rpc = MethodWebnat()
        var first = 0
        var second = 0
        rpc.on(name: "x") { _, callback, _, _ in
            first += 1
            callback(1, nil)
            return {}
        }
        rpc.on(name: "x") { _, callback, _, _ in
            second += 1
            callback(2, nil)
            return {}
        }
        var last: Message?
        var conn: Connection!
        conn = makePeerConnection { last = $0 }
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, invoke: Invoke(id: "i", method: "x", param: nil)))
        XCTAssertEqual(first, 0, "前一个 listener 应已被覆盖，不应再被调用")
        XCTAssertEqual(second, 1)
        XCTAssertEqual(last?.reply?.result as? Int, 2)
    }

    func testOffMethodMakesNextInvokeUnimplemented() {
        let rpc = MethodWebnat()
        let listener: MethodBlockListener = { _, callback, _, _ in
            callback("nope", nil)
            return {}
        }
        rpc.on(name: "y", listener: listener)
        rpc.off(name: "y", listener: listener)
        var last: Message?
        var conn: Connection!
        conn = makePeerConnection { last = $0 }
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, invoke: Invoke(id: "i", method: "y", param: nil)))
        XCTAssertNotNil(last?.reply?.error)
    }

    func testWebSideAbortInvokesNativeHandlerCancellation() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in }
        var cancelled = false
        rpc.on(name: "long") { _, _, _, _ in
            return { cancelled = true }
        }
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, invoke: Invoke(id: "rid", method: "long", param: nil)))
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, abort: Abort(id: "rid")))
        XCTAssertTrue(cancelled)
    }

    func testConnectionCloseDuringPendingRPCDeliversClosedError() {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in /* 不回复 */ }
        let exp = expectation(description: "closed")
        _ = rpc.method(
            "x",
            param: nil,
            timeout: nil,
            onNotification: nil,
            callback: { _, error in
                XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.closed)
                exp.fulfill()
            },
            connection: conn
        )
        rpc.onConnectionClose(connection: conn)
        wait(for: [exp], timeout: 1)
    }

    func testSendErrorFromConnectionForwardsToCallback() {
        let rpc = MethodWebnat()
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, completion in
            completion?(NSError(domain: "X", code: 42, userInfo: nil))
        }
        let exp = expectation(description: "send err")
        _ = rpc.method(
            "x",
            param: nil,
            timeout: nil,
            onNotification: nil,
            callback: { _, error in
                XCTAssertEqual((error as NSError?)?.code, 42)
                exp.fulfill()
            },
            connection: conn
        )
        wait(for: [exp], timeout: 1)
    }

    func testNotifyAfterCompletionIsDropped() {
        let rpc = MethodWebnat()
        var outgoing: [Message] = []
        var conn: Connection!
        conn = makePeerConnection { outgoing.append($0) }
        rpc.on(name: "n") { _, callback, notify, _ in
            callback(1, nil)
            notify("late")
            return {}
        }
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, invoke: Invoke(id: "ii", method: "n", param: nil)))
        let notifies = outgoing.compactMap(\.notify)
        XCTAssertEqual(notifies.count, 0, "已完成后再次 notify 不应外发消息")
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testAsyncOverloadSuccess() async throws {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            guard let inv = outgoing.invoke else { return }
            Task { @MainActor in
                rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, reply: Reply(id: inv.id, result: 7)))
            }
        }
        let result = try await rpc.method("x", connection: conn)
        XCTAssertEqual(result as? Int, 7)
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testAsyncOverloadThrowsOnReplyError() async {
        let rpc = MethodWebnat()
        var conn: Connection!
        conn = makePeerConnection { outgoing in
            guard let inv = outgoing.invoke else { return }
            Task { @MainActor in
                rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, reply: Reply(id: inv.id, error: NSError.unimplemented("x").toJson())))
            }
        }
        do {
            _ = try await rpc.method("x", connection: conn)
            XCTFail("应抛出错误")
        } catch let e as NSError {
            XCTAssertEqual(e.code, WebnatErrorCode.unimplemented)
        }
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testAsyncOverloadCancelledViaTaskCancel() async {
        let rpc = MethodWebnat()
        let conn = makePeerConnection { _ in /* 不回复 */ }
        let task = Task { @MainActor () -> Sendable? in
            do {
                return try await rpc.method("hang", connection: conn)
            } catch {
                XCTAssertEqual((error as NSError).code, WebnatErrorCode.cancelled)
                return nil as Sendable?
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testAsyncOverloadNilConnectionThrowsClosed() async {
        let rpc = MethodWebnat()
        do {
            _ = try await rpc.method("x", connection: nil)
            XCTFail("应抛错")
        } catch let e as NSError {
            XCTAssertEqual(e.code, WebnatErrorCode.closed)
        }
    }
}

// MARK: - BroadcastMethodCall (广播竞赛协调器)

@MainActor
final class BroadcastMethodCallTests: XCTestCase {
    /// 记录某连接发出的所有消息
    private final class Recorder {
        var messages: [Message] = []
    }

    /// 构造一个 mock 连接：记录出站消息，并可在收到 invoke 时回调
    private func makeConn(
        id: String,
        recorder: Recorder,
        onInvoke: ((Invoke, Connection) -> Void)? = nil
    ) -> Connection {
        var conn: Connection!
        conn = Connection(id: id, attributes: nil, url: nil) { message, completion in
            recorder.messages.append(message)
            if let inv = message.invoke {
                onInvoke?(inv, conn)
            }
            completion?(nil)
        }
        return conn
    }

    private func reply(_ rpc: MethodWebnat, _ conn: Connection, id: String, result: Sendable? = nil, error: Sendable? = nil) {
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, reply: Reply(id: id, result: result, error: error)))
    }

    private func notify(_ rpc: MethodWebnat, _ conn: Connection, id: String, param: Sendable?) {
        rpc.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, notify: Notify(id: id, param: param)))
    }

    private func makeCall(
        method: String = "m",
        onNotification: MethodOnNotification? = nil,
        callback: MethodCallback? = nil
    ) -> BroadcastMethodCall {
        BroadcastMethodCall(method: method, onNotification: onNotification, callback: callback, onFinished: {})
    }

    func testEmptyConnectionsReturnsClosed() {
        let rpc = MethodWebnat()
        let exp = expectation(description: "closed")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.closed)
            exp.fulfill()
        })
        _ = call.start(connections: [], methodWebnat: rpc, param: nil, timeout: nil)
        wait(for: [exp], timeout: 1)
    }

    func testSuccessFromImplementerAmongUnimplemented() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        // conn1 未实现：稍早回 unimplemented
        let conn1 = makeConn(id: "c1", recorder: r1) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.reply(rpc, conn, id: inv.id, error: NSError.unimplemented("m").toJson())
            }
        }
        // conn2 实现：稍晚回结果
        let conn2 = makeConn(id: "c2", recorder: r2) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                self.reply(rpc, conn, id: inv.id, result: 42)
            }
        }
        let exp = expectation(description: "result")
        let call = makeCall(callback: { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Int, 42)
            exp.fulfill()
        })
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        wait(for: [exp], timeout: 2)
    }

    func testAllUnimplementedReturnsUnimplemented() {
        let rpc = MethodWebnat()
        let r = Recorder()
        let mk: (String) -> Connection = { id in
            self.makeConn(id: id, recorder: r) { inv, conn in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self.reply(rpc, conn, id: inv.id, error: NSError.unimplemented("m").toJson())
                }
            }
        }
        let exp = expectation(description: "unimpl")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.unimplemented)
            exp.fulfill()
        })
        _ = call.start(connections: [mk("c1"), mk("c2"), mk("c3")], methodWebnat: rpc, param: nil, timeout: nil)
        wait(for: [exp], timeout: 2)
    }

    func testNotifyForwardedFromWinnerAndLosersAborted() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        // conn1 胜者：先 notify，稍后 reply
        let conn1 = makeConn(id: "c1", recorder: r1) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.notify(rpc, conn, id: inv.id, param: "p")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.reply(rpc, conn, id: inv.id, result: 1)
            }
        }
        // conn2 落败：从不主动回复，等待被 abort
        let conn2 = makeConn(id: "c2", recorder: r2)
        let expNotify = expectation(description: "notify")
        let expDone = expectation(description: "done")
        let call = makeCall(
            onNotification: { p in
                XCTAssertEqual(p as? String, "p")
                expNotify.fulfill()
            },
            callback: { result, error in
                XCTAssertNil(error)
                XCTAssertEqual(result as? Int, 1)
                expDone.fulfill()
            }
        )
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        wait(for: [expNotify, expDone], timeout: 2, enforceOrder: true)
        XCTAssertTrue(r2.messages.contains { $0.abort != nil }, "落败连接应收到 abort")
    }

    func testGroupTimeout() {
        let rpc = MethodWebnat()
        let r = Recorder()
        // 两个连接都不回复
        let conn1 = makeConn(id: "c1", recorder: r)
        let conn2 = makeConn(id: "c2", recorder: r)
        let exp = expectation(description: "timeout")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.timeout)
            exp.fulfill()
        })
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: 0.2)
        wait(for: [exp], timeout: 2)
    }

    func testRealErrorWins() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        let conn1 = makeConn(id: "c1", recorder: r1) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                self.reply(rpc, conn, id: inv.id, error: NSError(domain: WebnatErrorDomain, code: 123, userInfo: [NSLocalizedDescriptionKey: "boom"]).toJson())
            }
        }
        let conn2 = makeConn(id: "c2", recorder: r2) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.reply(rpc, conn, id: inv.id, error: NSError.unimplemented("m").toJson())
            }
        }
        let exp = expectation(description: "real error")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, 123)
            exp.fulfill()
        })
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        wait(for: [exp], timeout: 2)
    }

    func testClosedAmongUnimplementedReturnsClosed() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        // conn1 不回复，稍后由外部触发连接关闭 → closed
        let conn1 = makeConn(id: "c1", recorder: r1)
        // conn2 未实现
        let conn2 = makeConn(id: "c2", recorder: r2) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.reply(rpc, conn, id: inv.id, error: NSError.unimplemented("m").toJson())
            }
        }
        let exp = expectation(description: "closed")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.closed)
            exp.fulfill()
        })
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            rpc.onConnectionClose(connection: conn1)
        }
        wait(for: [exp], timeout: 2)
    }

    func testUserCancelAbortsAllAndReturnsCancelled() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        let conn1 = makeConn(id: "c1", recorder: r1)
        let conn2 = makeConn(id: "c2", recorder: r2)
        let exp = expectation(description: "cancelled")
        let call = makeCall(callback: { _, error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.cancelled)
            exp.fulfill()
        })
        let cancel = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        cancel()
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(r1.messages.contains { $0.abort != nil }, "取消后 conn1 应收到 abort")
        XCTAssertTrue(r2.messages.contains { $0.abort != nil }, "取消后 conn2 应收到 abort")
    }

    func testSingleCallbackEvenWithLateLoserReply() {
        let rpc = MethodWebnat()
        let r1 = Recorder()
        let r2 = Recorder()
        // conn1 胜者，快速成功
        let conn1 = makeConn(id: "c1", recorder: r1) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.reply(rpc, conn, id: inv.id, result: "win")
            }
        }
        // conn2 落败者，迟到才回复（被 abort 后仍尝试回复，应被忽略）
        let conn2 = makeConn(id: "c2", recorder: r2) { inv, conn in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.reply(rpc, conn, id: inv.id, result: "late")
            }
        }
        var callbackCount = 0
        var finalResult: Sendable?
        let call = makeCall(callback: { result, _ in
            callbackCount += 1
            finalResult = result
        })
        _ = call.start(connections: [conn1, conn2], methodWebnat: rpc, param: nil, timeout: nil)
        let exp = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(callbackCount, 1, "只应回调一次")
        XCTAssertEqual(finalResult as? String, "win")
    }
}

// MARK: - Message edge cases

@MainActor
final class MessageEdgeCaseTests: XCTestCase {
    func testEmptyStringFromStillParsesWithBroadcast() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "",
            "to": Message.NATIVE_UUID,
            "broadcast": ["name": "e"],
        ]
        let m = Message.from(dict: dict)
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.broadcast?.name, "e")
    }

    func testReplyWithBothResultAndErrorRoundTrip() {
        let m = Message(from: "p", to: Message.NATIVE_UUID, reply: Reply(id: "r", result: 1, error: "e"))
        let parsed = Message.from(dict: m.toDictionary())
        XCTAssertNotNil(parsed?.reply)
        XCTAssertEqual(parsed?.reply?.result as? Int, 1)
        XCTAssertNotNil(parsed?.reply?.error)
    }

    func testFromRejectsBadMagicType() {
        let dict: [String: Any] = [
            "magic": 123,
            "from": "a",
            "to": "b",
        ]
        XCTAssertNil(Message.from(dict: dict))
    }
}

// MARK: - Connection

@MainActor
final class ConnectionTests: XCTestCase {
    func testSendWhenClosedCompletesWithClosedError() {
        let exp = expectation(description: "closed")
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, _ in
            XCTFail("不应调用底层 send")
        }
        conn.closed = true
        conn.send(Message.raw(to: "c", param: 1)) { error in
            XCTAssertEqual((error as NSError?)?.code, WebnatErrorCode.closed)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testSendForwardsCompletionFromUnderlying() {
        let exp = expectation(description: "sent")
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
        conn.send(Message.raw(to: "c", param: nil)) { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testSendForwardsErrorFromUnderlying() {
        let exp = expectation(description: "err")
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, completion in
            completion?(NSError(domain: "X", code: 9, userInfo: nil))
        }
        conn.send(Message.raw(to: "c", param: nil)) { error in
            XCTAssertEqual((error as NSError?)?.code, 9)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - RawWebnat

@MainActor
final class RawWebnatTests: XCTestCase {
    func testMultipleListenersAllReceive() {
        let raw = RawWebnat()
        let conn = Connection(id: "c1", attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
        var a = 0
        var b = 0
        let la: RawBlockListener = { _, _ in a += 1 }
        let lb: RawBlockListener = { _, _ in b += 1 }
        raw.on(listener: la)
        raw.on(listener: lb)
        let msg = Message(from: "c1", to: Message.NATIVE_UUID, raw: Raw(param: "x"))
        raw.onConnectionReceive(connection: conn, message: msg)
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 1)
    }

    func testOffRemovesListener() {
        let raw = RawWebnat()
        let conn = Connection(id: "c1", attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
        var count = 0
        let l: RawBlockListener = { _, _ in count += 1 }
        raw.on(listener: l)
        raw.off(listener: l)
        raw.onConnectionReceive(connection: conn, message: Message(from: "c1", to: Message.NATIVE_UUID, raw: Raw(param: nil)))
        XCTAssertEqual(count, 0)
    }

    func testDuplicateOnSameListenerDedupes() {
        let raw = RawWebnat()
        let conn = Connection(id: "c1", attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
        var count = 0
        let l: RawBlockListener = { _, _ in count += 1 }
        raw.on(listener: l)
        raw.on(listener: l)
        raw.onConnectionReceive(connection: conn, message: Message(from: "c1", to: Message.NATIVE_UUID, raw: Raw(param: nil)))
        XCTAssertEqual(count, 1, "同一引用重复 on 应只保留一条")
    }

    func testIgnoresNonRawMessage() {
        let raw = RawWebnat()
        let conn = Connection(id: "c1", attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
        var count = 0
        raw.on(listener: { _, _ in count += 1 })
        raw.onConnectionReceive(connection: conn, message: Message(from: "c1", to: Message.NATIVE_UUID, broadcast: Broadcast(name: "x", param: nil)))
        XCTAssertEqual(count, 0)
    }
}

// MARK: - BroadcastWebnat

@MainActor
final class BroadcastWebnatTests: XCTestCase {
    private func makeConn(id: String = "c1") -> Connection {
        Connection(id: id, attributes: nil, url: nil) { _, completion in
            completion?(nil)
        }
    }

    private func broadcastMessage(conn: Connection, name: String, param: Sendable?) -> Message {
        Message(from: conn.id, to: Message.NATIVE_UUID, broadcast: Broadcast(name: name, param: param))
    }

    func testBlockListenerReceivesParamAndConnection() {
        let b = BroadcastWebnat()
        let conn = makeConn()
        let exp = expectation(description: "recv")
        let listener: BroadcastBlockListener = { param, c in
            XCTAssertEqual(c.id, conn.id)
            XCTAssertEqual(param as? String, "hi")
            exp.fulfill()
        }
        b.on(name: "evt", listener: listener)
        b.onConnectionReceive(connection: conn, message: broadcastMessage(conn: conn, name: "evt", param: "hi"))
        wait(for: [exp], timeout: 1)
    }

    func testDuplicateOnSameBlockReferenceDedupes() {
        let b = BroadcastWebnat()
        let conn = makeConn()
        var count = 0
        let listener: BroadcastBlockListener = { _, _ in count += 1 }
        b.on(name: "e", listener: listener)
        b.on(name: "e", listener: listener)
        b.onConnectionReceive(connection: conn, message: broadcastMessage(conn: conn, name: "e", param: nil))
        XCTAssertEqual(count, 1, "同一引用重复 on 应只保留一条")
    }

    func testOffRemovesBlockListener() {
        let b = BroadcastWebnat()
        let conn = makeConn()
        var count = 0
        let listener: BroadcastBlockListener = { _, _ in count += 1 }
        b.on(name: "e", listener: listener)
        b.off(name: "e", listener: listener)
        b.onConnectionReceive(connection: conn, message: broadcastMessage(conn: conn, name: "e", param: nil))
        XCTAssertEqual(count, 0)
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testListenReceivesValueWhenProducerRunsAfterAwaitStarts() async {
        let b = BroadcastWebnat()
        let conn = makeConn()
        let stream = b.listen(name: "topic")
        var it = stream.makeAsyncIterator()
        let producer = Task { @MainActor in
            b.onConnectionReceive(connection: conn, message: self.broadcastMessage(conn: conn, name: "topic", param: 42))
        }
        let first = await it.next()
        _ = await producer.value
        XCTAssertEqual(first?.0 as? Int, 42)
        XCTAssertEqual(first?.1.id, conn.id)
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testListenCancelThenBroadcastDoesNotDeadlock() async {
        let b = BroadcastWebnat()
        let conn = makeConn()
        let stream = b.listen(name: "t2")
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }
        consumer.cancel()
        await Task.yield()
        b.onConnectionReceive(connection: conn, message: broadcastMessage(conn: conn, name: "t2", param: 1))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let received = await consumer.value
        XCTAssertLessThanOrEqual(
            received,
            1,
            "取消后 AsyncStream 与 onConnectionReceive 存在竞态时，当前实现至多再投递一次；若业务要求严格 0 次，需要再收紧实现或单独约定。"
        )
    }

    func testIgnoresNonBroadcastMessage() {
        let b = BroadcastWebnat()
        let conn = makeConn()
        var count = 0
        b.on(name: "e", listener: { _, _ in count += 1 })
        b.onConnectionReceive(connection: conn, message: Message(from: conn.id, to: Message.NATIVE_UUID, raw: Raw(param: nil)))
        XCTAssertEqual(count, 0)
    }

    @available(iOS 13.0, macOS 10.15, *)
    func testTwoListenStreamsBothReceive() async {
        let b = BroadcastWebnat()
        let conn = makeConn()
        let s1 = b.listen(name: "fan")
        let s2 = b.listen(name: "fan")
        var it1 = s1.makeAsyncIterator()
        var it2 = s2.makeAsyncIterator()
        Task { @MainActor in
            b.onConnectionReceive(connection: conn, message: self.broadcastMessage(conn: conn, name: "fan", param: 7))
        }
        let v1 = await it1.next()
        let v2 = await it2.next()
        XCTAssertEqual(v1?.0 as? Int, 7)
        XCTAssertEqual(v2?.0 as? Int, 7)
    }
}

// MARK: - JavaScriptAliveKeeper

@MainActor
final class JavaScriptAliveKeeperTests: XCTestCase {
    func testReferenceCountStartsTimerAndStops() {
        var beats = 0
        let keeper = JavaScriptAliveKeeper(timerInterval: 0.05) {
            beats += 1
        }
        keeper.heartbeatInterval = 0.12
        keeper.increaseReference()
        let exp = expectation(description: "beat at least once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            XCTAssertGreaterThanOrEqual(beats, 1, "若 CI 极慢可调大等待；失败则可能是主线程定时器未触发")
            keeper.decreaseReference()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testHeartbeatIntervalPositiveChange() {
        let keeper = JavaScriptAliveKeeper(timerInterval: 0.1) {}
        keeper.heartbeatInterval = 2.5
        XCTAssertEqual(keeper.heartbeatInterval, 2.5, accuracy: 0.0001)
    }

    func testZeroReferencesNoHeartbeat() {
        var beats = 0
        let keeper = JavaScriptAliveKeeper(timerInterval: 0.05) { beats += 1 }
        keeper.heartbeatInterval = 0.1
        let exp = expectation(description: "no beat")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(beats, 0)
            // 防御 keeper 在 deinit 前继续触发
            _ = keeper
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testDecreaseStopsHeartbeats() {
        var beats = 0
        let keeper = JavaScriptAliveKeeper(timerInterval: 0.05) { beats += 1 }
        keeper.heartbeatInterval = 0.1
        keeper.increaseReference()
        let exp = expectation(description: "stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let baseline = beats
            keeper.decreaseReference()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                XCTAssertEqual(beats, baseline, "decrement 后心跳应停止")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2)
    }

    func testDelayPostponesNextHeartbeat() {
        var beats = 0
        let keeper = JavaScriptAliveKeeper(timerInterval: 0.05) { beats += 1 }
        keeper.heartbeatInterval = 0.2
        keeper.increaseReference()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            keeper.delay()
        }
        let exp = expectation(description: "delayed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(beats, 0, "delay 后下次心跳应推到 0.1+0.2=0.3 之后")
            keeper.decreaseReference()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }
}

// MARK: - Error

@MainActor
final class ErrorTests: XCTestCase {
    func testFromNSErrorReturnsSameInstance() {
        let original = NSError(domain: "X", code: 7, userInfo: nil)
        XCTAssertTrue(NSError.from(original) === original)
    }

    func testFromDictWithCodeAndMessage() {
        let dict: [String: Any] = ["code": -42, "message": "boom"]
        let e = NSError.from(dict)
        XCTAssertEqual(e.domain, WebnatErrorDomain)
        XCTAssertEqual(e.code, -42)
        XCTAssertEqual(e.localizedDescription, "boom")
    }

    func testFromDictWithVariantFieldNames() {
        let dict: [String: Any] = ["errCode": "777", "errMsg": "x"]
        let e = NSError.from(dict)
        XCTAssertEqual(e.code, 777)
        XCTAssertEqual(e.localizedDescription, "x")
    }

    func testFromNonDictUsesUnknown() {
        let e = NSError.from("oops" as Any)
        XCTAssertEqual(e.code, WebnatErrorCode.unknown)
        XCTAssertTrue(e.localizedDescription.contains("oops"))
    }

    func testFactoryConstructorsHaveExpectedCodes() {
        XCTAssertEqual(NSError.timeout().code, WebnatErrorCode.timeout)
        XCTAssertEqual(NSError.closed().code, WebnatErrorCode.closed)
        XCTAssertEqual(NSError.cancelled().code, WebnatErrorCode.cancelled)
        XCTAssertEqual(NSError.unimplemented("m").code, WebnatErrorCode.unimplemented)
        XCTAssertEqual(NSError.serializationFailed("x").code, WebnatErrorCode.serializationFailed)
        XCTAssertEqual(NSError.deserializationFailed("x").code, WebnatErrorCode.deserializationFailed)
        XCTAssertEqual(NSError.unknown("x").code, WebnatErrorCode.unknown)
    }

    func testToJsonRoundTrip() {
        let json = NSError.timeout().toJson()
        let back = NSError.from(json as Any)
        XCTAssertEqual(back.code, WebnatErrorCode.timeout)
    }
}

// MARK: - Message decode (NSNull placeholder + skip semantics)

@MainActor
final class MessageDecodeTests: XCTestCase {
    func testDecodePrimitiveAndNestedTypes() {
        let original = Message.invoke(to: "p", id: "i", method: "m", param: ["s": "x", "n": 1, "b": true, "arr": [1, 2.5, "z"]])
        let parsed = Message.from(dict: original.toDictionary())
        let p = parsed?.invoke?.param as? [String: Sendable]
        XCTAssertEqual(p?["s"] as? String, "x")
        XCTAssertEqual(p?["n"] as? Int, 1)
        XCTAssertEqual(p?["b"] as? Bool, true)
        let arr = p?["arr"] as? [Sendable]
        XCTAssertEqual(arr?.count, 3)
    }

    func testDecodeNSNullAtTopLevelKeptAsPlaceholder() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "broadcast": ["name": "e", "param": NSNull()],
        ]
        let m = Message.from(dict: dict)
        XCTAssertNotNil(m?.broadcast)
        XCTAssertTrue(m?.broadcast?.param is NSNull, "NSNull 应作为 Sendable 占位保留")
    }

    func testDecodeArrayContainingNSNullKeepsItAsPlaceholder() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "broadcast": ["name": "e", "param": [1, NSNull(), "z"]],
        ]
        let m = Message.from(dict: dict)
        let arr = m?.broadcast?.param as? [Sendable]
        XCTAssertEqual(arr?.count, 3)
        XCTAssertTrue(arr?[1] is NSNull)
    }

    func testDecodeArraySkipsUnknownTypeButKeepsValid() {
        // Date 不是 JSON 类型，应在数组中被跳过（与 NSNull 的「保留占位」行为不同）
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "broadcast": ["name": "e", "param": [1, Date(), "z"]],
        ]
        let m = Message.from(dict: dict)
        let arr = m?.broadcast?.param as? [Sendable]
        XCTAssertEqual(arr?.count, 2, "未识别类型应跳过，而不是让整个数组失败")
        XCTAssertEqual(arr?[0] as? Int, 1)
        XCTAssertEqual(arr?[1] as? String, "z")
    }

    func testDecodeDictSkipsUnknownTypeButKeepsValid() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "broadcast": ["name": "e", "param": ["k1": 1, "k2": Date(), "k3": "z"]],
        ]
        let m = Message.from(dict: dict)
        let p = m?.broadcast?.param as? [String: Sendable]
        XCTAssertEqual(p?.count, 2)
        XCTAssertEqual(p?["k1"] as? Int, 1)
        XCTAssertEqual(p?["k3"] as? String, "z")
    }

    func testDecodeInvokeWithoutMethodIsDropped() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "invoke": ["id": "i"],
        ]
        let m = Message.from(dict: dict)
        XCTAssertNotNil(m)
        XCTAssertNil(m?.invoke, "缺少 method 时整个 invoke payload 应被丢弃")
    }

    func testDecodeBroadcastWithoutNameIsDropped() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "broadcast": ["param": "x"],
        ]
        let m = Message.from(dict: dict)
        XCTAssertNotNil(m)
        XCTAssertNil(m?.broadcast)
    }

    func testDecodeReplyWithoutIdIsDropped() {
        let dict: [String: Any] = [
            "magic": Message.MAGIC,
            "from": "x",
            "to": "y",
            "reply": ["result": 1],
        ]
        let m = Message.from(dict: dict)
        XCTAssertNotNil(m)
        XCTAssertNil(m?.reply)
    }
}

// MARK: - Webnat top-level

@MainActor
final class WebnatStaticTests: XCTestCase {
    func testOfReturnsSameInstanceForSameWebView() {
        let cfg = WKWebViewConfiguration()
        Webnat.initialize(webViewConfiguration: cfg)
        let webView = WKWebView(frame: .zero, configuration: cfg)
        let a = Webnat.of(webView)
        let b = Webnat.of(webView)
        XCTAssertTrue(a === b)
    }

    func testOfDistinctForDifferentWebViews() {
        let cfg1 = WKWebViewConfiguration()
        Webnat.initialize(webViewConfiguration: cfg1)
        let v1 = WKWebView(frame: .zero, configuration: cfg1)
        let cfg2 = WKWebViewConfiguration()
        Webnat.initialize(webViewConfiguration: cfg2)
        let v2 = WKWebView(frame: .zero, configuration: cfg2)
        XCTAssertFalse(Webnat.of(v1) === Webnat.of(v2))
    }

    func testInitializePrependsWebnatUserAgent() {
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = "MyApp/1.0"
        Webnat.initialize(webViewConfiguration: cfg)
        let ua = cfg.applicationNameForUserAgent ?? ""
        XCTAssertTrue(ua.contains("Webnat/"))
        XCTAssertTrue(ua.contains("MyApp/1.0"))
    }

    func testInitializeIsIdempotent() {
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = "A/1"
        Webnat.initialize(webViewConfiguration: cfg)
        let firstUA = cfg.applicationNameForUserAgent ?? ""
        Webnat.initialize(webViewConfiguration: cfg)
        let secondUA = cfg.applicationNameForUserAgent ?? ""
        // 重复 initialize 不应累加多个 Webnat/x 段
        let count = secondUA.components(separatedBy: "Webnat/").count - 1
        XCTAssertEqual(count, 1, "重复 initialize 不应在 UA 中累加 Webnat 段；当前 UA: \(secondUA)")
        XCTAssertEqual(firstUA.contains("A/1"), secondUA.contains("A/1"))
    }
}

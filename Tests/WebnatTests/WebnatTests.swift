//
//  WebnatTests.swift
//  Webnat
//
//  Created by auhgnayuo on 2025/11/14.
//

import XCTest
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
}

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
}

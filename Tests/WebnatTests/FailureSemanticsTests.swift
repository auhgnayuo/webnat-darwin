//
//  FailureSemanticsTests.swift
//  Webnat
//
//  跨端「失败语义」契约在 Darwin 上的测试：
//  - C1b  同步完成的 handler 不留下取消 / 关闭钩子
//  - C2   发送失败对等待方可见：序列化失败 -1012、WebView 已销毁 closed、WebKit 报告的错误原样透出；
//         结果无法序列化时回复 -1012 错误回复；非 JSON 值不会让进程崩溃
//  - C3   `webViewWebContentProcessDidTerminate()`
//

import XCTest
import WebKit
import JavaScriptCore
@testable import Webnat

// MARK: - 测试替身

/// 记录 `evaluateJavaScript` 收到的脚本，不经过 WebKit；`evaluateError` 非空时按失败回调。
@MainActor
private final class RecordingWebView: WKWebView {
    var scripts: [String] = []
    var evaluateError: Error?

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        scripts.append(javaScriptString)
        completionHandler?(nil, evaluateError)
    }
}

/// `WKScriptMessage` 无法直接构造：用子类喂入 `body` 和 `webView`。
@MainActor
private final class FakeScriptMessage: WKScriptMessage {
    private let payload: Any
    private weak var owner: WKWebView?

    init(body: Any, webView: WKWebView) {
        payload = body
        owner = webView
        super.init()
    }

    override var body: Any { payload }
    override var webView: WKWebView? { owner }
    /// 裸构造的 `WKFrameInfo` 没有内部状态，一释放 WebKit 就崩溃：用一个永不释放的共享实例。
    private static let sharedFrameInfo = WKFrameInfo()
    override var frameInfo: WKFrameInfo { Self.sharedFrameInfo }
    override var name: String { "__native_webnat__" }
}

/// 让 `@Sendable` 回调里也能记录结果的小盒子（MainActor 隔离的类天然 Sendable）。
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 一个真实的 `Webnat`（挂在 `RecordingWebView` 上），页面消息从 `userContentController(_:didReceive:)` 灌入。
@MainActor
private final class Harness {
    let webView: RecordingWebView
    let webnat: Webnat

    init() {
        let configuration = WKWebViewConfiguration()
        Webnat.initialize(webViewConfiguration: configuration)
        webView = RecordingWebView(frame: .zero, configuration: configuration)
        webnat = Webnat.of(webView)
    }

    /// 模拟 Web 端发来一条协议消息。
    func web(_ message: Message) {
        let fake = FakeScriptMessage(body: message.dictionaryForTest(), webView: webView)
        webnat.userContentController(webView.configuration.userContentController, didReceive: fake)
    }

    /// 模拟 Web 端打开一个连接并返回它。
    @discardableResult
    func open(_ id: String = "main") -> Connection {
        web(Message.open(from: id, param: ["origin": "https://demo.example", "isMainframe": true]))
        return webnat.connections[id]!
    }

    /// 已发给 Web 端的协议消息（解析自 `evaluateJavaScript` 收到的脚本）。
    var sent: [[String: Any]] {
        let prefix = "window.__web_webnat__.receive(..."
        return webView.scripts.compactMap { script in
            guard script.hasPrefix(prefix), script.hasSuffix(")") else { return nil }
            let expression = String(script.dropFirst(prefix.count).dropLast())
            guard expression.hasPrefix("JSON.parse("), expression.hasSuffix(")"),
                  let literal = String(expression.dropFirst("JSON.parse(".count).dropLast()).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed) as? String,
                  let data = json.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            return array.first
        }
    }

    /// 已发给 Web 端的 reply 消息体。
    var replies: [[String: Any]] {
        sent.compactMap { $0["reply"] as? [String: Any] }
    }
}

@MainActor
private func invokeFromWeb(_ connectionId: String, id: String, method: String, param: Sendable? = nil) -> Message {
    Message(from: connectionId, to: Message.NATIVE_UUID, invoke: Invoke(id: id, method: method, param: param))
}

@MainActor
private func replyFromWeb(_ connectionId: String, id: String, result: Sendable? = nil) -> Message {
    Message(from: connectionId, to: Message.NATIVE_UUID, reply: Reply(id: id, result: result))
}

// MARK: - C2：发送失败对等待方可见

@MainActor
final class SendFailureTests: XCTestCase {
    private struct Point: Sendable { var x = 1 }

    func testMethodWithUnserializableParamFailsAtOnceWithSerializationFailed() {
        let h = Harness()
        let conn = h.open()
        let failure = Box<NSError?>(nil)
        let completions = Box(0)
        h.webnat.method("m", param: Date(), callback: { _, error in
            completions.value += 1
            failure.value = error as NSError?
        }, connection: conn)
        XCTAssertEqual(completions.value, 1, "应当立即失败，而不是等到超时")
        XCTAssertEqual(failure.value?.domain, WebnatErrorDomain)
        XCTAssertEqual(failure.value?.code, WebnatErrorCode.serializationFailed)
        XCTAssertTrue(h.sent.isEmpty, "无法序列化的消息不应发给页面")
    }

    func testAsyncMethodWithUnserializableParamThrowsSerializationFailed() async {
        let h = Harness()
        let conn = h.open()
        do {
            _ = try await h.webnat.method("m", param: Date(), connection: conn)
            XCTFail("应当抛出序列化失败")
        } catch {
            XCTAssertEqual((error as NSError).code, WebnatErrorCode.serializationFailed)
        }
    }

    /// T9：非 JSON 值（`JSONSerialization` 会抛出 Swift 的 do/catch 抓不到的 NSException）不能让进程崩溃。
    func testNonJSONValuesFailWithoutCrashing() {
        let values: [(String, Sendable)] = [
            ("Date", Date()),
            ("Data", Data([1, 2])),
            ("NaN", Double.nan),
            ("infinity", Float.infinity),
            ("custom struct", Point()),
            ("non-string key", [1: "a"]),
            ("nested Date", ["k": [Date()]]),
        ]
        let h = Harness()
        let conn = h.open()
        for (label, value) in values {
            let code = Box<Int?>(nil)
            h.webnat.method("m", param: value, callback: { _, error in
                code.value = (error as NSError?)?.code
            }, connection: conn)
            XCTAssertEqual(code.value, WebnatErrorCode.serializationFailed, label)
            // raw / broadcast 是发出即忘：不崩溃、不外发
            h.webnat.raw(value, connection: conn)
            h.webnat.broadcast(name: "evt", param: value, connection: conn)
        }
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testConnectionMetadataRemainsJsonCompatibleAndFrameInfoIsSeparate() throws {
        let h = Harness()
        let payload: [String: Sendable?] = ["null": NSNull(), "items": [1, nil] as [Sendable?]]
        h.web(Message.open(from: "meta", param: payload))
        let connection = try XCTUnwrap(h.webnat.connections["meta"])
        let attributes = try XCTUnwrap(connection.attributes)
        XCTAssertTrue(attributes.keys.contains("null")); XCTAssertTrue(attributes["null"]! is NSNull)
        XCTAssertFalse(attributes.keys.contains("frameInfo")); XCTAssertTrue(connection.frameInfo != nil)
        h.webnat.raw(attributes, connection: connection)
        let sent = try XCTUnwrap(h.sent.last?["raw"] as? [String: Any])
        XCTAssertTrue((sent["param"] as? [String: Any])?["null"] is NSNull)
        h.webnat.webViewWebContentProcessDidTerminate()
    }

    func testJavaScriptTransportPreservesProtoKeysAndUnicodeInTheRealJSEngine() throws {
        let h = Harness(); let connection = h.open()
        let payload: [String: Sendable?] = ["__proto__": ["safe": true], "text": "你好 😀\n\"\u{2028}\u{2029}"]
        h.webnat.raw(payload, connection: connection)
        let script = try XCTUnwrap(h.webView.scripts.last)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var seen; var window = {__web_webnat__: {receive: function(m) {seen=m;}}};")
        context.evaluateScript(script)
        XCTAssertTrue(context.exception == nil)
        XCTAssertTrue(context.evaluateScript("Object.prototype.hasOwnProperty.call(seen.raw.param, '__proto__') && Object.getPrototypeOf(seen.raw.param) === Object.prototype && seen.raw.param.__proto__.safe === true")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("seen.raw.param.text")?.toString(), "你好 😀\n\"\u{2028}\u{2029}")
        h.webnat.webViewWebContentProcessDidTerminate()
    }

    func testSerializableValuesAreStillDelivered() {
        let h = Harness()
        let conn = h.open()
        let param: [String: Sendable?] = [
            "int": 1, "int64": Int64(2), "uint": UInt(3), "double": 1.5, "float": Float(2.5),
            "bool": true, "string": "x", "null": NSNull(), "array": [1, "two", 3.0], "object": ["k": "v"],
        ]
        h.webnat.method("m", param: param, callback: { _, _ in }, connection: conn)
        let invoke = h.sent.last?["invoke"] as? [String: Any]
        XCTAssertEqual(invoke?["method"] as? String, "m")
        let delivered = invoke?["param"] as? [String: Any]
        XCTAssertEqual(delivered?["int"] as? Int, 1)
        XCTAssertEqual(delivered?["string"] as? String, "x")
        XCTAssertEqual((delivered?["array"] as? [Any])?.count, 3)
        XCTAssertTrue(delivered?["null"] is NSNull)
        // 清理挂起的调用（保活定时器随引用计数停止）
        h.webnat.webViewWebContentProcessDidTerminate()
    }

    /// WebKit 自己报告的投递失败，照旧让调用立即失败（Darwin 本来就如此，这里固定下来）。
    func testDeliveryErrorReportedByWebKitStillFailsTheCallAtOnce() {
        let h = Harness()
        let conn = h.open()
        h.webView.evaluateError = NSError(domain: "WKErrorDomain", code: 4, userInfo: nil)
        let seen = Box<NSError?>(nil)
        h.webnat.method("m", callback: { _, error in seen.value = error as NSError? }, connection: conn)
        XCTAssertEqual(seen.value?.domain, "WKErrorDomain")
        XCTAssertEqual(seen.value?.code, 4)
    }

    private func makeDetachedConnection() -> (Webnat, Connection) {
        autoreleasepool {
            let h = Harness()
            return (h.webnat, h.open())
        }
    }

    func testMethodOnGoneWebViewFailsWithClosed() {
        let (webnat, conn) = makeDetachedConnection() // WKWebView 随 Harness 释放
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) // WebKit 的释放会稍有延迟
        let seen = Box<NSError?>(nil)
        webnat.method("m", callback: { _, error in seen.value = error as NSError? }, connection: conn)
        XCTAssertEqual(seen.value?.code, WebnatErrorCode.closed)
    }

    func testSendSurfacesFailureAndNilCompletionSwallowsIt() {
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, completion in
            completion?(NSError.serializationFailed("x"))
        }
        let seen = Box<NSError?>(nil)
        conn.send(Message.raw(to: "c", param: 1)) { seen.value = $0 as NSError? }
        XCTAssertEqual(seen.value?.code, WebnatErrorCode.serializationFailed)
        conn.send(Message.raw(to: "c", param: 1)) // 不关心结果：不崩溃即可
    }

    // MARK: 结果无法序列化 -> -1012 错误回复

    func testUnserializableResultIsAnsweredWithSerializationFailedErrorReply() {
        let h = Harness()
        h.open()
        h.webnat.onMethod(name: "now") { _, callback, _, _ in
            callback(Date(), nil)
            return {}
        }
        h.web(invokeFromWeb("main", id: "rid", method: "now"))
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.replies.first?["id"] as? String, "rid")
        XCTAssertNil(h.replies.first?["result"])
        let error = h.replies.first?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, WebnatErrorCode.serializationFailed)
        XCTAssertNotNil(error?["message"] as? String)
    }

    func testUnserializableResultCompletedLaterIsAnsweredToo() {
        let h = Harness()
        h.open()
        let stored = Box<MethodCallback?>(nil)
        h.webnat.onMethod(name: "later") { _, callback, _, _ in
            stored.value = callback
            return {}
        }
        h.web(invokeFromWeb("main", id: "rid", method: "later"))
        XCTAssertTrue(h.replies.isEmpty)
        stored.value?(Double.nan, nil)
        let error = h.replies.first?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, WebnatErrorCode.serializationFailed)
    }

    func testSerializableResultIsNotReplacedByAnError() {
        let h = Harness()
        h.open()
        h.webnat.onMethod(name: "ok") { _, callback, _, _ in
            callback(["answer": 42], nil)
            return {}
        }
        h.web(invokeFromWeb("main", id: "rid", method: "ok"))
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual((h.replies.first?["result"] as? [String: Any])?["answer"] as? Int, 42)
        XCTAssertNil(h.replies.first?["error"])
    }
}

// MARK: - C2：回复降级（MethodWebnat 层，固定降级的边界）

@MainActor
final class ReplyFallbackTests: XCTestCase {
    private func answer(
        failingWith error: NSError,
        sentLog: Box<[Message]>,
        attempts: Box<Int>
    ) -> (MethodWebnat, Connection) {
        let rpc = MethodWebnat()
        let conn = Connection(id: "c", attributes: nil, url: nil) { message, completion in
            attempts.value += 1
            if message.reply?.result != nil {
                completion?(error)
                return
            }
            sentLog.value.append(message)
            completion?(nil)
        }
        rpc.on(name: "m") { _, callback, _, _ in
            callback("valid result", nil)
            return {}
        }
        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "i", method: "m"))
        return (rpc, conn)
    }

    func testSerializationFailureTriggersExactlyOneErrorReply() {
        let sentLog = Box<[Message]>([])
        let attempts = Box(0)
        _ = answer(failingWith: NSError.serializationFailed("result"), sentLog: sentLog, attempts: attempts)
        XCTAssertEqual(attempts.value, 2, "一次结果回复 + 一次降级的错误回复")
        XCTAssertEqual(sentLog.value.count, 1)
        XCTAssertEqual(sentLog.value.first?.reply?.id, "i")
        let error = sentLog.value.first?.reply?.error as? [String: Sendable?]
        XCTAssertEqual(error?["code"] as? Int, WebnatErrorCode.serializationFailed)
    }

    func testOtherSendFailuresDoNotTriggerAFallback() {
        for failure in [NSError.closed(), NSError(domain: "WKErrorDomain", code: 4, userInfo: nil)] {
            let sentLog = Box<[Message]>([])
            let attempts = Box(0)
            _ = answer(failingWith: failure, sentLog: sentLog, attempts: attempts)
            XCTAssertEqual(attempts.value, 1, "\(failure.domain) \(failure.code)")
            XCTAssertTrue(sentLog.value.isEmpty)
        }
    }

    func testSameCodeInAnotherErrorDomainDoesNotTriggerAFallback() {
        // NSURLErrorDomain 里 -1012 是 userCancelledAuthentication，与 Webnat 的序列化失败无关
        let sentLog = Box<[Message]>([])
        let attempts = Box(0)
        _ = answer(failingWith: NSError(domain: NSURLErrorDomain, code: -1012, userInfo: nil), sentLog: sentLog, attempts: attempts)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(sentLog.value.isEmpty)
    }

    func testFailingErrorReplyDoesNotLoop() {
        let rpc = MethodWebnat()
        let attempts = Box(0)
        let conn = Connection(id: "c", attributes: nil, url: nil) { _, completion in
            attempts.value += 1
            completion?(NSError.serializationFailed("always"))
        }
        rpc.on(name: "m") { _, callback, _, _ in
            callback(Date(), nil)
            return {}
        }
        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "i", method: "m"))
        XCTAssertEqual(attempts.value, 2, "降级的错误回复自己失败时不再重试")
    }
}

// MARK: - C1b：同步完成的 handler 不留下钩子

@MainActor
final class MethodHookCleanupTests: XCTestCase {
    /// 读取 `MethodWebnat` 里仍登记着的取消 / 关闭钩子数量。用 Mirror 读私有表，生产代码不为测试留接口。
    private func hooks(of rpc: MethodWebnat, file: StaticString = #filePath, line: UInt = #line) -> (aborts: Int, closes: Int) {
        let children = Mirror(reflecting: rpc).children
        guard let aborts = children.first(where: { $0.label == "aborts" })?.value as? [String: () -> Void],
              let onCloses = children.first(where: { $0.label == "onCloses" })?.value as? [String: [String: () -> Void]] else {
            XCTFail("MethodWebnat 的 aborts / onCloses 改名或改型了，请同步更新这个测试", file: file, line: line)
            return (-1, -1)
        }
        return (aborts.count, onCloses.values.reduce(0) { $0 + $1.count })
    }

    private func makeConnection(sent: Box<[Message]>) -> Connection {
        Connection(id: "c", attributes: nil, url: nil) { message, completion in
            sent.value.append(message)
            completion?(nil)
        }
    }

    func testSynchronouslyCompletedInvokeLeavesNoHooksBehind() {
        let rpc = MethodWebnat()
        let sent = Box<[Message]>([])
        let conn = makeConnection(sent: sent)
        rpc.on(name: "sync") { _, callback, _, _ in
            callback("ok", nil)
            return {}
        }
        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "i1", method: "sync"))
        XCTAssertEqual(sent.value.compactMap(\.reply).count, 1)
        let counts = hooks(of: rpc)
        XCTAssertEqual(counts.aborts, 0)
        XCTAssertEqual(counts.closes, 0)
    }

    func testManySynchronousInvokesDoNotAccumulateHooks() {
        let rpc = MethodWebnat()
        let sent = Box<[Message]>([])
        let conn = makeConnection(sent: sent)
        rpc.on(name: "sync") { _, callback, _, _ in
            callback(1, nil)
            return {}
        }
        for index in 0..<100 {
            rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "i\(index)", method: "sync"))
        }
        let counts = hooks(of: rpc)
        XCTAssertEqual(counts.aborts, 0)
        XCTAssertEqual(counts.closes, 0)
        // 连接关闭之后也不应有残留
        rpc.onConnectionClose(connection: conn)
        XCTAssertEqual(hooks(of: rpc).closes, 0)
    }

    func testPendingInvokeKeepsItsHooksUntilItCompletes() {
        let rpc = MethodWebnat()
        let sent = Box<[Message]>([])
        let conn = makeConnection(sent: sent)
        let stored = Box<MethodCallback?>(nil)
        rpc.on(name: "later") { _, callback, _, _ in
            stored.value = callback
            return {}
        }
        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "i1", method: "later"))
        XCTAssertEqual(hooks(of: rpc).aborts, 1)
        XCTAssertEqual(hooks(of: rpc).closes, 1)
        stored.value?("done", nil)
        XCTAssertEqual(hooks(of: rpc).aborts, 0)
        XCTAssertEqual(hooks(of: rpc).closes, 0)
        XCTAssertEqual(sent.value.compactMap(\.reply).count, 1)
    }

    func testPendingInvokeIsStillAbortedByThePeerAndByConnectionClose() {
        let rpc = MethodWebnat()
        let sent = Box<[Message]>([])
        let conn = makeConnection(sent: sent)
        let cancelled = Box(0)
        rpc.on(name: "long") { _, _, _, _ in
            return { cancelled.value += 1 }
        }
        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "a", method: "long"))
        rpc.onConnectionReceive(connection: conn, message: Message(from: "c", to: Message.NATIVE_UUID, abort: Abort(id: "a")))
        XCTAssertEqual(cancelled.value, 1)

        rpc.onConnectionReceive(connection: conn, message: invokeFromWeb("c", id: "b", method: "long"))
        rpc.onConnectionClose(connection: conn)
        XCTAssertEqual(cancelled.value, 2)
        let counts = hooks(of: rpc)
        XCTAssertEqual(counts.aborts, 0)
        XCTAssertEqual(counts.closes, 0)
        XCTAssertTrue(sent.value.compactMap(\.reply).isEmpty, "被取消或随连接关闭的调用没有回复")
    }
}

// MARK: - C3：webViewWebContentProcessDidTerminate

@MainActor
final class CloseAllConnectionsTests: XCTestCase {
    func testEndsPendingCallsAbortsHandlersAndEmptiesTheConnectionTable() {
        let h = Harness()
        let conn = h.open("main")
        let completions = Box(0)
        let failure = Box<NSError?>(nil)
        h.webnat.method("slow", callback: { _, error in
            completions.value += 1
            failure.value = error as NSError?
        }, connection: conn)

        let aborted = Box(0)
        let lateCallback = Box<MethodCallback?>(nil)
        h.webnat.onMethod(name: "long") { _, callback, _, _ in
            lateCallback.value = callback
            return { aborted.value += 1 }
        }
        h.web(invokeFromWeb("main", id: "rid", method: "long"))
        let sentBefore = h.sent.count

        h.webnat.webViewWebContentProcessDidTerminate()

        XCTAssertEqual(completions.value, 1)
        XCTAssertEqual(failure.value?.code, WebnatErrorCode.closed)
        XCTAssertEqual(aborted.value, 1)
        XCTAssertTrue(h.webnat.connections.isEmpty)
        XCTAssertTrue(conn.closed)
        lateCallback.value?("too late", nil)
        XCTAssertEqual(h.sent.count, sentBefore, "不向页面发送任何消息，被取消的 handler 迟到的结果也不回复")
    }

    func testIsIdempotentAndWebnatKeepsWorkingForAReloadedPage() {
        let h = Harness()
        h.webnat.webViewWebContentProcessDidTerminate() // 没有连接：什么也不做
        let first = h.open("main")
        let completions = Box(0)
        h.webnat.method("slow", callback: { _, _ in completions.value += 1 }, connection: first)
        h.webnat.webViewWebContentProcessDidTerminate()
        h.webnat.webViewWebContentProcessDidTerminate()
        XCTAssertEqual(completions.value, 1, "回调只触发一次")
        XCTAssertTrue(first.closed)

        // 页面重新加载：新的连接 ID，Webnat 与已注册的 handler 都还在
        h.webnat.onMethod(name: "echo") { param, callback, _, _ in
            callback(param, nil)
            return {}
        }
        let second = h.open("main-2")
        XCTAssertFalse(second.closed)
        XCTAssertEqual(h.webnat.connections.count, 1)
        h.web(invokeFromWeb("main-2", id: "r1", method: "echo", param: "hi"))
        XCTAssertEqual(h.replies.last?["result"] as? String, "hi")

        let answer = Box<Sendable?>(nil)
        h.webnat.method("ping", callback: { result, _ in answer.value = result }, connection: second)
        let invoke = h.sent.last?["invoke"] as? [String: Any]
        XCTAssertEqual(invoke?["method"] as? String, "ping")
        h.web(replyFromWeb("main-2", id: invoke?["id"] as? String ?? "", result: "pong"))
        XCTAssertEqual(answer.value as? String, "pong")
    }

    func testReopeningWithTheSameConnectionIdAfterCloseWorks() {
        let h = Harness()
        let first = h.open("main")
        h.webnat.webViewWebContentProcessDidTerminate()
        let second = h.open("main")
        XCTAssertFalse(second.closed)
        XCTAssertTrue(first.closed)
        XCTAssertTrue(h.webnat.connections["main"] === second)
    }

    func testCallbackRunningDuringCloseSeesTheWholeWebnatAlreadyClosed() {
        let h = Harness()
        let main = h.open("main")
        h.open("frame")
        let reentrantFailure = Box<NSError?>(nil)
        let connectionsSeen = Box(-1)
        let completions = Box(0)
        h.webnat.method("slow", callback: { _, _ in
            completions.value += 1
            connectionsSeen.value = h.webnat.connections.count
            h.webnat.webViewWebContentProcessDidTerminate() // 重入：不能重复触发回调，也不能崩溃
            h.webnat.method("again", callback: { _, error in reentrantFailure.value = error as NSError? }, connection: main)
        }, connection: main)
        h.webnat.webViewWebContentProcessDidTerminate()
        XCTAssertEqual(completions.value, 1)
        XCTAssertEqual(connectionsSeen.value, 0, "回调里看到的应是已经全部关闭的状态")
        XCTAssertEqual(reentrantFailure.value?.code, WebnatErrorCode.closed)
    }

    func testBroadcastCallWithoutConnectionEndsWithClosedWhenEveryConnectionIsClosed() {
        let h = Harness()
        h.open("main")
        h.open("frame")
        let completions = Box(0)
        let failure = Box<NSError?>(nil)
        h.webnat.method("x", callback: { _, error in
            completions.value += 1
            failure.value = error as NSError?
        })
        XCTAssertEqual(h.sent.compactMap { $0["invoke"] }.count, 2, "广播给两个连接")
        h.webnat.webViewWebContentProcessDidTerminate()
        XCTAssertEqual(completions.value, 1)
        XCTAssertEqual(failure.value?.code, WebnatErrorCode.closed)
    }
}

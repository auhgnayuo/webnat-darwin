import Foundation
import XCTest
@testable import Webnat

@MainActor
extension Message {
    /// Existing valid-message fixtures: retain XCTest failures instead of crashing on an unexpected error.
    func dictionaryForTest(file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        do { return try toDictionary() }
        catch { XCTFail("Unexpected encoding failure: \(error)", file: file, line: line); return [:] }
    }
}

@MainActor
final class JsonValueTests: XCTestCase {
    func testNestedNullRoundTripPreservesFieldsAndPositions() throws {
        let payload: [String: Sendable?] = ["": "empty key", "nil": nil, "array": [1, nil, ["x": nil] as [String: Sendable?]] as [Sendable?]]
        let json = try toJsonValue(payload)
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try XCTUnwrap(try fromJsonValue(JSONSerialization.jsonObject(with: data)) as? [String: Sendable?])
        XCTAssertTrue(decoded.keys.contains("nil"))
        XCTAssertNil(decoded["nil"]!)
        XCTAssertEqual(decoded[""] as? String, "empty key")
        let array = try XCTUnwrap(decoded["array"] as? [Sendable?])
        XCTAssertEqual(array.count, 3)
        XCTAssertNil(array[1])
        let nested = try XCTUnwrap(array[2] as? [String: Sendable?])
        XCTAssertTrue(nested.keys.contains("x"))
        XCTAssertNil(nested["x"]!)
    }

    func testNullMessageFieldsUseTheUnknownErrorFallback() throws {
        let value = try XCTUnwrap(try fromJsonValue(["code": 123, "message": NSNull()]))
        let error = NSError.from(value)
        XCTAssertEqual(error.code, 123)
        XCTAssertEqual(error.localizedDescription, "Unknown Error")
    }

    func testUnicodeControlsAndQuotedStringsRoundTrip() throws {
        let strings = ["", "你好 😀", "\n\r\t\\\"", "\u{0}\u{2028}\u{2029}"]
        let json = try toJsonValue(strings)
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try fromJsonValue(JSONSerialization.jsonObject(with: data)) as? [String], strings)
    }

    func testNullAndEmptyContainers() throws {
        XCTAssertTrue(try toJsonValue(nil) is NSNull)
        XCTAssertNil(try fromJsonValue(NSNull()))
        XCTAssertNil(try fromJsonValue(nil))
        XCTAssertEqual((try fromJsonValue([:] as [String: Any])) as? [String: String], [:])
        XCTAssertEqual((try fromJsonValue([] as [Any])) as? [String], [])
    }

    func testRejectsInvalidTypesAtEveryLevel() {
        struct Custom: Sendable { let value = 1 }
        let invalid: [Any] = [Date(), Data([1]), Set([1]), Custom(), NSNull(), [1: "non-string key"]]
        for value in invalid {
            XCTAssertThrowsError(try toJsonValue(value))
            XCTAssertThrowsError(try toJsonValue(["nested": [value]]))
        }
        for value in [Date(), Data([1]), Set([1]), Custom(), [1: "non-string key"]] as [Any] {
            XCTAssertThrowsError(try fromJsonValue(value))
            XCTAssertThrowsError(try fromJsonValue(["nested": [value]]))
        }
    }

    func testRejectsNonFiniteNumbers() {
        for value in [Double.nan, .infinity, -.infinity] {
            for payload in [value, [value], ["nested": [value]]] as [Any] {
                XCTAssertThrowsError(try toJsonValue(payload))
                XCTAssertThrowsError(try fromJsonValue(payload))
            }
        }
    }

    func testPreservesNumericBooleanAndIntegerPrecision() throws {
        for number in [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: -1), NSNumber(value: Int64(9007199254740993)), NSNumber(value: UInt64.max)] {
            let value = try XCTUnwrap(try fromJsonValue(number))
            let encoded = try XCTUnwrap(try toJsonValue(value) as? NSNumber)
            XCTAssertNotEqual(CFGetTypeID(encoded), CFBooleanGetTypeID())
            XCTAssertEqual(encoded, number)
        }
        for boolean in [true, false] {
            XCTAssertEqual(try fromJsonValue(NSNumber(value: boolean)) as? Bool, boolean)
        }
    }

    func testAllMessageBodiesConvertNullAndRejectInvalidPayloads() throws {
        let payload: [String: Sendable?] = ["null": nil, "list": [1, nil, 3] as [Sendable?]]
        let messages = [Message.open(from: "p", param: payload), Message.close(from: "p", param: payload),
                        Message.raw(to: "p", param: payload), Message.broadcast(to: "p", name: "e", param: payload),
                        Message.invoke(to: "p", id: "i", method: "m", param: payload), Message.reply(to: "p", id: "i", result: payload),
                        Message.reply(to: "p", id: "i", error: payload), Message.notify(to: "p", id: "i", param: payload), Message.abort(to: "p", id: "i")]
        for message in messages {
            let json = try message.toDictionary()
            let parsed = try XCTUnwrap(Message.from(dict: json))
            let encodedAgain = try parsed.toDictionary()
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: json, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: encodedAgain, options: .sortedKeys))
        }
        let invalid = [Message.open(from: "p", param: Date()), Message.close(from: "p", param: Date()),
                       Message.raw(to: "p", param: Date()), Message.broadcast(to: "p", name: "e", param: Date()),
                       Message.invoke(to: "p", id: "i", method: "m", param: Date()), Message.reply(to: "p", id: "i", result: Date()),
                       Message.reply(to: "p", id: "i", error: Date()), Message.notify(to: "p", id: "i", param: Date())]
        for message in invalid {
            XCTAssertThrowsError(try message.toDictionary()) { XCTAssertEqual(($0 as NSError).code, WebnatErrorCode.serializationFailed) }
        }
    }

    func testNativeNullsReachRawBroadcastAndMethodListeners() throws {
        let payload: [String: Sendable?] = ["null": nil, "array": [1, nil, 3] as [Sendable?]]
        let state = ListenerState()
        let connection = Connection(id: "p", attributes: nil, url: nil) { message, completion in
            state.sent.append(message)
            completion?(nil)
        }
        let raw = RawWebnat()
        raw.on { value, _ in state.raw += 1; Self.checkNullPayload(value) }
        raw.onConnectionReceive(connection: connection, message: try XCTUnwrap(Message.from(dict: Message.raw(to: "p", param: payload).toDictionary())))
        let broadcast = BroadcastWebnat()
        broadcast.on(name: "event") { value, _ in state.broadcast += 1; Self.checkNullPayload(value) }
        broadcast.onConnectionReceive(connection: connection, message: try XCTUnwrap(Message.from(dict: Message.broadcast(to: "p", name: "event", param: payload).toDictionary())))
        let methods = MethodWebnat()
        methods.on(name: "echo") { value, callback, notify, _ in
            state.method += 1
            Self.checkNullPayload(value)
            notify(value)
            callback(value, nil)
            return {}
        }
        methods.onConnectionReceive(connection: connection, message: try XCTUnwrap(Message.from(dict: Message.invoke(to: "p", id: "i", method: "echo", param: payload).toDictionary())))
        XCTAssertEqual(state.raw, 1); XCTAssertEqual(state.broadcast, 1); XCTAssertEqual(state.method, 1)
        XCTAssertEqual(state.sent.count, 2)
        for message in state.sent {
            let parsed = try XCTUnwrap(Message.from(dict: message.toDictionary()))
            Self.checkNullPayload(parsed.notify?.param ?? parsed.reply?.result)
        }
    }

    private static func checkNullPayload(_ value: Sendable?) {
        let dictionary = value as? [String: Sendable?]
        XCTAssertNotNil(dictionary)
        XCTAssertTrue(dictionary?.keys.contains("null") == true)
        XCTAssertNil(dictionary?["null"]!)
        XCTAssertNil((dictionary?["array"] as? [Sendable?])?[1])
    }

    func testEveryPayloadFieldNormalizesMissingAndExplicitNull() throws {
        for body in ["open", "close", "raw", "broadcast", "invoke", "reply", "notify"] {
            for explicitNull in [false, true] {
                var fields: [String: Any] = ["id": "i", "method": "m", "name": "e"]
                if explicitNull { fields["param"] = NSNull(); fields["result"] = NSNull(); fields["error"] = NSNull() }
                let message = try XCTUnwrap(Message.from(dict: ["magic": Message.MAGIC, "from": "p", "to": "n", body: fields]))
                XCTAssertNil(message.open?.param); XCTAssertNil(message.close?.param); XCTAssertNil(message.raw?.param)
                XCTAssertNil(message.broadcast?.param); XCTAssertNil(message.invoke?.param); XCTAssertNil(message.notify?.param)
                XCTAssertNil(message.reply?.result); XCTAssertNil(message.reply?.error)
                let encoded = try XCTUnwrap(try message.toDictionary()[body] as? [String: Any])
                XCTAssertNil(encoded["param"]); XCTAssertNil(encoded["result"]); XCTAssertNil(encoded["error"])
            }
        }
    }

    func testInvalidDataInAnyPayloadRejectsTheEntireMessage() {
        for body in ["open", "close", "raw", "broadcast", "invoke", "reply", "notify"] {
            let fieldsToCheck = body == "reply" ? ["result", "error"] : ["param"]
            for field in fieldsToCheck {
                for invalid in [Date(), Double.nan, ["nested": [Date()]]] as [Any] {
                    let fields: [String: Any] = ["id": "i", "method": "m", "name": "e", field: invalid]
                    XCTAssertNil(Message.from(dict: ["magic": Message.MAGIC, "from": "p", "to": "n", body: fields]))
                }
            }
        }
        for body in ["open", "close", "raw", "broadcast", "invoke", "reply", "notify", "abort"] {
            for invalid in [NSNull(), "string", [1, 2]] as [Any] {
                XCTAssertNil(Message.from(dict: ["magic": Message.MAGIC, "from": "p", "to": "n", body: invalid]))
            }
        }
    }

    func testFoundationDecodingAndSharedChildren() throws {
        let child = NSArray(array: [1, NSNull()])
        let value = NSDictionary(dictionary: ["a": child, "b": child])
        let decoded = try XCTUnwrap(try fromJsonValue(value) as? [String: Sendable?])
        XCTAssertEqual((decoded["a"] as? [Sendable?])?.count, 2)
        XCTAssertNil((decoded["b"] as? [Sendable?])?[1])
        XCTAssertThrowsError(try toJsonValue(value))
    }

    func testRejectsCyclicFoundationContainersWithoutCrashing() {
        let array = NSMutableArray(); array.add(array)
        defer { array.removeAllObjects() }
        XCTAssertThrowsError(try fromJsonValue(array))
        XCTAssertThrowsError(try toJsonValue(array))
        let dictionary = NSMutableDictionary(); dictionary["self"] = dictionary
        defer { dictionary.removeAllObjects() }
        XCTAssertThrowsError(try fromJsonValue(dictionary))
        XCTAssertThrowsError(try toJsonValue(dictionary))
    }

    func testConnectionAttributesHaveOptionalValuesAndNoNativeObjects() throws {
        let payload: [String: Sendable?] = ["null": nil, "list": [1, nil] as [Sendable?]]
        let decoded = try XCTUnwrap(Message.from(dict: Message.open(from: "p", param: payload).toDictionary()))
        let connection = Connection(id: "p", attributes: decoded.open?.param as? [String: Sendable?], url: nil) { _, completion in completion?(nil) }
        let attributes = try XCTUnwrap(connection.attributes)
        XCTAssertTrue(attributes.keys.contains("null")); XCTAssertNil(attributes["null"]!)
        XCTAssertFalse(attributes.keys.contains("frameInfo"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(try toJsonValue(attributes)))
    }

    func testExplicitNullErrorIsASuccessfulRPCReply() throws {
        let rpc = MethodWebnat()
        let state = CallState()
        let connection = Connection(id: "p", attributes: nil, url: nil) { message, completion in
            state.id = message.invoke?.id
            completion?(nil)
        }
        _ = rpc.method("m", callback: { result, error in
            state.completed = true
            XCTAssertEqual(result as? Int, 42)
            XCTAssertNil(error)
        }, connection: connection)
        let id = try XCTUnwrap(state.id)
        let json: [String: Any] = ["magic": Message.MAGIC, "from": "p", "to": Message.NATIVE_UUID,
                                   "reply": ["id": id, "result": 42, "error": NSNull()]]
        rpc.onConnectionReceive(connection: connection, message: try XCTUnwrap(Message.from(dict: json)))
        XCTAssertTrue(state.completed)
    }
}

@MainActor
private final class CallState { var id: String?; var completed = false }

@MainActor
private final class ListenerState {
    var raw = 0; var broadcast = 0; var method = 0; var sent: [Message] = []
}

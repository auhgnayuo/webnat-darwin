import Foundation
import XCTest
@testable import Webnat

@MainActor final class SharedContractsTests: XCTestCase {
    private func fixtures() throws -> [String: Any] {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("contracts/v1/golden.json"))) as! [String:Any]
    }
    func testGoldenErrors() throws {
        for c in try fixtures()["errors"] as! [[String:Any]] {
            let expected=c["expected"] as? [String:Any]
            let input=try fromJsonValue(c["input"])
            if expected==nil {XCTAssertNil(input,c["id"] as! String);continue}
            let e=NSError.from(input as Any)
            XCTAssertEqual(e.code,expected!["code"] as! Int,c["id"] as! String)
            XCTAssertEqual(e.localizedDescription,expected!["message"] as! String,c["id"] as! String)
        }
    }
    func testGoldenMessages() throws {
        for c in try fixtures()["messages"] as! [[String:Any]] {
            let m=try XCTUnwrap(Message.from(dict:c["input"] as! [String:Any]),c["id"] as! String)
            let actual=try JSONSerialization.data(withJSONObject:m.toDictionary(),options:.sortedKeys)
            let expected=try JSONSerialization.data(withJSONObject:c["canonical"]!,options:.sortedKeys)
            XCTAssertEqual(actual,expected,c["id"] as! String)
        }
        for c in try fixtures()["rejectedMessages"] as! [[String:Any]] {XCTAssertNil(Message.from(dict:c["input"] as! [String:Any]),c["id"] as! String)}
    }
    func testGoldenInvalidValues() throws {
        for c in try fixtures()["invalidValues"] as! [[String:Any]] {
            let kind=c["kind"] as! String
            if kind=="array-cycle" {
                let a=NSMutableArray();a.add(a);defer{a.removeAllObjects()}
                XCTAssertThrowsError(try fromJsonValue(a));XCTAssertThrowsError(try toJsonValue(a))
            } else if kind=="object-cycle" {
                let d=NSMutableDictionary();d["self"]=d;defer{d.removeAllObjects()}
                XCTAssertThrowsError(try fromJsonValue(d));XCTAssertThrowsError(try toJsonValue(d))
            } else {
                let n=kind=="nan" ? Double.nan : kind=="positive-infinity" ? Double.infinity : -Double.infinity
                XCTAssertThrowsError(try fromJsonValue(n));XCTAssertThrowsError(try toJsonValue(n))
            }
        }
    }
}

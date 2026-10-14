@testable import EarDiggerKit
import XCTest

final class JSONTests: XCTestCase {
    func testOrgJsonStyleAccessors() throws {
        let o = try XCTUnwrap(JSON.object(#"{"s":"x","blank":"  ","null":null,"n":718,"f":1.5,"t":true,"z":0,"one":"1","yes":"TRUE","num":"90"}"#))
        XCTAssertEqual("x", JSON.string(o, "s"))
        XCTAssertNil(JSON.string(o, "blank"))
        XCTAssertNil(JSON.string(o, "null"))
        XCTAssertNil(JSON.string(o, "missing"))
        XCTAssertEqual("718", JSON.string(o, "n"))
        XCTAssertEqual(718, JSON.int(o, "n"))
        XCTAssertEqual(90, JSON.int(o, "num"))
        XCTAssertEqual(7, JSON.int(o, "missing", default: 7))
        XCTAssertTrue(JSON.flag(o, "t"))
        XCTAssertFalse(JSON.flag(o, "z"))
        XCTAssertTrue(JSON.flag(o, "one"))
        XCTAssertTrue(JSON.flag(o, "yes"))
        XCTAssertTrue(JSON.flag(o, "n"))
        XCTAssertFalse(JSON.flag(o, "missing"))
    }

    func testFirmwareQuirksAreForgiven() {
        // NUL padding, junk around the object and a trailing comma.
        let text = "\u{0}\u{0}xx{\"model\":\"ES\",\"brand\":\"bebird\",}\u{0}\u{0}"
        let o = JSON.object(text)
        XCTAssertEqual("ES", o.flatMap { JSON.string($0, "model") })
        XCTAssertNil(JSON.object("no braces here"))
        XCTAssertNil(JSON.object("[1, 2]"))
    }
}

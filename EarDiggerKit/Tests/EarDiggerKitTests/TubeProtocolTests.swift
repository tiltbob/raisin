@testable import EarDiggerKit
import XCTest

final class TubeProtocolTests: XCTestCase {
    func testBatteryIsBigEndianStateAndPercent() {
        // state 2 (charging), 65 percent  -> 0x0002_0041
        let b = TubeProtocol.parseBattery([0x00, 0x02, 0x00, 0x41])!
        XCTAssertEqual(2, b.state)
        XCTAssertEqual(65, b.percent)
        XCTAssertTrue(b.charging)
        XCTAssertFalse(b.full)
        XCTAssertNil(TubeProtocol.parseBattery([0, 1, 2]))
    }

    func testSensorAngleIsShortIndexNine() {
        var pkt = [UInt8](repeating: 0, count: TubeProtocol.sensorPacketLength)
        pkt[18] = 0x01; pkt[19] = 0x2C // 300 big-endian at short index 9
        XCTAssertEqual(300, TubeProtocol.parseSensorAngle(pkt))
        pkt[18] = 0x01; pkt[19] = 0x68 // 360 is out of range
        XCTAssertNil(TubeProtocol.parseSensorAngle(pkt))
        XCTAssertNil(TubeProtocol.parseSensorAngle([UInt8](repeating: 0, count: 10)))
    }

    func testCommandBytesMatchVendorApp() {
        XCTAssertEqual([0x20, 0x36], TubeProtocol.startVideo)
        XCTAssertEqual([0x20, 0x37], TubeProtocol.stopVideo)
        XCTAssertEqual([0x66, 0x39, 1, 1], TubeProtocol.getBoardInfo)
        XCTAssertEqual([0x66, 0x3A], TubeProtocol.getBattery)
        XCTAssertEqual([0x66, 0x3C, 42], TubeProtocol.setBrightness(42))
        XCTAssertEqual([0x66, 0x3C, 0xFF], TubeProtocol.commitBrightness)
        XCTAssertEqual([0x66, 0x3C, 0xFE], TubeProtocol.queryBrightness)
        XCTAssertEqual([0x66, 0x3F, 0, 1], TubeProtocol.triggerLed(0, on: true))
        XCTAssertEqual([0x86, 0x06, 1], TubeProtocol.toggleAngleStream(true))
    }

    func testBoardInfoCompletesOnClosingBrace() {
        let part = Array("{\"model\":\"ES\",".utf8)
        XCTAssertFalse(TubeProtocol.isBoardInfoComplete(part, length: part.count))
        let whole = Array("{\"model\":\"ES\"}".utf8)
        XCTAssertTrue(TubeProtocol.isBoardInfoComplete(whole, length: whole.count))
    }

    func testBoardInfoParsing() {
        let text = #"{"brand":"bebird","model":"R1","firmware":"1.2.3","ssid":"bebird-R1-630136","float_angle":1,"rotate_angle":"90"}"#
        let info = TubeDiscovery.parseBoardInfo(host: "192.168.5.1", text: text)!
        XCTAssertEqual(.tube, info.cameraProtocol)
        XCTAssertEqual("R1", info.model)
        XCTAssertEqual("1.2.3", info.firmware)
        XCTAssertEqual("bebird-R1-630136", info.ssid)
        XCTAssertTrue(info.floatAngle)
        XCTAssertEqual(90, info.rotateAngle)
        XCTAssertEqual(text, info.rawInfo)
        XCTAssertEqual("Bebird R1", info.displayName)

        let prefixOnly = TubeDiscovery.parseBoardInfo(host: "h", text: #"{"ssid":"","ssid_prefix":"bebird","float_angle":false}"#)!
        XCTAssertEqual("bebird", prefixOnly.ssid)
        XCTAssertFalse(prefixOnly.floatAngle)
        XCTAssertNil(TubeDiscovery.parseBoardInfo(host: "h", text: "not json"))
    }
}

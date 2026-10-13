@testable import EarDiggerKit
import XCTest

final class MlProtocolTests: XCTestCase {
    func testRequestLayoutMatchesNativeLibrary() {
        let r = MlProtocol.request(MlProtocol.cmdSetLight, sequence: 7, parameter: 55)
        XCTAssertEqual(24, r.count)
        // 99 99 | 16 10 | 07 00 00 00 | 37 00 00 00 | zeros
        XCTAssertEqual([0x99, 0x99, 0x16, 0x10, 7, 0, 0, 0, 55, 0, 0, 0] + [UInt8](repeating: 0, count: 12), r)
        let start = MlProtocol.videoControl(MlProtocol.videoStart)
        XCTAssertEqual([0x99, 0x99, 1, 0] + [UInt8](repeating: 0, count: 20), start)
    }

    func testReplyMatching() {
        var reply = [UInt8](repeating: 0, count: 12)
        Bytes.putU16le(&reply, 0, 0x9999)
        Bytes.putU16le(&reply, 2, UInt16(MlProtocol.cmdGetLight))
        Bytes.putU32le(&reply, 8, 42)
        XCTAssertTrue(MlProtocol.replyMatches(reply, length: reply.count, command: MlProtocol.cmdGetLight))
        XCTAssertFalse(MlProtocol.replyMatches(reply, length: reply.count, command: MlProtocol.cmdGetBattery))
        XCTAssertEqual(42, MlProtocol.replyInt(reply, length: reply.count))
        XCTAssertNil(MlProtocol.replyInt(reply, length: 8))
    }

    func testBatteryDecoding() {
        var reply = [UInt8](repeating: 0, count: 24)
        Bytes.putU16le(&reply, 0, 0x9999)
        Bytes.putU16le(&reply, 2, UInt16(MlProtocol.cmdGetBattery))
        Bytes.putU32le(&reply, 4, 1)
        Bytes.putU32le(&reply, 8, 0x10000 | 3900) // charging, 3900 mV
        Bytes.putU32le(&reply, 16, 0x10000 | 77) // direct percent present
        let b = MlProtocol.parseBattery(reply, length: reply.count)!
        XCTAssertTrue(b.charging)
        XCTAssertEqual(3900, b.millivolts)
        XCTAssertEqual(77, b.percentDirect)
        XCTAssertEqual(83, b.percentEstimate(model: nil)) // (3900-3400)/6
        XCTAssertEqual(66, b.percentEstimate(model: "Note3")) // (3900-3700)/3

        var noDirect = reply
        Bytes.putU32le(&noDirect, 16, 5)
        XCTAssertNil(MlProtocol.parseBattery(noDirect, length: noDirect.count)!.percentDirect)
    }

    static func boardInfoReply(_ json: String, corrupt: Bool = false) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 24 + 1024)
        Bytes.putU16le(&reply, 0, 0x9999)
        Bytes.putU16le(&reply, 2, UInt16(MlProtocol.cmdGetBoardInfo))
        let bytes = Array(json.utf8)
        reply.replaceSubrange(24..<(24 + bytes.count), with: bytes)
        var x: UInt8 = 0
        for i in 24..<(24 + 1024) { x ^= reply[i] }
        Bytes.putU32le(&reply, 8, UInt32(x ^ (corrupt ? 1 : 0)))
        Bytes.putU32le(&reply, 12, UInt32(bytes.count))
        return reply
    }

    func testBoardInfoChecksum() {
        let json = #"{"model":"M9 Pro","brand":"bebird"}"#
        let reply = Self.boardInfoReply(json)
        XCTAssertEqual(json, MlProtocol.parseBoardInfo(reply, length: reply.count))
        let bad = Self.boardInfoReply(json, corrupt: true)
        XCTAssertNil(MlProtocol.parseBoardInfo(bad, length: bad.count))

        let info = MlDiscovery.fromBoardInfo(host: MlProtocol.defaultHost, text: json)
        XCTAssertEqual("M9 Pro", info.model)
        XCTAssertEqual("Bebird M9 Pro", info.displayName)
    }

    func testObfuscatedIndexMatchesFormula() {
        // ((len ^ key) + len + (~len & 1)) ^ len, modulo len
        XCTAssertEqual(1, MlProtocol.obfuscatedIndex(key: 0, length: 10))
        XCTAssertEqual(0, MlProtocol.obfuscatedIndex(key: 123, length: 0))
        let key: UInt32 = 0x1234_5678
        let len: UInt32 = 48213
        let u = ((len ^ key) &+ len &+ (~len & 1)) ^ len
        XCTAssertEqual(Int(u % len), MlProtocol.obfuscatedIndex(key: key, length: Int(len)))
        XCTAssertTrue((0..<1000).contains(MlProtocol.obfuscatedIndex(key: UInt32(bitPattern: -5), length: 1000)))
        // Same value the 32-bit signed arithmetic of the vendor library gives.
        XCTAssertEqual(7799, MlProtocol.obfuscatedIndex(key: 0x5A5A_5A5A, length: 48213))
    }

    func testVideoChunkHeaderParses() {
        let d = Self.chunkDatagram(frameId: 9, frameLength: 5, index: 1, count: 1, payload: [1, 2, 3, 4, 5], key: 77, plain: false, angleRaw: 0xC000_0000 + 90_000)
        let c = MlProtocol.parseVideoChunk(d, length: d.count)!
        XCTAssertEqual(3, c.packetType)
        XCTAssertEqual(9, c.frameId)
        XCTAssertEqual(5, c.frameLength)
        XCTAssertEqual(1, c.chunkIndex)
        XCTAssertEqual(1, c.chunkCount)
        XCTAssertEqual(5, c.chunkLength)
        XCTAssertEqual(77, c.key)
        XCTAssertFalse(c.plain)
        XCTAssertNil(MlProtocol.parseVideoChunk(d, length: 20))
    }

    func testAngleDecoderAbsoluteAndNone() {
        let dec = MlProtocol.AngleDecoder()
        XCTAssertNil(dec.decode(0))
        XCTAssertNil(dec.decode(0x10001))
        XCTAssertEqual(90, dec.decode(0x8000_0000 | 90_000)!, accuracy: 0.001)
        XCTAssertEqual(123.456, dec.decode(0xC000_0000 | 123_456)!, accuracy: 0.001)
    }

    func testAngleDecoderAccelerometer() {
        let dec = MlProtocol.AngleDecoder()
        // x = 300, y = 300 (both positive, big enough) -> 45 degrees once it has settled
        let raw: UInt32 = (300 << 10) | 300
        _ = dec.decode(raw)
        XCTAssertEqual(45, dec.decode(raw)!, accuracy: 0.5)
    }

    static func chunkDatagram(
        frameId: Int,
        frameLength: Int,
        index: Int,
        count: Int,
        payload: [UInt8],
        key: UInt32,
        plain: Bool,
        angleRaw: UInt32 = 0,
        kind: UInt8 = 0
    ) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: MlProtocol.videoChunkHeaderLength + payload.count)
        Bytes.putU16le(&d, 0, 0x9999)
        Bytes.putU16le(&d, 2, 3)
        Bytes.putU32le(&d, 8, angleRaw)
        Bytes.putU32le(&d, 16, plain ? 1 : 0)
        d[24] = kind
        Bytes.putU32le(&d, 25, UInt32(truncatingIfNeeded: frameId))
        Bytes.putU32le(&d, 29, UInt32(truncatingIfNeeded: frameLength))
        Bytes.putU16le(&d, 33, UInt16(index))
        Bytes.putU16le(&d, 35, UInt16(count))
        Bytes.putU16le(&d, 37, UInt16(payload.count))
        Bytes.putU32le(&d, 39, 1234)
        Bytes.putU32le(&d, 47, key)
        d.replaceSubrange(MlProtocol.videoChunkHeaderLength..<d.count, with: payload)
        return d
    }
}

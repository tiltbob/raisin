@testable import EarDiggerKit
import XCTest

final class MlTcpStreamParserTests: XCTestCase {
    static func jpeg(_ size: Int) -> [UInt8] {
        var j = (0..<size).map { UInt8($0 * 13 % 251) }
        j[0] = 0xFF; j[1] = 0xD8; j[size - 2] = 0xFF; j[size - 1] = 0xD9
        return j
    }

    static func frame(_ data: [UInt8], trailing: Int = 0, angleRaw: UInt32 = 0, type: UInt8 = 0) -> [UInt8] {
        let payload = data + [UInt8](repeating: 0x55, count: trailing)
        var header = [UInt8](repeating: 0, count: MlProtocol.tcpFrameHeaderLength)
        header[1] = type
        header[2] = 1
        Bytes.putU32le(&header, 4, UInt32(payload.count))
        Bytes.putU32le(&header, 12, 42)
        Bytes.putU32le(&header, 20, angleRaw)
        Bytes.putU32le(&header, 24, 640)
        Bytes.putU32le(&header, 28, 480)
        var wire = payload
        wire[payload.count / 2] = ~wire[payload.count / 2]
        return MlProtocol.tcpStart + header + wire + MlProtocol.tcpEnd
    }

    func testParsesFramesAcrossReadBoundaries() {
        let d1 = Self.jpeg(3_000)
        let d2 = Self.jpeg(2_500)
        let stream = [UInt8](repeating: UInt8(ascii: "x"), count: 17) + Self.frame(d1, trailing: 3, angleRaw: 7) + Self.frame(d2)
        var got: [([UInt8], MlProtocol.TcpFrameHeader)] = []
        let parser = MlTcpStreamParser { j, h in got.append((j, h)) }
        var off = 0
        var n = 1
        while off < stream.count {
            let len = min(n, stream.count - off)
            parser.feed(Array(stream[off..<(off + len)]), count: len)
            off += len
            n = (n * 3) % 701 + 1
        }
        XCTAssertEqual(2, got.count)
        XCTAssertEqual(d1, got[0].0)
        XCTAssertEqual(7, got[0].1.angleRaw)
        XCTAssertEqual(640, got[0].1.width)
        XCTAssertEqual(d2, got[1].0)
        XCTAssertEqual(2, parser.framesCompleted)
    }

    func testRejectsNonVideoAndBadLength() {
        let f = Self.frame(Self.jpeg(1_000), type: 1) // audio
        var count = 0
        let parser = MlTcpStreamParser { _, _ in count += 1 }
        parser.feed(f, count: f.count)
        XCTAssertEqual(0, count)
        XCTAssertEqual(1, parser.framesRejected)
    }
}

@testable import EarDiggerKit
import XCTest

final class FrameAssemblerTests: XCTestCase {
    static func fakeJpeg(_ size: Int) -> [UInt8] {
        var jpeg = (0..<size).map { UInt8($0 % 251) }
        jpeg[0] = 0xFF; jpeg[1] = 0xD8
        jpeg[size - 2] = 0xFF; jpeg[size - 1] = 0xD9
        return jpeg
    }

    /// Split a JPEG into datagrams exactly as the camera does.
    static func chunk(_ jpeg: [UInt8], _ chunkSize: Int, frameId: Int, lastFlag: Int, angleLow: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var offset = 0
        var index = 1
        while offset < jpeg.count {
            let len = min(chunkSize, jpeg.count - offset)
            let last = offset + len >= jpeg.count
            var d: [UInt8] = [
                UInt8(truncatingIfNeeded: frameId),
                last ? UInt8(truncatingIfNeeded: lastFlag) : 0,
                UInt8(truncatingIfNeeded: index),
                last ? UInt8(truncatingIfNeeded: angleLow) : 0,
            ]
            d += jpeg[offset..<(offset + len)]
            out.append(d)
            offset += len
            index += 1
        }
        return out
    }

    private func feed(_ a: FrameAssembler, _ list: [[UInt8]]) -> FrameAssembler.Frame? {
        var frame: FrameAssembler.Frame?
        for d in list { frame = a.offer(d, length: d.count) ?? frame }
        return frame
    }

    func testReassemblesInOrder() {
        let jpeg = Self.fakeJpeg(10_000)
        let a = FrameAssembler()
        var frame: FrameAssembler.Frame?
        for d in Self.chunk(jpeg, 1400, frameId: 7, lastFlag: 1, angleLow: 90) {
            XCTAssertNil(frame)
            frame = a.offer(d, length: d.count)
        }
        XCTAssertEqual(jpeg, frame?.jpeg)
        XCTAssertEqual(90, frame?.angleDegrees)
        XCTAssertEqual(7, frame?.frameId)
        XCTAssertEqual(1, a.framesCompleted)
        XCTAssertEqual(0, a.framesDropped)
    }

    func testReassemblesOutOfOrder() {
        let jpeg = Self.fakeJpeg(6_000)
        let d = Self.chunk(jpeg, 1000, frameId: 1, lastFlag: 1, angleLow: 10)
        // first chunk must come first (it fixes the chunk size); shuffle the rest
        let frame = feed(FrameAssembler(), [d[0], d[5], d[2], d[1], d[4], d[3]])
        XCTAssertEqual(jpeg, frame?.jpeg)
    }

    func testAngleHighBitInIntegerMode() {
        let jpeg = Self.fakeJpeg(3_000)
        let frame = feed(FrameAssembler(floatAngle: false), Self.chunk(jpeg, 1000, frameId: 3, lastFlag: 2, angleLow: 44))
        XCTAssertEqual(300, frame?.angleDegrees)
    }

    func testAngleInFloatMode() {
        let jpeg = Self.fakeJpeg(3_000)
        // lastFlag carries the high byte: (0x0C << 8 | 0x4D) / 10 = 3149 / 10
        let frame = feed(FrameAssembler(floatAngle: true), Self.chunk(jpeg, 1000, frameId: 3, lastFlag: 0x0C, angleLow: 0x4D))
        XCTAssertEqual(314.9, frame!.angleDegrees, accuracy: 0.001)

        // lastFlag 15 means "no high byte"
        let frame2 = feed(FrameAssembler(floatAngle: true), Self.chunk(jpeg, 1000, frameId: 4, lastFlag: 15, angleLow: 123))
        XCTAssertEqual(12.3, frame2!.angleDegrees, accuracy: 0.001)
    }

    func testLostChunkDropsFrameAndRecovers() {
        let a = FrameAssembler()
        var d1 = Self.chunk(Self.fakeJpeg(5_000), 1000, frameId: 1, lastFlag: 1, angleLow: 0)
        d1.remove(at: 2) // lose chunk 3
        for d in d1 { XCTAssertNil(a.offer(d, length: d.count)) }

        let jpeg2 = Self.fakeJpeg(4_000)
        let frame = feed(a, Self.chunk(jpeg2, 1000, frameId: 2, lastFlag: 1, angleLow: 5))
        XCTAssertEqual(jpeg2, frame?.jpeg)
        XCTAssertEqual(1, a.framesDropped)
        XCTAssertEqual(1, a.framesCompleted)
    }

    func testPatchesMissingEoiMarker() {
        let jpeg = Self.fakeJpeg(2_000)
        let truncated = Array(jpeg[0..<(jpeg.count - 2)]) // camera cut the FF D9
        let frame = feed(FrameAssembler(), Self.chunk(truncated, 1000, frameId: 9, lastFlag: 1, angleLow: 0))
        XCTAssertEqual(jpeg, frame?.jpeg)
    }

    func testIgnoresTinyAndForeignDatagrams() {
        let a = FrameAssembler()
        XCTAssertNil(a.offer([1, 0, 1, 0], length: 4)) // header only
        let foreign: [UInt8] = [5, 1, 2, 0, 1, 2, 3] // chunk 2 of a frame we never started
        XCTAssertNil(a.offer(foreign, length: foreign.count))
        XCTAssertEqual(0, a.framesDropped)
    }

    func testOnlyTheGivenLengthIsRead() {
        // The receive buffer is larger than the datagram; bytes past the length are stale.
        let jpeg = Self.fakeJpeg(900)
        var d = Self.chunk(jpeg, 1000, frameId: 1, lastFlag: 1, angleLow: 0)[0]
        let length = d.count
        d += [UInt8](repeating: 0x55, count: 3000)
        XCTAssertEqual(jpeg, FrameAssembler().offer(d, length: length)?.jpeg)
    }
}

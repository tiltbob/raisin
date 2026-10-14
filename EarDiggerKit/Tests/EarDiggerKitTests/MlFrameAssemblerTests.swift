@testable import EarDiggerKit
import XCTest

final class MlFrameAssemblerTests: XCTestCase {
    static func jpeg(_ size: Int) -> [UInt8] {
        var j = (0..<size).map { UInt8($0 * 7 % 251) }
        j[0] = 0xFF; j[1] = 0xD8; j[size - 2] = 0xFF; j[size - 1] = 0xD9
        return j
    }

    /// Split like the camera: fixed chunk size, last chunk shorter, one byte inverted on the wire.
    static func datagrams(frameId: Int, _ data: [UInt8], chunkSize: Int, key: UInt32, plain: Bool) -> [[UInt8]] {
        var wire = data
        if !plain {
            let i = MlProtocol.obfuscatedIndex(key: key, length: data.count)
            wire[i] = ~wire[i]
        }
        let count = (wire.count + chunkSize - 1) / chunkSize
        return (0..<count).map { i in
            let part = Array(wire[(i * chunkSize)..<min(wire.count, (i + 1) * chunkSize)])
            return MlProtocolTests.chunkDatagram(frameId: frameId, frameLength: data.count, index: i + 1, count: count, payload: part, key: key, plain: plain)
        }
    }

    private func feed(_ a: MlFrameAssembler, _ list: [[UInt8]]) -> MlFrameAssembler.Frame? {
        var out: MlFrameAssembler.Frame?
        for d in list {
            let c = MlProtocol.parseVideoChunk(d, length: d.count)!
            out = a.offer(c, datagram: d) ?? out
        }
        return out
    }

    func testReassemblesAndDeobfuscates() {
        let data = Self.jpeg(10_000)
        let a = MlFrameAssembler()
        let frame = feed(a, Self.datagrams(frameId: 1, data, chunkSize: 2900, key: 0x5A5A_5A5A, plain: false))
        XCTAssertEqual(data, frame?.jpeg)
        XCTAssertEqual(1, a.framesCompleted)
    }

    func testPlainFramesAreNotTouched() {
        let data = Self.jpeg(4_000)
        let frame = feed(MlFrameAssembler(), Self.datagrams(frameId: 2, data, chunkSize: 1388, key: 99, plain: true))
        XCTAssertEqual(data, frame?.jpeg)
    }

    func testInterleavedFramesAndOutOfOrderChunks() {
        let d1 = Self.jpeg(6_000)
        let d2 = Self.jpeg(5_000)
        let l1 = Self.datagrams(frameId: 10, d1, chunkSize: 2900, key: 1, plain: false)
        let l2 = Self.datagrams(frameId: 11, d2, chunkSize: 2900, key: 2, plain: false)
        let a = MlFrameAssembler()
        var frames: [MlFrameAssembler.Frame] = []
        for d in [l1[2], l2[0], l1[0], l2[1], l1[1]] {
            if let f = a.offer(MlProtocol.parseVideoChunk(d, length: d.count)!, datagram: d) { frames.append(f) }
        }
        XCTAssertEqual(2, frames.count)
        XCTAssertEqual(11, frames[0].frameId)
        XCTAssertEqual(d2, frames[0].jpeg)
        XCTAssertEqual(10, frames[1].frameId)
        XCTAssertEqual(d1, frames[1].jpeg)
    }

    func testDropsStaleFrames() {
        let a = MlFrameAssembler(maxInFlight: 2)
        // first chunk of three different frames: the oldest is evicted
        for id in 1...3 {
            let d = Self.datagrams(frameId: id, Self.jpeg(6_000), chunkSize: 2900, key: UInt32(id), plain: true)[0]
            XCTAssertNil(a.offer(MlProtocol.parseVideoChunk(d, length: d.count)!, datagram: d))
        }
        XCTAssertEqual(1, a.framesDropped)
    }

    func testChangedChunkCountDoesNotCrash() {
        let a = MlFrameAssembler()
        let first = MlProtocolTests.chunkDatagram(frameId: 5, frameLength: 100, index: 1, count: 2, payload: [1, 2], key: 0, plain: true)
        let odd = MlProtocolTests.chunkDatagram(frameId: 5, frameLength: 100, index: 4, count: 4, payload: [3, 4], key: 0, plain: true)
        XCTAssertNil(a.offer(MlProtocol.parseVideoChunk(first, length: first.count)!, datagram: first))
        XCTAssertNil(a.offer(MlProtocol.parseVideoChunk(odd, length: odd.count)!, datagram: odd))
    }
}

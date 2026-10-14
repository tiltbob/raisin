/// Reassembles JPEG frames from the chunked datagrams the camera sends on the video port.
///
/// Every datagram is:
/// ```
///  byte 0   frame id            (all chunks of one frame share it; wraps at 255)
///  byte 1   last-chunk flag     (0 = more chunks follow; non-zero = final chunk,
///                                also carries angle high bits, see below)
///  byte 2   chunk index         (1-based)
///  byte 3   roll angle, low 8 bits (only meaningful on the final chunk)
///  byte 4.. JPEG data
/// ```
/// Chunks of one frame are all the same size except the last one, so the payload size of
/// chunk 1 fixes where every later chunk lands in the frame buffer. A frame is delivered only
/// when every chunk index from 1 to the final one was seen.
///
/// Angle encoding on the final chunk:
///  - integer mode (default):  `angle = b3 + (b1 == 2 ? 256 : 0)`  -> 0...359 degrees
///  - float mode (`float_angle` board flag): `angle = (b3 + (b1 != 15 ? b1 << 8 : 0)) / 10`
///
/// Not thread-safe: one receive loop feeds it.
public final class FrameAssembler {
    /// One complete JPEG frame.
    public struct Frame {
        public let jpeg: [UInt8]
        public let angleDegrees: Float
        public let frameId: Int
    }

    public var floatAngle: Bool

    private var frame: [UInt8]
    private var received = [Bool](repeating: false, count: 256)
    private var frameId = -1
    private var chunkSize = 0
    private var lastIndex = -1
    private var endOffset = -1
    private var angle: Float = 0

    public private(set) var framesCompleted = 0
    public private(set) var framesDropped = 0

    public init(floatAngle: Bool = false, maxFrameLength: Int = TubeProtocol.maxFrameLength) {
        self.floatAngle = floatAngle
        frame = [UInt8](repeating: 0, count: maxFrameLength)
    }

    public func reset() {
        for i in received.indices { received[i] = false }
        frameId = -1
        chunkSize = 0
        lastIndex = -1
        endOffset = -1
    }

    /// Feed one datagram (the first [length] bytes of [datagram]). Returns a completed frame,
    /// or nil if more chunks are needed (or the datagram was discarded).
    public func offer(_ datagram: [UInt8], length: Int) -> Frame? {
        let header = TubeProtocol.frameHeaderLength
        let payload = min(length, datagram.count) - header
        if payload <= 0 { return nil }

        let id = Int(datagram[0])
        let lastFlag = Int(datagram[1])
        let index = Int(datagram[2])
        if index < 1 { return nil }

        if index == 1 {
            // A new frame begins. Anything half-built is lost.
            if frameId >= 0 { framesDropped += 1 }
            reset()
            frameId = id
            chunkSize = payload
        } else if frameId < 0 || id != frameId {
            // Chunk of a frame whose start we never saw, or of a different frame: drop.
            if frameId >= 0 {
                framesDropped += 1
                reset()
            }
            return nil
        }

        if chunkSize <= 0 { return nil }
        let offset = (index - 1) * chunkSize
        if offset + payload > frame.count {
            framesDropped += 1
            reset()
            return nil
        }
        frame.replaceSubrange(offset..<(offset + payload), with: datagram[header..<(header + payload)])
        received[index - 1] = true

        if lastFlag != 0 {
            lastIndex = index
            angle = decodeAngle(lastFlag: lastFlag, low: Int(datagram[3]))
            endOffset = offset + payload
            if !endsWithEoi(endOffset) {
                // Some firmware truncates the EOI marker on a full-size last chunk; patch it in.
                if endOffset + 2 <= frame.count {
                    frame[endOffset] = 0xFF
                    frame[endOffset + 1] = 0xD9
                    endOffset += 2
                }
            }
        }

        if lastIndex > 0 {
            for i in 0..<lastIndex where !received[i] {
                // Chunks can arrive out of order; keep waiting until the next frame starts.
                return nil
            }
            if !startsWithSoi() {
                framesDropped += 1
                reset()
                return nil
            }
            let out = Frame(jpeg: Array(frame[0..<endOffset]), angleDegrees: angle, frameId: frameId)
            framesCompleted += 1
            reset()
            return out
        }
        return nil
    }

    private func decodeAngle(lastFlag: Int, low: Int) -> Float {
        if floatAngle {
            let raw = lastFlag != 15 ? low + (lastFlag << 8) : low
            return Float(raw) / 10
        }
        return Float(low + (lastFlag == 2 ? 256 : 0))
    }

    private func startsWithSoi() -> Bool {
        frame[0] == 0xFF && frame[1] == 0xD8
    }

    private func endsWithEoi(_ end: Int) -> Bool {
        end >= 2 && frame[end - 2] == 0xFF && frame[end - 1] == 0xD9
    }
}

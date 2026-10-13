/// Splits the TCP video stream (port 7060) into frames.
///
/// The stream is `BoundaryS` + 32-byte header + payload + `BoundaryE`, repeated. The parser
/// is a byte state machine exactly like the vendor library's: it hunts for the marker text,
/// accumulates everything after `BoundaryS`, and emits when `BoundaryE` closes the frame.
/// The payload's middle byte is inverted on the wire and restored here.
public final class MlTcpStreamParser {
    private static let markerPrefix = Array("Boundary".utf8)
    private static let startMarker = UInt8(ascii: "S")
    private static let endMarker = UInt8(ascii: "E")

    private let onFrame: ([UInt8], MlProtocol.TcpFrameHeader) -> Void
    private var buffer: [UInt8]
    private var length = 0
    private var state = 0
    private var accumulating = false

    public private(set) var framesCompleted = 0
    public private(set) var framesRejected = 0

    public init(
        maxFrameLength: Int = MlProtocol.maxFrameLength,
        onFrame: @escaping (_ jpeg: [UInt8], _ header: MlProtocol.TcpFrameHeader) -> Void
    ) {
        self.onFrame = onFrame
        buffer = [UInt8](repeating: 0, count: maxFrameLength + MlProtocol.tcpFrameHeaderLength + 16)
    }

    public func reset() {
        length = 0
        state = 0
        accumulating = false
    }

    public func feed(_ data: [UInt8], count: Int) {
        let prefix = Self.markerPrefix
        for i in 0..<min(count, data.count) {
            let b = data[i]
            if accumulating {
                if length < buffer.count {
                    buffer[length] = b
                    length += 1
                } else {
                    reset()
                }
            }
            if state < prefix.count {
                state = b == prefix[state] ? state + 1 : (b == prefix[0] ? 1 : 0)
            } else {
                switch b {
                case Self.startMarker:
                    length = 0
                    accumulating = true
                    state = 0
                case Self.endMarker:
                    if accumulating { complete() }
                    accumulating = false
                    state = 0
                default:
                    state = prefix.count
                }
            }
        }
    }

    private func complete() {
        let content = length - MlProtocol.tcpEnd.count
        if content < MlProtocol.tcpFrameHeaderLength { return }
        guard let header = MlProtocol.parseTcpFrameHeader(buffer, offset: 0, length: content) else { return }
        let payload = content - MlProtocol.tcpFrameHeaderLength
        if header.type != 0 || header.payloadLength != payload || payload <= 2 {
            framesRejected += 1
            return
        }
        let start = MlProtocol.tcpFrameHeaderLength
        buffer[start + payload / 2] = ~buffer[start + payload / 2]
        if buffer[start] != 0xFF || buffer[start + 1] != 0xD8 {
            framesRejected += 1
            return
        }
        // The camera may append a few bytes after the EOI marker; trim to it.
        var end = start + payload
        let floor = max(start + 2, end - 16)
        var k = end
        while k - 2 >= floor {
            if buffer[k - 2] == 0xFF && buffer[k - 1] == 0xD9 {
                end = k
                break
            }
            k -= 1
        }
        framesCompleted += 1
        onFrame(Array(buffer[start..<end]), header)
    }
}

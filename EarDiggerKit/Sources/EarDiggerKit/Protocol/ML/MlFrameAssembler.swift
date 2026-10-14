/// Reassembles JPEG frames from UDP video chunks ([MlProtocol.VideoChunk]).
///
/// Chunks of a frame may interleave with the next frame's, so up to [maxInFlight] frames are
/// tracked at once. A frame is delivered when all of its chunks have been seen; the single
/// inverted byte the camera inserts is restored unless the chunk header says the frame is plain.
///
/// Not thread-safe: one receive loop feeds it.
public final class MlFrameAssembler {
    public struct Frame {
        public let jpeg: [UInt8]
        public let frameId: Int
        public let angleRaw: UInt32
        public let kind: Int
    }

    private final class Pending {
        let chunk: MlProtocol.VideoChunk
        var parts: [[UInt8]?]
        var received = 0

        init(_ chunk: MlProtocol.VideoChunk) {
            self.chunk = chunk
            parts = Array(repeating: nil, count: chunk.chunkCount)
        }
    }

    private let maxInFlight: Int
    private var pending: [Int: Pending] = [:]
    /// Frame ids in the order their first chunk arrived (oldest first).
    private var order: [Int] = []

    public private(set) var framesCompleted = 0
    public private(set) var framesDropped = 0

    public init(maxInFlight: Int = 2) {
        self.maxInFlight = maxInFlight
    }

    public func reset() {
        pending.removeAll()
        order.removeAll()
    }

    /// Feed one datagram's parsed header plus its raw bytes. Returns a frame when complete.
    public func offer(_ chunk: MlProtocol.VideoChunk, datagram: [UInt8]) -> Frame? {
        guard chunk.packetType == MlProtocol.videoPacketType else { return nil }
        guard chunk.chunkCount > 0, (1...chunk.chunkCount).contains(chunk.chunkIndex) else { return nil }
        guard chunk.frameLength > 0, chunk.frameLength <= MlProtocol.maxFrameLength else { return nil }

        let p: Pending
        if let existing = pending[chunk.frameId] {
            p = existing
        } else {
            while pending.count >= maxInFlight, let oldest = order.first {
                order.removeFirst()
                pending[oldest] = nil
                framesDropped += 1
            }
            p = Pending(chunk)
            pending[chunk.frameId] = p
            order.append(chunk.frameId)
        }
        let slot = chunk.chunkIndex - 1
        // A chunk count that changed mid-frame would not fit the slots: ignore it.
        guard slot < p.parts.count, p.parts[slot] == nil else { return nil }
        let start = MlProtocol.videoChunkHeaderLength
        guard start + chunk.chunkLength <= datagram.count else { return nil }
        p.parts[slot] = Array(datagram[start..<(start + chunk.chunkLength)])
        p.received += 1
        if p.received < p.parts.count { return nil }

        pending[chunk.frameId] = nil
        order.removeAll { $0 == chunk.frameId }
        let total = p.parts.reduce(0) { $0 + ($1?.count ?? 0) }
        let length = min(total, p.chunk.frameLength)
        var jpeg = [UInt8]()
        jpeg.reserveCapacity(length)
        for part in p.parts {
            guard let part else { continue }
            let n = min(part.count, length - jpeg.count)
            if n <= 0 { break }
            jpeg += part[0..<n]
        }
        if !p.chunk.plain {
            let i = MlProtocol.obfuscatedIndex(key: p.chunk.key, length: p.chunk.frameLength)
            if jpeg.indices.contains(i) { jpeg[i] = ~jpeg[i] }
        }
        framesCompleted += 1
        return Frame(jpeg: jpeg, frameId: p.chunk.frameId, angleRaw: p.chunk.angleRaw, kind: p.chunk.frameKind)
    }
}

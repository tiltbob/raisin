import Foundation

/// Wire-level constants and codecs for the older "ML" generation of Bebird scopes, which the
/// vendor app drives through its native `libBBCameraLibs.so` (M9 Pro, X17 Pro, Note3, T15,
/// P30, D3, E3, C3/T5, B1 and friends). The camera is the Wi-Fi access point and always has
/// the address [defaultHost].
///
/// Three channels, all little-endian:
///  - commands:  UDP [commandPort] 50000, request/reply, 24-byte request header
///  - video:     UDP [videoPort] 8030, START/STOP + chunked JPEG frames (51-byte chunk header)
///  - video:     TCP [tcpVideoPort] 7060, `BoundaryS` + 32-byte header + JPEG + `BoundaryE`
/// The native library runs both video receivers at once and uses whichever delivers frames.
public enum MlProtocol {
    public static let defaultHost = "192.168.10.123"
    public static let commandPort: UInt16 = 50000
    public static let videoPort: UInt16 = 8030
    public static let tcpVideoPort: UInt16 = 7060

    public static let magic = 0x9999

    /// Request and reply header size on the command port.
    public static let commandLength = 24

    /// Largest command reply the vendor library accepts (board info).
    public static let maxCommandReply = 0x578

    /// Largest datagram on the video port.
    public static let maxVideoDatagram = 0xC00

    public static let videoChunkHeaderLength = 51
    public static let tcpFrameHeaderLength = 32
    public static let maxFrameLength = 1024 * 1024

    /// How often the video START must be repeated to keep the UDP stream flowing.
    public static let videoKeepAliveMs: Int64 = 600

    // ---- command ids (second header short) ---------------------------------
    public static let cmdGetVersion = 0x1002
    public static let cmdGetLight = 0x1015
    public static let cmdSetLight = 0x1016
    public static let cmdGetBattery = 0x1017
    public static let cmdPowerOff = 0x1019
    public static let cmdGetStaInfo = 0x101A
    public static let cmdGetPwmStatus = 0x101C
    public static let cmdSetPwmStatus = 0x101D
    public static let cmdSetTweezer = 0x1054
    public static let cmdGetBoardInfo = 0x1060

    // ---- video port control (same 24-byte shape, command 1 / 2) ------------
    public static let videoStart = 1
    public static let videoStop = 2

    /// Packet type of a UDP video chunk.
    public static let videoPacketType = 3

    /// Build a 24-byte request:
    /// ```
    ///  0  u16 magic 0x9999
    ///  2  u16 command
    ///  4  i32 sequence (any increasing number)
    ///  8  u32 parameter (set commands), else 0
    /// 12  zero padding to 24 bytes
    /// ```
    public static func request(_ command: Int, sequence: Int, parameter: Int = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: commandLength)
        Bytes.putU16le(&b, 0, UInt16(magic))
        Bytes.putU16le(&b, 2, UInt16(truncatingIfNeeded: command))
        Bytes.putU32le(&b, 4, UInt32(truncatingIfNeeded: sequence))
        Bytes.putU32le(&b, 8, UInt32(truncatingIfNeeded: parameter))
        return b
    }

    /// The video START/STOP datagrams carry the command in the second short and no sequence.
    public static func videoControl(_ command: Int) -> [UInt8] {
        request(command, sequence: 0)
    }

    /// True if [reply] echoes the magic and [command] we sent.
    public static func replyMatches(_ reply: [UInt8], length: Int, command: Int) -> Bool {
        guard min(length, reply.count) >= 4 else { return false }
        return Bytes.u16le(reply, 0) == magic && Bytes.u16le(reply, 2) == command
    }

    /// The 32-bit value most "get" replies carry at offset 8.
    public static func replyInt(_ reply: [UInt8], length: Int, offset: Int = 8) -> Int? {
        guard min(length, reply.count) >= offset + 4 else { return nil }
        return Bytes.i32le(reply, offset)
    }

    public struct Battery: Equatable, Sendable {
        /// Raw value from offset 8: bit 16 = charging, low 16 bits = millivolts.
        public let raw: UInt32
        /// Optional direct percentage from offset 16 (present when bit 16 of that word is set).
        public let percentDirect: Int?

        public var charging: Bool { (raw >> 16) & 1 != 0 }
        public var millivolts: Int { Int(raw & 0xFFFF) }

        /// Percent as the vendor app estimates it from the cell voltage (default curve).
        public func percentEstimate(model: String? = nil) -> Int {
            let m = model?.lowercased() ?? ""
            let v: Float
            if m.contains("note3") {
                v = Float(millivolts - 3700) / 3
            } else if m == "r3" {
                v = Float(millivolts - 3600) / 3
            } else {
                v = Float(millivolts - 3400) / 6
            }
            return min(max(Int(v), 0), 100)
        }
    }

    public static func parseBattery(_ reply: [UInt8], length: Int) -> Battery? {
        guard min(length, reply.count) >= 20 else { return nil }
        let raw = Bytes.u32le(reply, 8)
        let extra = Bytes.u32le(reply, 16)
        let direct = extra & 0x10000 != 0 ? Int(extra & 0xFFFF) : nil
        return Battery(raw: raw, percentDirect: direct)
    }

    /// Board-info reply:
    /// ```
    ///  0  u16 magic, 2 u16 command
    ///  8  u32 checksum: XOR of the 1024 bytes at offset 24
    /// 12  i32 length of the JSON document
    /// 24  JSON document (NUL padded)
    /// ```
    /// Returns the JSON text or nil if the checksum fails.
    public static func parseBoardInfo(_ reply: [UInt8], length: Int) -> String? {
        let length = min(length, reply.count)
        guard length >= 24 else { return nil }
        let checksum = reply[8]
        let jsonLength = Bytes.i32le(reply, 12)
        guard jsonLength > 0, 24 + jsonLength <= length else { return nil }
        var x: UInt8 = 0
        for i in 24..<min(length, 24 + 1024) { x ^= reply[i] }
        guard x == checksum else { return nil }
        let text = String(decoding: reply[24..<(24 + jsonLength)], as: UTF8.self)
        if let nul = text.firstIndex(of: "\u{0}") { return String(text[..<nul]) }
        return text
    }

    /// One datagram of the UDP video stream:
    /// ```
    ///  2  u16 packetType       (3 = video chunk)
    ///  8  u32 angleRaw         (orientation word, see [AngleDecoder])
    /// 16  u32 plainFlag        (0 = one byte of the frame is inverted, see [obfuscatedIndex])
    /// 24  u8  frameKind        (3 = key / still frame that must not be dropped)
    /// 25  u32 frameId
    /// 29  u32 frameLength      (bytes of the whole JPEG)
    /// 33  u16 chunkIndex       (1-based)
    /// 35  u16 chunkCount
    /// 37  u16 chunkLength      (payload bytes in this datagram)
    /// 39  u32 timestamp
    /// 47  u32 key              (input to [obfuscatedIndex])
    /// 51  payload
    /// ```
    public struct VideoChunk: Sendable {
        public let packetType: Int
        public let angleRaw: UInt32
        public let plain: Bool
        public let frameKind: Int
        public let frameId: Int
        public let frameLength: Int
        public let chunkIndex: Int
        public let chunkCount: Int
        public let chunkLength: Int
        public let timestamp: UInt32
        public let key: UInt32
    }

    public static func parseVideoChunk(_ data: [UInt8], length: Int) -> VideoChunk? {
        let length = min(length, data.count)
        guard length >= videoChunkHeaderLength else { return nil }
        let chunkLength = Bytes.u16le(data, 37)
        guard videoChunkHeaderLength + chunkLength <= length else { return nil }
        return VideoChunk(
            packetType: Bytes.u16le(data, 2),
            angleRaw: Bytes.u32le(data, 8),
            plain: Bytes.u32le(data, 16) != 0,
            frameKind: Int(data[24]),
            frameId: Bytes.i32le(data, 25),
            frameLength: Bytes.i32le(data, 29),
            chunkIndex: Bytes.u16le(data, 33),
            chunkCount: Bytes.u16le(data, 35),
            chunkLength: chunkLength,
            timestamp: Bytes.u32le(data, 39),
            key: Bytes.u32le(data, 47)
        )
    }

    /// The camera flips one byte of every UDP frame; this is its position. Port of the
    /// library's `encode_index(key, length)` (32-bit wrapping arithmetic).
    public static func obfuscatedIndex(key: UInt32, length: Int) -> Int {
        if length == 0 { return 0 }
        let len = UInt32(truncatingIfNeeded: length)
        let u = ((len ^ key) &+ len &+ (~len & 1)) ^ len
        return Int(u % len)
    }

    /// Boundary markers of the TCP stream.
    public static let tcpStart = Array("BoundaryS".utf8)
    public static let tcpEnd = Array("BoundaryE".utf8)

    /// Header of one TCP frame (follows `BoundaryS`):
    /// ```
    ///  1  u8  type (0 = video)
    ///  2  u8  index (0 is treated as 1)
    ///  4  u32 payload length
    /// 12  u32 frame number
    /// 20  u32 angleRaw
    /// 24  u32 width, 28 u32 height (video only)
    /// 32  payload: JPEG whose middle byte (payload[length / 2]) is inverted
    /// ```
    public struct TcpFrameHeader: Sendable {
        public let type: Int
        public let index: Int
        public let payloadLength: Int
        public let frameNumber: Int
        public let angleRaw: UInt32
        public let width: Int
        public let height: Int
    }

    public static func parseTcpFrameHeader(_ data: [UInt8], offset: Int, length: Int) -> TcpFrameHeader? {
        guard min(length, data.count) - offset >= tcpFrameHeaderLength else { return nil }
        let index = Int(data[offset + 2])
        return TcpFrameHeader(
            type: Int(data[offset + 1]),
            index: index == 0 ? 1 : index,
            payloadLength: Bytes.i32le(data, offset + 4),
            frameNumber: Bytes.i32le(data, offset + 12),
            angleRaw: Bytes.u32le(data, offset + 20),
            width: Bytes.i32le(data, offset + 24),
            height: Bytes.i32le(data, offset + 28)
        )
    }

    /// Stateful port of the library's `getDegree()`; returns degrees, or nil when unknown.
    /// Not thread-safe.
    public final class AngleDecoder {
        private var lastStable: Float = 0
        private var lastSeen: Float = 0
        private var changes = 0

        public init() {}

        public func decode(_ raw: UInt32) -> Float? {
            let top = raw >> 30
            if top >= 2 {
                // Absolute angle in thousandths of a degree.
                return fmodf(Float(raw & 0x3FFF_FFFF) / 1000, 360)
            }
            if raw == 0 || raw == 0x10001 { return nil }
            // Three 10-bit sign-magnitude-ish accelerometer axes.
            let xi = raw & 0x3FF
            let yi = (raw >> 10) & 0x3FF
            let zi = raw >> 20
            let fx: Float = xi < 0x200 ? Float(xi) : 1024 - Float(xi)
            let fy: Float = yi < 0x200 ? Float(yi) : 1024 - Float(yi)
            let fz: Float = (raw >> 29) == 0 ? Float(zi) : 1024 - Float(zi)
            var a = atan(Double(fy / fx))
            if xi > 0x200 { a = .pi - a }
            if yi > 0x200 { a = 2 * .pi - a }
            let angle = Float(a)
            let threshold: Float = fz < 25 ? 0.04 : 0.009
            if abs(angle - lastSeen) <= threshold {
                changes = 0
            } else {
                lastSeen = angle
                changes += 1
            }
            let result: Float
            if fx >= 64 || fy >= 64 {
                if angle == 0 || changes < 1 {
                    result = lastStable
                } else {
                    lastStable = angle
                    result = angle
                }
            } else {
                lastSeen = 0
                result = lastStable
            }
            return Float(Double(result) * 180 / .pi)
        }
    }
}

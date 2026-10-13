/// Wire-level constants and codecs for the "tube" generation of Bebird Wi-Fi scopes
/// (the devices the vendor app drives from its pure-Java `BebirdTube` class:
/// ES, ESU, UltraX, Note5, R1, R3, M9, X17 and friends on the 192.168.5.1 /
/// 192.168.10.1 access points).
///
/// Transport: UDP, all to the camera's IP.
///  - [videoPort]   58080  start/stop video and MJPEG chunk stream
///  - [commandPort] 58090  request/reply commands (battery, board info, light...)
///  - [sensorPort]  58098  optional orientation sensor stream
///  - [beaconPort]  58099  JSON status beacon broadcast by the camera
public enum TubeProtocol {
    public static let videoPort: UInt16 = 58080
    public static let commandPort: UInt16 = 58090
    public static let sensorPort: UInt16 = 58098
    public static let beaconPort: UInt16 = 58099

    /// Access-point addresses the vendor app hard-codes for this generation.
    public static let knownHosts = ["192.168.5.1", "192.168.10.1"]

    /// Datagram payload limit used by the camera.
    public static let maxDatagram = 4096

    /// Header prepended to each MJPEG chunk on the video port.
    public static let frameHeaderLength = 4

    /// Upper bound for one reassembled JPEG frame.
    public static let maxFrameLength = 512 * 1024

    // ---- video port (58080) -------------------------------------------------
    public static let startVideo: [UInt8] = [0x20, 0x36]
    public static let stopVideo: [UInt8] = [0x20, 0x37]

    // ---- command port (58090) -----------------------------------------------
    /// Reply is a JSON document that may span several datagrams; it ends with '}'.
    public static let getBoardInfo: [UInt8] = [0x66, 0x39, 0x01, 0x01]

    /// Reply is a 4-byte big-endian int: high 16 bits = state, low 16 bits = percent.
    public static let getBattery: [UInt8] = [0x66, 0x3A]

    /// Set the tip light level 0...100. Takes effect once [commitBrightness] is sent.
    public static func setBrightness(_ level: Int) -> [UInt8] {
        precondition((0...100).contains(level), "brightness must be 0...100, was \(level)")
        return [0x66, 0x3C, UInt8(level)]
    }

    /// Apply the previously sent brightness level.
    public static let commitBrightness: [UInt8] = [0x66, 0x3C, 0xFF]

    /// Ask for the current brightness; reply is one byte 0...100.
    public static let queryBrightness: [UInt8] = [0x66, 0x3C, 0xFE]

    /// Camera image effect selector (0 = normal).
    public static func setCameraEffect(_ effect: Int) -> [UInt8] {
        [0x66, 0x3B, UInt8(truncatingIfNeeded: effect)]
    }

    /// LED trigger. The vendor app sends (0, on) when the camera screen opens and (0, off)
    /// when it closes, which turns the tip light on at the saved level / off.
    /// (2, on) / (2, off) drive the blue status LED.
    public static func triggerLed(_ which: Int, on: Bool) -> [UInt8] {
        [0x66, 0x3F, UInt8(truncatingIfNeeded: which), on ? 1 : 0]
    }

    /// Named "reboot" in the vendor app; on most units it powers the scope off.
    public static let reboot: [UInt8] = [0x66, 0x3E]

    /// Tweezer / accessory status (1 = plain tip, 2 = tweezer tip).
    public static func setTweezerStatus(_ status: Int) -> [UInt8] {
        [0x66, 0x40, UInt8(truncatingIfNeeded: status)]
    }

    // ---- sensor port (58098) ------------------------------------------------
    /// Start (on) or stop (off) the 34-byte orientation sensor stream.
    public static func toggleAngleStream(_ on: Bool) -> [UInt8] {
        [0x86, 0x06, on ? 1 : 0]
    }

    /// Index of the roll angle (0...359) inside the sensor packet when read as big-endian shorts.
    public static let sensorAngleIndex = 9
    public static let sensorPacketLength = 34

    // ---- codecs -------------------------------------------------------------

    public struct Battery: Equatable, Sendable {
        public let state: Int
        public let percent: Int
        public var charging: Bool { state == 2 }
        public var full: Bool { state == 3 }
        /// State 4 means the scope is powering down / handing off.
        public var disconnecting: Bool { state == 4 }
    }

    /// Decode a battery reply. Nil if the datagram is too short.
    public static func parseBattery(_ data: [UInt8], length: Int? = nil) -> Battery? {
        guard min(length ?? data.count, data.count) >= 4 else { return nil }
        let v = Bytes.u32be(data, 0)
        return Battery(state: Int(v >> 16), percent: Int(v & 0xFFFF))
    }

    /// Decode the roll angle from a sensor datagram, or nil if it is not a valid packet.
    public static func parseSensorAngle(_ data: [UInt8], length: Int? = nil) -> Int? {
        guard min(length ?? data.count, data.count) >= (sensorAngleIndex + 1) * 2 else { return nil }
        let angle = Bytes.i16be(data, sensorAngleIndex * 2)
        return (0...359).contains(angle) ? angle : nil
    }

    /// True once a (possibly multi-datagram) board-info reply is complete.
    public static func isBoardInfoComplete(_ buffer: [UInt8], length: Int) -> Bool {
        length > 0 && buffer[length - 1] == UInt8(ascii: "}")
    }
}

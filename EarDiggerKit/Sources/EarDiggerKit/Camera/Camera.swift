import Foundation

/// Which wire protocol a camera speaks.
public enum CameraProtocol: String, Codable, Sendable {
    /// Pure-UDP "tube" protocol on ports 58080/58090 (ES, ESU, UltraX, Note5, R1, R3...).
    case tube = "TUBE"

    /// Older "ML" protocol implemented by the vendor's native library (M9 Pro, X17 Pro, Note3, T15...).
    case ml = "ML"
}

/// What we know about a camera before and after connecting.
public struct DeviceInfo: Codable, Hashable, Identifiable, Sendable {
    public var host: String
    public var cameraProtocol: CameraProtocol
    public var model: String?
    public var firmware: String?
    public var ssid: String?
    public var brand: String?
    /// Frame-header angle uses the tenth-of-a-degree encoding.
    public var floatAngle: Bool
    /// Fixed rotation the vendor app applies for this unit, in degrees.
    public var rotateAngle: Int
    /// The raw board-info JSON document, if the device reported one.
    public var rawInfo: String?

    public init(
        host: String,
        cameraProtocol: CameraProtocol,
        model: String? = nil,
        firmware: String? = nil,
        ssid: String? = nil,
        brand: String? = nil,
        floatAngle: Bool = false,
        rotateAngle: Int = 0,
        rawInfo: String? = nil
    ) {
        self.host = host
        self.cameraProtocol = cameraProtocol
        self.model = model
        self.firmware = firmware
        self.ssid = ssid
        self.brand = brand
        self.floatAngle = floatAngle
        self.rotateAngle = rotateAngle
        self.rawInfo = rawInfo
    }

    public var id: String { "\(cameraProtocol.rawValue)@\(host)" }

    /// `Bebird R1`: from the board info when we have it, else from the Wi-Fi name, else the address.
    public var displayName: String {
        if let name = CameraWifi.prettyName(brand: brand, model: model) { return name }
        let fromSsid = CameraWifi.prettyName(ssid: ssid)
        return fromSsid.isEmpty ? host : fromSsid
    }

    private enum CodingKeys: String, CodingKey {
        case host, cameraProtocol = "protocol", model, firmware, ssid, brand, floatAngle, rotateAngle, rawInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        cameraProtocol = (try? c.decode(CameraProtocol.self, forKey: .cameraProtocol)) ?? .tube
        model = try c.decodeIfPresent(String.self, forKey: .model)
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
        ssid = try c.decodeIfPresent(String.self, forKey: .ssid)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        floatAngle = try c.decodeIfPresent(Bool.self, forKey: .floatAngle) ?? false
        rotateAngle = try c.decodeIfPresent(Int.self, forKey: .rotateAngle) ?? 0
        rawInfo = try c.decodeIfPresent(String.self, forKey: .rawInfo)
    }
}

/// One decode-ready JPEG frame plus the roll angle reported with it.
public struct VideoFrame: Sendable {
    public let jpeg: [UInt8]
    public let angleDegrees: Float
    /// Monotonic milliseconds when the frame was completed.
    public let receivedAtMs: Int64

    public init(jpeg: [UInt8], angleDegrees: Float, receivedAtMs: Int64) {
        self.jpeg = jpeg
        self.angleDegrees = angleDegrees
        self.receivedAtMs = receivedAtMs
    }
}

public struct BatteryStatus: Equatable, Sendable {
    public let percent: Int
    public let charging: Bool
    /// Protocol-specific raw state value, for diagnostics.
    public let rawState: Int

    public init(percent: Int, charging: Bool, rawState: Int) {
        self.percent = percent
        self.charging = charging
        self.rawState = rawState
    }
}

public enum ConnectionState: Sendable { case idle, connected, streaming, closed }

public enum CameraError: Error, CustomStringConvertible {
    case notConnected
    case badAddress(String)

    public var description: String {
        switch self {
        case .notConnected: return "connect() first"
        case .badAddress(let host): return "not an IPv4 address: \(host)"
        }
    }
}

/// A live link to one camera. Implementations talk only to [DeviceInfo.host]; nothing else
/// on the network is ever contacted.
///
/// The blocking calls ([close]) must not run on the main thread.
public protocol CameraClient: AnyObject, Sendable {
    var info: DeviceInfo { get }

    /// Completed frames. Only the newest couple are buffered: a slow consumer skips frames
    /// rather than falling behind the live picture.
    var frames: AsyncStream<VideoFrame> { get }

    /// Battery readings, about once a second while streaming.
    var battery: AsyncStream<BatteryStatus> { get }

    /// Open sockets. Must be called before [start].
    func connect() async throws

    /// Start the video stream (and whatever keep-alive the device needs).
    func start() async throws

    /// Stop the video stream but keep the connection.
    func stop() async

    /// Tip light level, 0...100.
    func setLight(_ percent: Int) async

    /// Current tip light level, or nil if the device does not report it.
    func getLight() async -> Int?

    /// Ask the camera for its board info and adopt what matters for the stream (the angle
    /// encoding, the battery curve). Nil if it does not answer.
    func refreshInfo() async -> DeviceInfo?

    /// Stop everything and release the sockets. Blocks briefly while loops wind down.
    func close()
}

/// Picks the client implementation for a device.
public enum CameraClients {
    public static func create(_ info: DeviceInfo, binding: SocketBinding = .none) -> CameraClient {
        switch info.cameraProtocol {
        case .tube: return TubeCameraClient(info: info, binding: binding)
        case .ml: return MlCameraClient(info: info, binding: binding)
        }
    }
}

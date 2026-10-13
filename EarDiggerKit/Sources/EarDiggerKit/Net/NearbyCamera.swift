/// A scope heard over the air (or remembered), before we have joined its Wi-Fi.
public struct NearbyCamera: Equatable, Identifiable, Sendable {
    /// The Wi-Fi network name (also the BLE advertised name).
    public var ssid: String
    /// Core Bluetooth's identifier for the advertiser. iOS never reveals the radio address,
    /// so unlike on Android it cannot be turned into the access point's BSSID.
    public var bluetoothID: String?
    public var seenByBluetooth: Bool
    /// Signal strength in dBm from the last advertisement.
    public var rssi: Int?
    /// Joined before (see [KnownScope]); listed even when no radio hears it right now.
    public var remembered: Bool
    public var lastJoinedMs: Int64?

    public init(
        ssid: String,
        bluetoothID: String? = nil,
        seenByBluetooth: Bool = false,
        rssi: Int? = nil,
        remembered: Bool = false,
        lastJoinedMs: Int64? = nil
    ) {
        self.ssid = ssid
        self.bluetoothID = bluetoothID
        self.seenByBluetooth = seenByBluetooth
        self.rssi = rssi
        self.remembered = remembered
        self.lastJoinedMs = lastJoinedMs
    }

    public var id: String { ssid.lowercased() }

    /// Heard by a radio during this scan, as opposed to only remembered.
    public var heard: Bool { seenByBluetooth }

    /// `Bebird R1` for `bebird-R1-630136`.
    public var displayName: String { CameraWifi.prettyName(ssid: ssid) }

    public var security: CameraWifi.Security { CameraWifi.security(forSsid: ssid) }

    public func merge(_ other: NearbyCamera) -> NearbyCamera {
        var m = self
        m.bluetoothID = other.bluetoothID ?? bluetoothID
        m.seenByBluetooth = seenByBluetooth || other.seenByBluetooth
        m.rssi = other.rssi ?? rssi
        m.remembered = remembered || other.remembered
        m.lastJoinedMs = other.lastJoinedMs ?? lastJoinedMs
        return m
    }
}

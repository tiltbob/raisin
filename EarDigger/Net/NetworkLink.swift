import EarDiggerKit
import Foundation
import Network
import NetworkExtension

/// Joins the scope's Wi-Fi and keeps track of the phone's Wi-Fi interface.
///
/// The scope's access point has no internet, so iOS may keep the phone's default route on
/// cellular. Every camera socket is therefore pinned to the Wi-Fi interface through
/// [binding] (the Android app's `Network.bindSocket`). Ways onto the scope's network:
///  - [join]: the scope found by [NearbyScanner] (what the vendor app's auto-connect does),
///    through `NEHotspotConfiguration`; iOS asks once and remembers the network;
///  - [joinByPrefix]: any network whose name starts with a prefix, when Bluetooth cannot
///    hear the scope;
///  - the user joins it in Settings › Wi-Fi, after which discovery finds the camera.
@MainActor
final class NetworkLink {
    private static let tag = "NetworkLink"

    enum Status: String { case none, requesting, joined, failed }

    enum JoinResult {
        case joined
        /// The user declined iOS's "Join Wi-Fi network?" question.
        case declined
        /// This build cannot configure Wi-Fi (no Hotspot Configuration entitlement) or iOS
        /// refused for an internal reason.
        case unsupported(String)
        case failed(String)
    }

    // NEHotspotConfigurationError codes (stable since iOS 11).
    private static let errorDomain = "NEHotspotConfigurationErrorDomain"
    private static let errorUserDenied = 7
    private static let errorInternal = 8
    private static let errorAlreadyAssociated = 13

    private(set) var status = Status.none
    /// The SSID the current join targets, for display; nil for a prefix join.
    private(set) var targetSsid: String?

    /// The Wi-Fi interface as Network.framework reports it, and whether its path is usable.
    private(set) var wifiInterfaceName: String?
    private(set) var wifiInterfaceIndex: Int?
    private(set) var wifiPathUp = false

    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

    init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let wifi = path.availableInterfaces.first { $0.type == .wifi }
            let up = path.status == .satisfied
            let name = wifi?.name
            let index = wifi?.index
            Task { @MainActor [weak self] in self?.pathChanged(up: up, name: name, index: index) }
        }
        monitor.start(queue: DispatchQueue(label: "eardigger.wifi-path"))
    }

    private func pathChanged(up: Bool, name: String?, index: Int?) {
        if up != wifiPathUp || name != wifiInterfaceName {
            DebugLog.log(Self.tag, "wifi path: \(up ? "up" : "down") interface=\(name ?? "-") address=\(wifiAddress?.description ?? "-")")
        }
        wifiPathUp = up
        wifiInterfaceName = name
        wifiInterfaceIndex = index
        onChange?()
    }

    // ---- joining ------------------------------------------------------------

    /// Join the given scope's Wi-Fi. iOS shows its own "Join Wi-Fi network?" question the
    /// first time and remembers the network after that.
    func join(_ camera: NearbyCamera) async -> JoinResult {
        targetSsid = camera.ssid
        DebugLog.log(Self.tag, "join(ssid=\(camera.ssid) security=\(camera.security) bt=\(camera.bluetoothID ?? "-"))")
        let config: NEHotspotConfiguration
        switch camera.security {
        case .open:
            config = NEHotspotConfiguration(ssid: camera.ssid)
        case .wpa:
            config = NEHotspotConfiguration(ssid: camera.ssid, passphrase: CameraWifi.defaultPassphrase, isWEP: false)
        }
        config.joinOnce = false
        return await apply(config, label: camera.ssid)
    }

    /// Join the first network in range whose name starts with [prefix].
    func joinByPrefix(_ prefix: String) async -> JoinResult {
        targetSsid = nil
        DebugLog.log(Self.tag, "joinByPrefix(\"\(prefix)\")")
        let config = NEHotspotConfiguration(ssidPrefix: prefix)
        config.joinOnce = false
        return await apply(config, label: "\(prefix)…")
    }

    private func apply(_ config: NEHotspotConfiguration, label: String) async -> JoinResult {
        status = .requesting
        onChange?()
        let error: Error? = await withCheckedContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(config) { error in continuation.resume(returning: error) }
        }
        let result: JoinResult
        if let error = error as NSError? {
            let isHotspot = error.domain == Self.errorDomain
            DebugLog.log(Self.tag, "apply(\(label)) failed: \(error.domain) \(error.code) \(error.localizedDescription)")
            if isHotspot && error.code == Self.errorAlreadyAssociated {
                result = .joined
            } else if isHotspot && error.code == Self.errorUserDenied {
                result = .declined
            } else if isHotspot && error.code == Self.errorInternal {
                result = .unsupported(error.localizedDescription)
            } else {
                result = .failed(error.localizedDescription)
            }
        } else {
            DebugLog.log(Self.tag, "apply(\(label)) accepted; wifi=\(wifiAddress?.description ?? "no address yet")")
            result = .joined
        }
        if case .joined = result { status = .joined } else { status = .failed }
        onChange?()
        return result
    }

    /// Drop the Wi-Fi configuration EarDigger saved for [ssid] (iOS only lets an app remove
    /// its own).
    func forget(_ ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        DebugLog.log(Self.tag, "removed the Wi-Fi configuration for \(ssid)")
    }

    /// The Wi-Fi network's name when iOS tells us (it does for networks this app joined);
    /// nil otherwise.
    func currentSsid() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in continuation.resume(returning: network?.ssid) }
        }
    }

    // ---- the Wi-Fi interface -------------------------------------------------

    /// The IPv4 address of the Wi-Fi interface, once DHCP has given it one.
    var wifiAddress: IPv4Interface? {
        let name = wifiInterfaceName ?? "en0"
        return NetInterfaces.active().first { $0.name == name && !$0.isLinkLocal }
    }

    /// Pins sockets to the Wi-Fi interface; the default route when it is unknown.
    func binding() -> SocketBinding {
        guard let name = wifiInterfaceName, let index = wifiInterfaceIndex, index > 0 else {
            if let address = wifiAddress {
                let index = if_nametoindex(address.name)
                if index > 0 { return SocketBinding(interfaceName: address.name, interfaceIndex: index) }
            }
            return .none
        }
        return SocketBinding(interfaceName: name, interfaceIndex: UInt32(index))
    }

    /// Our own IPv4 address on the Wi-Fi, for display.
    func localAddress() -> String? { wifiAddress?.address }

    /// Addresses likely to be the camera besides the well-known ones: the first host of the
    /// Wi-Fi subnet, which on the scope's own network is the access point, i.e. the camera.
    func candidateHosts() -> [String] {
        [wifiAddress?.firstHost].compactMap { $0 }
    }

    /// One-line summary for the debug log.
    func describe() -> String {
        "  wifi path=\(wifiPathUp ? "up" : "down") interface=\(wifiInterfaceName ?? "-")#\(wifiInterfaceIndex.map(String.init) ?? "-") address=\(wifiAddress?.description ?? "-") all=\(NetInterfaces.summary())"
    }
}

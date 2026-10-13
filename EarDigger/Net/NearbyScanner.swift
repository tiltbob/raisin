import CoreBluetooth
import EarDiggerKit
import Foundation

/// Finds scopes that are switched on nearby, the way the vendor app does: a Bluetooth LE
/// scan for advertisements whose name starts with a known prefix (the scope's BLE name is
/// its Wi-Fi SSID). Only listening; nothing is connected or sent.
///
/// The Android app also reads the Wi-Fi scan results; iOS has no such API for apps.
@MainActor
final class NearbyScanner: NSObject {
    private static let tag = "Nearby"

    private(set) var cameras: [NearbyCamera] = []
    private(set) var scanning = false
    /// Human-readable reasons Bluetooth could not be used in the last scan.
    private(set) var notes: [String] = []

    var namePrefixes = CameraWifi.defaultNamePrefixes
    var onChange: (() -> Void)?

    private var central: CBCentralManager?
    private var wantScan = false
    private var stopTask: Task<Void, Never>?
    private var duration: TimeInterval = 8
    private var seen = Set<UUID>()
    private var hits = 0

    /// True when scanning will not make iOS ask for the Bluetooth permission.
    var mayScanWithoutPrompt: Bool { CBManager.authorization == .allowedAlways }

    var authorizationDescription: String {
        switch CBManager.authorization {
        case .allowedAlways: return "granted"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    var stateDescription: String {
        guard let central else { return "not started" }
        switch central.state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    /// Scan for [duration] seconds, merging hits into [cameras]. The first call may make
    /// iOS ask for the Bluetooth permission.
    func start(duration: TimeInterval = 8) {
        stop()
        cameras = []
        seen.removeAll()
        hits = 0
        notes = []
        self.duration = duration
        wantScan = true
        scanning = true
        DebugLog.log(Self.tag, "start(): prefixes=\(namePrefixes) duration=\(Int(duration))s bluetooth=\(authorizationDescription)")
        if central == nil {
            // The state arrives in centralManagerDidUpdateState, which starts the scan.
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            beginIfReady()
        }
        // Gives up on its own when Bluetooth never becomes ready (permission prompt ignored).
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((duration + 2) * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
        onChange?()
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        let wasScanning = scanning
        wantScan = false
        if let central, central.state == .poweredOn, central.isScanning { central.stopScan() }
        scanning = false
        if wasScanning {
            DebugLog.log(Self.tag, "stop(): ble advertisements=\(hits) distinct=\(seen.count), cameras=\(cameras.map(\.ssid))")
            onChange?()
        }
    }

    private func beginIfReady() {
        guard wantScan, let central else { return }
        switch central.state {
        case .poweredOn:
            guard !central.isScanning else { return }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DebugLog.log(Self.tag, "ble: scan started (no filters)")
            stopTask?.cancel()
            let seconds = duration
            stopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { self?.stop() }
            }
        case .poweredOff:
            give(up: Strings.bluetoothOff)
        case .unauthorized:
            give(up: Strings.bluetoothDenied)
        case .unsupported:
            give(up: Strings.bluetoothUnsupported)
        case .resetting, .unknown:
            break // another state update follows
        @unknown default:
            break
        }
    }

    private func give(up note: String) {
        DebugLog.log(Self.tag, "ble: \(note)")
        notes = [note]
        stop()
        onChange?()
    }

    private func onAdvertisement(id: UUID, name: String?, rssi: Int) {
        guard scanning else { return }
        hits += 1
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if seen.insert(id).inserted {
            DebugLog.log(Self.tag, "ble: seen \(id.uuidString.prefix(8)) name=\(name ?? "-") rssi=\(rssi)")
        }
        guard let name, !name.isEmpty, CameraWifi.looksLikeCamera(name, prefixes: namePrefixes) else { return }
        DebugLog.log(Self.tag, "ble: CAMERA \(name) (\(id.uuidString))")
        add(NearbyCamera(ssid: name, bluetoothID: id.uuidString, seenByBluetooth: true, rssi: rssi))
    }

    private func add(_ camera: NearbyCamera) {
        var list = cameras
        if let i = list.firstIndex(where: { $0.ssid.caseInsensitiveCompare(camera.ssid) == .orderedSame }) {
            list[i] = list[i].merge(camera)
        } else {
            list.append(camera)
        }
        cameras = list.sorted { ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }
        onChange?()
    }
}

extension NearbyScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state.rawValue
        Task { @MainActor in
            DebugLog.log(Self.tag, "ble: state \(state) (\(self.stateDescription))")
            self.beginIfReady()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // The advertised name needs no connection, unlike the GAP name behind peripheral.name.
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in self.onAdvertisement(id: id, name: name, rssi: rssi) }
    }
}

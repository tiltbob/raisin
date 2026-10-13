import EarDiggerKit
import Foundation
import SwiftUI

/// State and flow of the connect screen. The scope is always its own Wi-Fi access point,
/// so the only flow is: hear it over Bluetooth, join its network, find the camera on that
/// network, open the viewer.
@MainActor
final class AppModel: ObservableObject {
    private static let tag = "Main"
    /// How long to keep looking for the camera after joining: iOS takes a few seconds to
    /// associate and get an address, and the first packets fail until the user has answered
    /// the local-network question.
    private static let findPatience: TimeInterval = 25
    private static let debugTailLines = 12

    let link = NetworkLink()
    let scanner = NearbyScanner()
    let known = KnownScopes()
    private let shake = ShakeDetector()

    @Published private(set) var listing: [NearbyCamera] = []
    @Published private(set) var status = Strings.nearbyIdle
    @Published private(set) var notes: [String] = []
    @Published private(set) var scanning = false
    /// True between asking iOS to join a scope's Wi-Fi and opening the viewer.
    @Published private(set) var pendingJoin = false
    /// Presents the viewer while set.
    @Published var viewerDevice: DeviceInfo?
    @Published private(set) var debugVisible = false
    @Published private(set) var debugTail = ""
    @Published var toast: String?

    private var findTask: Task<Void, Never>?
    /// Only rejoin the remembered scope by itself once per launch, so leaving the viewer does
    /// not bounce straight back into it.
    private var autoJoinDone = false
    private var debugRefreshQueued = false

    init() {
        DebugLog.log("App", "remembered scopes: \(known.scopes.map(\.ssid))")
        scanner.onChange = { [weak self] in self?.scannerChanged() }
        known.onChange = { [weak self] _ in self?.refreshList() }
        shake.onShake = { [weak self] in self?.revealDebug() }
        DebugLog.shared.onChange = { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.queueDebugRefresh() }
        }
        refreshList()
    }

    var busy: Bool { scanning || pendingJoin }

    // ---- lifecycle -----------------------------------------------------------

    /// The connect screen is showing (launch, back from the background, viewer closed).
    func screenShown() {
        DebugLog.log(Self.tag, "shown: link=\(link.status.rawValue) bluetooth=\(scanner.authorizationDescription) pendingJoin=\(pendingJoin) wifi=\(link.localAddress() ?? "-")")
        shake.start()
        // Listen right away when we already may; never prompt without a tap.
        if scanner.mayScanWithoutPrompt && !scanner.scanning && !pendingJoin && viewerDevice == nil {
            startNearbyScan()
        }
        if !autoJoinDone && !pendingJoin { checkCurrentWifi() }
    }

    func screenHidden() {
        shake.stop()
        scanner.stop()
    }

    /// When iOS says the phone is already on a scope's Wi-Fi (joined in Settings, or iOS
    /// rejoined it by itself), go straight to the camera.
    private func checkCurrentWifi() {
        guard link.wifiAddress != nil else { return }
        Task {
            guard let ssid = await link.currentSsid() else { return }
            DebugLog.log(Self.tag, "current Wi-Fi: \(ssid)")
            guard CameraWifi.looksLikeCamera(ssid), !autoJoinDone, !pendingJoin, viewerDevice == nil else { return }
            autoJoinDone = true
            known.remember(ssid)
            pendingJoin = true
            scanner.stop()
            findCameraOnJoinedNetwork(CameraWifi.prettyName(ssid: ssid), rememberAs: ssid)
        }
    }

    // ---- nearby scopes ---------------------------------------------------------

    func findNearby() {
        DebugLog.log(Self.tag, "tap: Find nearby (bluetooth \(scanner.authorizationDescription))")
        autoJoinDone = false
        startNearbyScan()
    }

    private func startNearbyScan() {
        scanner.namePrefixes = CameraWifi.defaultNamePrefixes
        scanner.start()
    }

    private func scannerChanged() {
        let heard = scanner.cameras
        scanning = scanner.scanning
        notes = scanner.notes.isEmpty || scanning ? scanner.notes : scanner.notes + [Strings.noWifiScanNote]
        refreshList()
        if !pendingJoin && !heard.isEmpty { status = Strings.nearbyFound(heard.count) }
        // The scope we used last time is switched on again: rejoin it without a tap.
        guard let last = known.lastUsed, !autoJoinDone, !pendingJoin, viewerDevice == nil,
              let match = heard.first(where: { $0.ssid.caseInsensitiveCompare(last.ssid) == .orderedSame }) else { return }
        autoJoinDone = true
        DebugLog.log(Self.tag, "heard the last used scope \(match.ssid): rejoining")
        connectAndOpen(last.complete(match))
    }

    /// Heard scopes first, then remembered ones nobody hears yet.
    private func refreshList() {
        listing = KnownScope.listing(heard: scanner.cameras, scopes: known.scopes)
        if !pendingJoin && !scanner.scanning { status = idleStatus() }
        if scanner.scanning && !pendingJoin { status = scanner.cameras.isEmpty ? Strings.nearbyScanning : Strings.nearbyFound(scanner.cameras.count) }
    }

    /// What to say under the list when nothing is in progress.
    private func idleStatus() -> String {
        let heard = scanner.cameras.count
        let remembered = known.scopes.count
        if heard > 0 { return Strings.nearbyFound(heard) }
        if remembered > 0 { return Strings.nearbyRemembered(remembered) }
        return Strings.nearbyNone
    }

    /// Join the scope's Wi-Fi, then look for the camera on it.
    func connectAndOpen(_ camera: NearbyCamera) {
        scanner.stop()
        pendingJoin = true
        known.remember(camera.ssid)
        let name = camera.displayName.isEmpty ? camera.ssid : camera.displayName
        status = Strings.nearbyConnecting(name)
        findTask?.cancel()
        findTask = Task {
            let result = await link.join(camera)
            guard !Task.isCancelled else { return }
            switch result {
            case .joined:
                findCameraOnJoinedNetwork(name, rememberAs: camera.ssid)
            case .declined:
                finishJoin(Strings.nearbyJoinDeclined(name))
            case .unsupported:
                finishJoin(Strings.nearbyJoinUnsupported(camera.ssid))
            case .failed(let reason):
                finishJoin(Strings.nearbyJoinFailed(name, reason))
            }
        }
    }

    func forget(_ camera: NearbyCamera) {
        known.forget(camera.ssid)
        link.forget(camera.ssid)
    }

    /// Fallback when Bluetooth cannot hear the scope: let iOS join whatever bebird… network
    /// is in range.
    func joinByPrefix() {
        DebugLog.log(Self.tag, "tap: Join any bebird Wi-Fi")
        scanner.stop()
        pendingJoin = true
        status = Strings.nearbyConnecting(Strings.theScope)
        findTask?.cancel()
        findTask = Task {
            let result = await link.joinByPrefix(CameraWifi.defaultNamePrefixes[0])
            guard !Task.isCancelled else { return }
            switch result {
            case .joined:
                let ssid = await link.currentSsid()
                findCameraOnJoinedNetwork(ssid.map { CameraWifi.prettyName(ssid: $0) } ?? Strings.theScope, rememberAs: ssid)
            case .declined:
                finishJoin(Strings.nearbyJoinDeclined(Strings.theScope))
            case .unsupported:
                finishJoin(Strings.nearbyJoinUnsupported("the scope's network (bebird…)"))
            case .failed(let reason):
                finishJoin(Strings.nearbyJoinFailed(Strings.theScope, reason))
            }
        }
    }

    /// The user joined the scope's Wi-Fi in Settings: look for the camera on the current network.
    func findOnCurrentWifi() {
        DebugLog.log(Self.tag, "tap: Find the camera on the current Wi-Fi (\(link.localAddress() ?? "no address"))")
        guard link.wifiAddress != nil else {
            status = Strings.nearbyNoWifi
            return
        }
        scanner.stop()
        pendingJoin = true
        findTask?.cancel()
        findTask = Task {
            let ssid = await link.currentSsid()
            if let ssid, CameraWifi.looksLikeCamera(ssid) { known.remember(ssid) }
            findCameraOnJoinedNetwork(ssid.map { CameraWifi.prettyName(ssid: $0) } ?? Strings.theScope, rememberAs: ssid, patience: 8)
        }
    }

    // ---- joined network ----------------------------------------------------------

    /// The phone is on the scope's own network: ask it for the camera and open the viewer.
    /// [rememberAs] is the SSID to file the camera's details under, when we know it.
    private func findCameraOnJoinedNetwork(_ name: String, rememberAs: String?, patience: TimeInterval = AppModel.findPatience) {
        findTask?.cancel()
        status = Strings.nearbyLooking(name)
        findTask = Task {
            let remembered = known.forSsid(rememberAs)?.device
            let deadline = Date().addingTimeInterval(patience)
            var found: [DeviceInfo] = []
            var round = 0
            repeat {
                round += 1
                // The camera's address from last time goes first in line, in case the network's
                // first address is not the camera itself.
                var hosts = [String]()
                for h in [remembered?.host].compactMap({ $0 }) + link.candidateHosts() where !hosts.contains(h) { hosts.append(h) }
                DebugLog.log(Self.tag, "looking on \(name) (round \(round)): local=\(link.localAddress() ?? "-") candidates=\(hosts) remembered=\(remembered.map { "\($0.host)/\($0.cameraProtocol.rawValue)/\($0.model ?? "-")" } ?? "-")")
                if link.wifiAddress != nil {
                    found = await CameraDiscovery.scan(binding: link.binding(), extraHosts: hosts)
                }
                if !found.isEmpty || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while Date() < deadline && !Task.isCancelled
            guard !Task.isCancelled else { return }
            guard var first = found.first else {
                finishJoin(Strings.nearbyNoCamera(name))
                return
            }
            // A beacon-only answer says less than the board info we kept from last time.
            if first.rawInfo == nil, let remembered, remembered.rawInfo != nil, remembered.host == first.host {
                first = remembered
            }
            if let rememberAs { known.learn(rememberAs, device: first) }
            finishJoin(Strings.nearbyFound(1))
            openCamera(first)
        }
    }

    private func finishJoin(_ message: String) {
        pendingJoin = false
        status = message
    }

    private func openCamera(_ info: DeviceInfo) {
        DebugLog.log(Self.tag, "open camera \(info.host) \(info.cameraProtocol.rawValue)")
        // Hearing the scope again after the viewer closes must not reopen it by itself.
        autoJoinDone = true
        shake.stop()
        viewerDevice = info
    }

    /// The viewer went away; [reason] is why, when it was not the user's doing.
    func viewerClosed(_ reason: String?) {
        viewerDevice = nil
        if let reason { toast = reason }
        shake.start()
    }

    // ---- debug card ------------------------------------------------------------

    private func revealDebug() {
        guard !debugVisible, viewerDevice == nil else { return }
        DebugLog.log(Self.tag, "rage shake: debug card revealed")
        debugTail = DebugLog.tail(Self.debugTailLines)
        debugVisible = true
        toast = Strings.debugRevealed
    }

    func hideDebug() {
        DebugLog.log(Self.tag, "tap: Hide debug")
        debugVisible = false
    }

    private func queueDebugRefresh() {
        guard debugVisible, !debugRefreshQueued else { return }
        // Lines can arrive in bursts; refresh the card at most a few times a second.
        debugRefreshQueued = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            debugRefreshQueued = false
            if debugVisible { debugTail = DebugLog.tail(Self.debugTailLines) }
        }
    }

    func shareReportFile() -> URL? {
        DebugLog.log(Self.tag, "tap: Share log")
        do {
            return try DebugReport.file(self)
        } catch {
            DebugLog.log(Self.tag, "share failed", error)
            return nil
        }
    }

    func copyReport() {
        DebugReport.copy(self)
        toast = Strings.debugCopied
    }

    func clearLog() {
        DebugLog.clear()
        debugTail = ""
    }
}

import Foundation

/// A scope the app has joined before, remembered so the next time is quicker:
///  - it is listed as soon as the app opens, before any radio has heard it, so a tap can
///    ask iOS for its Wi-Fi straight away;
///  - the camera's address and board info let discovery go straight to it.
public struct KnownScope: Codable, Equatable, Sendable {
    public var ssid: String
    /// What the camera said about itself on that network, the last time we found it.
    public var device: DeviceInfo?
    public var lastJoinedMs: Int64

    public init(ssid: String, device: DeviceInfo? = nil, lastJoinedMs: Int64 = 0) {
        self.ssid = ssid
        self.device = device
        self.lastJoinedMs = lastJoinedMs
    }

    /// What to show in the nearby list when no radio has heard this scope (yet).
    public func asNearby() -> NearbyCamera {
        NearbyCamera(ssid: ssid, remembered: true, lastJoinedMs: lastJoinedMs)
    }

    /// A sighting of this scope, marked as remembered.
    public func complete(_ camera: NearbyCamera) -> NearbyCamera {
        var c = camera
        c.remembered = true
        c.lastJoinedMs = lastJoinedMs
        return c
    }

    /// How many scopes to keep; the least recently joined fall off the end.
    public static let max = 8

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Record a join of the scope named [ssid] at [nowMs], most recently joined first.
    public static func remember(_ scopes: [KnownScope], ssid: String, nowMs: Int64) -> [KnownScope] {
        var updated = scopes.first { same($0.ssid, ssid) } ?? KnownScope(ssid: ssid)
        updated.lastJoinedMs = nowMs
        let rest = scopes
            .filter { !same($0.ssid, ssid) }
            .sorted { $0.lastJoinedMs > $1.lastJoinedMs }
            .prefix(max - 1)
        return [updated] + rest
    }

    /// Attach what the camera on [ssid]'s network reported about itself.
    public static func learn(_ scopes: [KnownScope], ssid: String, device: DeviceInfo) -> [KnownScope] {
        scopes.map { s in
            guard same(s.ssid, ssid) else { return s }
            var c = s
            c.device = device
            return c
        }
    }

    public static func forget(_ scopes: [KnownScope], ssid: String) -> [KnownScope] {
        scopes.filter { !same($0.ssid, ssid) }
    }

    /// The list to show: everything the radios hear now (strongest first), marked when
    /// remembered, then remembered scopes nobody has heard yet (most recently used first).
    public static func listing(heard: [NearbyCamera], scopes: [KnownScope]) -> [NearbyCamera] {
        var bySsid: [String: KnownScope] = [:]
        for s in scopes where bySsid[s.ssid.lowercased()] == nil { bySsid[s.ssid.lowercased()] = s }
        let live = heard.map { cam in bySsid[cam.ssid.lowercased()]?.complete(cam) ?? cam }
        let heardSsids = Set(heard.map { $0.ssid.lowercased() })
        let silent = scopes
            .filter { !heardSsids.contains($0.ssid.lowercased()) }
            .sorted { $0.lastJoinedMs > $1.lastJoinedMs }
            .map { $0.asNearby() }
        return live + silent
    }
}

/// The scopes this phone has joined, kept in the app's private defaults. Nothing in here
/// ever leaves the phone; it is a few network names and addresses, the same ones the debug
/// log shows.
public final class KnownScopes {
    private static let key = "known_scopes"

    private let defaults: UserDefaults
    public private(set) var scopes: [KnownScope]

    /// Called after every change.
    public var onChange: (([KnownScope]) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scopes = Self.load(defaults)
    }

    /// The scope joined most recently, which the app rejoins by itself when it hears it.
    public var lastUsed: KnownScope? { scopes.max { $0.lastJoinedMs < $1.lastJoinedMs } }

    public func forSsid(_ ssid: String?) -> KnownScope? {
        guard let ssid else { return nil }
        return scopes.first { $0.ssid.caseInsensitiveCompare(ssid) == .orderedSame }
    }

    public func remember(_ ssid: String) {
        update(KnownScope.remember(scopes, ssid: ssid, nowMs: Self.nowMs()))
    }

    public func learn(_ ssid: String, device: DeviceInfo) {
        update(KnownScope.learn(scopes, ssid: ssid, device: device))
    }

    public func forget(_ ssid: String) {
        DebugLog.log("Known", "forget \(ssid)")
        update(KnownScope.forget(scopes, ssid: ssid))
    }

    private func update(_ list: [KnownScope]) {
        scopes = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
        onChange?(list)
    }

    private static func load(_ defaults: UserDefaults) -> [KnownScope] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([KnownScope].self, from: data).filter { !CameraWifi.isBlank($0.ssid) }
        } catch {
            DebugLog.log("Known", "could not read remembered scopes, starting over", error)
            return []
        }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

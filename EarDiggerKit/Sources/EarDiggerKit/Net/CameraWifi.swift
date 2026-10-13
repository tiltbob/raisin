import Foundation

/// How Bebird scopes advertise themselves, mirroring the vendor app.
public enum CameraWifi {
    /// Advertised names (BLE device name == Wi-Fi SSID) start with one of these.
    public static let defaultNamePrefixes = ["bebird", "xlife"]

    /// The only passphrase the vendor app ever uses, for the few models with a secured AP.
    public static let defaultPassphrase = "12345678"

    /// Model tokens (second part of `brand-Model-1234`) whose access point is WPA protected.
    private static let securedModels: Set<String> = ["w3", "e3", "se", "max22"]
    private static let securedModelPrefixes = ["elite14"]

    public enum Security: Sendable {
        case open
        /// WPA2 or WPA3 personal with [defaultPassphrase].
        case wpa
    }

    public static func looksLikeCamera(_ name: String?, prefixes: [String] = defaultNamePrefixes) -> Bool {
        guard let name, !isBlank(name) else { return false }
        let n = name.lowercased()
        return prefixes.contains { !isBlank($0) && n.hasPrefix($0.lowercased()) }
    }

    /// Whether an SSID belongs to a model whose AP needs [defaultPassphrase]. The vendor app
    /// looks at the token after the first `-` (or `_`), e.g. `bebird-W3-1234`.
    public static func isSecuredBySsid(_ ssid: String?) -> Bool {
        guard let ssid, !isBlank(ssid) else { return false }
        func token(_ separator: Character) -> String? {
            let parts = ssid.split(separator: separator, omittingEmptySubsequences: false)
            guard parts.count > 1, !isBlank(String(parts[1])) else { return nil }
            return String(parts[1])
        }
        guard let model = token("-") ?? token("_") else { return false }
        let m = model.replacingOccurrences(of: " ", with: "").lowercased()
        return securedModels.contains(m) || securedModelPrefixes.contains { m.hasPrefix($0) }
    }

    /// iOS cannot list Wi-Fi networks, so the security comes from the model in the name.
    public static func security(forSsid ssid: String?) -> Security {
        isSecuredBySsid(ssid) ? .wpa : .open
    }

    /// A name fit for the screen: `bebird-R1-630136` -> `Bebird R1`, `xlife_W3_1A2B` -> `Xlife W3`,
    /// `Bebird M9 Pro` -> `Bebird M9 Pro`. Trailing unit numbers (all digits, or four or more
    /// hex characters) are dropped; the raw SSID still tells two units of one model apart.
    public static func prettyName(ssid: String?) -> String {
        guard let ssid, !isBlank(ssid) else { return "" }
        var tokens = trim(ssid)
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
            .filter { !isBlank($0) }
        while tokens.count > 1, let last = tokens.last, isUnitNumber(last) { tokens.removeLast() }
        return tokens.enumerated().map { i, t in i == 0 ? prettyBrand(t) : t }.joined(separator: " ")
    }

    /// `bebird` + `R1` -> `Bebird R1`; nil when neither is known.
    public static func prettyName(brand: String?, model: String?) -> String? {
        let parts = [
            brand.map(trim).flatMap { isBlank($0) ? nil : prettyBrand($0) },
            model.map(trim).flatMap { isBlank($0) ? nil : $0 },
        ].compactMap { $0 }
        let joined = parts.joined(separator: " ")
        return isBlank(joined) ? nil : joined
    }

    private static func prettyBrand(_ brand: String) -> String {
        let lower = brand.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    private static func isUnitNumber(_ token: String) -> Bool {
        token.allSatisfy(isDigit) ||
            (token.count >= 4 && token.allSatisfy { isDigit($0) || "abcdef".contains($0.lowercased()) })
    }

    private static func isDigit(_ c: Character) -> Bool {
        ("0"..."9").contains(c)
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isBlank(_ s: String) -> Bool { trim(s).isEmpty }
}

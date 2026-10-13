import Foundation

/// Reads the small JSON documents the cameras send (board info, beacons) with the
/// forgiving accessors of Android's org.json, which the Android app relies on: a missing,
/// null or blank value reads as absent, numbers read as text where text is expected, and
/// flags may be booleans, 0/1 or "true".
enum JSON {
    /// The top-level object of [text]. Firmware text that strict parsing rejects is tried
    /// once more after trimming it to the outer braces and dropping NULs and trailing commas.
    static func object(_ text: String) -> [String: Any]? {
        if let o = parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return o }
        var cleaned = String(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        guard let open = cleaned.firstIndex(of: "{"), let close = cleaned.lastIndex(of: "}"), open < close else { return nil }
        cleaned = String(cleaned[open...close])
        cleaned = cleaned.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return parse(cleaned)
    }

    private static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The value as text, or nil when missing, null or blank.
    static func string(_ o: [String: Any], _ key: String) -> String? {
        guard let v = o[key] else { return nil }
        let text: String
        switch v {
        case let s as String: text = s
        case is NSNull: return nil
        case let n as NSNumber: text = numberText(n)
        case let b as Bool: text = b ? "true" : "false"
        case let i as Int: text = String(i)
        case let d as Double: text = String(d)
        default: return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func int(_ o: [String: Any], _ key: String, default fallback: Int = 0) -> Int {
        guard let v = o[key] else { return fallback }
        switch v {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite { return Int(d) }
            return fallback
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        case let d as Double where d.isFinite: return Int(d)
        default: return fallback
        }
    }

    /// The firmware writes some flags as booleans and some as 0/1.
    static func flag(_ o: [String: Any], _ key: String) -> Bool {
        guard let v = o[key] else { return false }
        switch v {
        case let s as String: return s.caseInsensitiveCompare("true") == .orderedSame || s == "1"
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let i as Int: return i != 0
        case let d as Double: return d != 0
        default: return false
        }
    }

    private static func numberText(_ n: NSNumber) -> String {
        let d = n.doubleValue
        if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return n.stringValue
    }
}

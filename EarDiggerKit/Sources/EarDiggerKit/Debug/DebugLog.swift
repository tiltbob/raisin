import Foundation

/// In-memory diagnostic log shared by every part of the app. Plain Swift so the protocol
/// code can write to it; the app installs a [sink] that mirrors lines to the system log
/// and an [onChange] hook so the debug card can refresh.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()

    private static let maxLines = 4000

    private let lock = NSLock()
    private var lines: [String] = []
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var _version = 0
    private var _sink: ((String, String) -> Void)?
    private var _onChange: (() -> Void)?

    /// Bumps on every line, so the UI knows when to refresh.
    public var version: Int {
        lock.lock()
        defer { lock.unlock() }
        return _version
    }

    /// Mirrors every line elsewhere (the system log). Called outside the log's lock.
    public var sink: ((String, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }

    /// Called after every change, on whichever thread logged.
    public var onChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }

    public static func log(_ tag: String, _ message: String) {
        shared.log(tag, message)
    }

    public static func log(_ tag: String, _ message: String, _ error: Error) {
        shared.log(tag, "\(message): \(type(of: error)): \(error)")
    }

    public func log(_ tag: String, _ message: String) {
        lock.lock()
        lines.append("\(timeFormat.string(from: Date())) \(tag): \(message)")
        // Trim in batches so a full log does not shift 4000 lines on every call.
        if lines.count > Self.maxLines + 200 { lines.removeFirst(lines.count - Self.maxLines) }
        _version += 1
        let sink = _sink
        let onChange = _onChange
        lock.unlock()
        sink?(tag, message)
        onChange?()
    }

    public func tail(_ count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: "\n")
    }

    public func dump() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(Self.maxLines).joined(separator: "\n")
    }

    public func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return min(lines.count, Self.maxLines)
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        _version += 1
        let onChange = _onChange
        lock.unlock()
        onChange?()
    }

    public static func tail(_ count: Int) -> String { shared.tail(count) }
    public static func dump() -> String { shared.dump() }
    public static func size() -> Int { shared.size() }
    public static func clear() { shared.clear() }

    /// Short hex preview of a datagram for the log.
    public static func hex(_ data: [UInt8], length: Int, max: Int = 16) -> String {
        let n = Swift.min(length, max, data.count)
        var s = data[0..<n].map { byte -> String in
            let h = String(byte, radix: 16)
            return h.count == 1 ? "0" + h : h
        }.joined(separator: " ")
        if length > max { s += " … (\(length) bytes)" }
        return s
    }
}

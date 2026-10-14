import EarDiggerKit
import Foundation
import MetricKit

/// Keeps the last crash in the app's private files, so the debug report after a restart can
/// show it. Two sources: Objective-C exceptions, caught as they happen (with the log tail),
/// and the crash diagnostics iOS itself hands the app through MetricKit on the next launch.
/// Nothing is sent anywhere.
enum CrashRecord {
    private static let fileName = "last-crash.txt"
    private static let maxLength = 24_000

    static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func install() {
        if let previous = read() {
            let head = previous.split(separator: "\n").prefix(3).joined(separator: " | ")
            DebugLog.log("App", "the previous run crashed: \(head)")
        }
        NSSetUncaughtExceptionHandler(recordUncaughtException)
        MXMetricManager.shared.add(CrashDiagnostics.shared)
    }

    static func read() -> String? {
        guard let url = fileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ text: String) {
        guard let url = fileURL else { return }
        try? String(text.prefix(maxLength)).write(to: url, atomically: true, encoding: .utf8)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.string(from: date)
    }
}

private func recordUncaughtException(_ exception: NSException) {
    let text = """
    \(CrashRecord.timestamp()) \(AppInfo.version) uncaught \(exception.name.rawValue): \(exception.reason ?? "")
    \(exception.callStackSymbols.joined(separator: "\n"))
    log tail at the time:
    \(DebugLog.tail(40))
    """
    CrashRecord.write(text)
}

/// Receives iOS's crash reports for earlier runs (delivered at the next launch on iOS 15+).
private final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let json = String(decoding: crash.jsonRepresentation(), as: UTF8.self)
                CrashRecord.write("\(CrashRecord.timestamp(payload.timeStampEnd)) crash reported by iOS (MetricKit):\n\(json)")
                DebugLog.log("App", "iOS reported a crash of an earlier run; it is in the debug report")
            }
        }
    }
}

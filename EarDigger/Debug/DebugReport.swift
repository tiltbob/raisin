import CoreBluetooth
import EarDiggerKit
import Foundation
import Photos
import UIKit

/// Assembles the shareable debug report: environment summary plus the [DebugLog].
@MainActor
enum DebugReport {
    static func build(_ model: AppModel) -> String {
        var s = ""
        func line(_ text: String = "") { s += text + "\n" }
        line("EarDigger debug report")
        line("generated: \(CrashRecord.timestamp())")
        line("app: \(AppInfo.bundleId) \(AppInfo.version)")
        line("device: \(AppInfo.device)")
        line()
        line("permissions:")
        line("  bluetooth: \(model.scanner.authorizationDescription)")
        line("  photos (add only): \(photosDescription)")
        line("  local network: iOS does not tell apps; while it is not allowed, sends fail with \"No route to host\"")
        line()
        line("radios:")
        line("  bluetooth: \(model.scanner.stateDescription)")
        line()
        let link = model.link
        line("network link: status=\(link.status.rawValue) target=\(link.targetSsid ?? "-") local=\(link.localAddress() ?? "-") candidates=\(link.candidateHosts()) binding=\(link.binding())")
        line(link.describe())
        line()
        if let crash = CrashRecord.read() {
            line("last crash (the run before this one, or earlier):")
            for l in crash.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false) {
                line("  " + l)
            }
            line()
        }
        line("remembered scopes:")
        if model.known.scopes.isEmpty { line("  none") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for k in model.known.scopes {
            let camera = k.device.map { "\($0.host)/\($0.cameraProtocol.rawValue)/\($0.model ?? "-")" } ?? "-"
            let joined = f.string(from: Date(timeIntervalSince1970: TimeInterval(k.lastJoinedMs) / 1000))
            line("  \(k.ssid) camera=\(camera) joined=\(joined)")
        }
        line()
        line("log (\(DebugLog.size()) lines):")
        s += DebugLog.dump()
        line()
        return s
    }

    private static var photosDescription: String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized: return "granted"
        case .limited: return "limited"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    /// Writes the report to a temporary file for the share sheet.
    static func file(_ model: AppModel) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("debug", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("eardigger-debug-\(f.string(from: Date())).txt")
        try build(model).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func copy(_ model: AppModel) {
        UIPasteboard.general.string = build(model)
    }
}

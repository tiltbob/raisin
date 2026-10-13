import Foundation
import UIKit

/// Version and device details for the debug log.
enum AppInfo {
    static var bundleId: String { Bundle.main.bundleIdentifier ?? "?" }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) (\(build))"
    }

    /// `iPhone15,2`: the hardware model identifier.
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor static var device: String {
        "\(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
}

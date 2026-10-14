import EarDiggerKit
import os
import SwiftUI

@main
struct EarDiggerApp: App {
    @StateObject private var model: AppModel

    init() {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EarDigger", category: "EarDigger")
        DebugLog.shared.sink = { tag, message in
            logger.debug("\(tag, privacy: .public): \(message, privacy: .public)")
        }
        DebugLog.log("App", "start: \(AppInfo.version) on \(AppInfo.device)")
        CrashRecord.install()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ConnectView()
                .environmentObject(model)
        }
    }
}

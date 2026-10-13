import EarDiggerKit
import Foundation

/// Every user-facing text in one place (the Android app's strings.xml).
enum Strings {
    static let appName = "EarDigger"
    static let tagline = "Local-only viewer for Bebird Wi-Fi scopes"

    static let sectionNearby = "Nearby cameras"
    static let nearbyHelp = "Switch the scope on. The app listens for it over Bluetooth; tap it to join its Wi-Fi and open the picture."
    static let findNearby = "Find nearby"
    static let nearbyIdle = "Tap Find nearby to look for a switched-on scope."
    static let nearbyScanning = "Listening for scopes…"
    static let nearbyNone = "No scope found nearby. Make sure it is switched on and close by."
    static func nearbyFound(_ n: Int) -> String { "\(n) scope(s) nearby. Tap one to connect." }
    static func nearbyRemembered(_ n: Int) -> String {
        "\(n) remembered scope(s). Tap one to connect, or Find nearby to listen for others."
    }
    static func nearbyConnecting(_ name: String) -> String { "Connecting to \(name)…" }
    static func nearbyLooking(_ name: String) -> String { "Connected to \(name), looking for the camera…" }
    static func nearbyJoinFailed(_ name: String, _ reason: String) -> String {
        "Could not connect to \(name) (\(reason)). Make sure the scope is switched on and try again."
    }
    static func nearbyJoinDeclined(_ name: String) -> String { "Joining \(name)'s Wi-Fi was declined." }
    static func nearbyJoinUnsupported(_ name: String) -> String {
        "This build cannot join Wi-Fi networks itself. Join \(name) in Settings › Wi-Fi, come back and tap “\(joinedInSettings)”."
    }
    static func nearbyNoCamera(_ name: String) -> String {
        "No camera answered on \(name)'s Wi-Fi. Make sure the scope is on and the phone is on its Wi-Fi, then try again; if it keeps happening, shake the phone hard to reveal the debug log and share it."
    }
    static let nearbyNoWifi = "The phone is not on a Wi-Fi network. Join the scope's Wi-Fi in Settings › Wi-Fi first."
    static let theScope = "the scope"
    static let pickWifi = "Can't see it? Join any bebird Wi-Fi"
    static let joinedInSettings = "Joined its Wi-Fi in Settings? Find the camera"
    static let rememberedTag = "remembered, not heard yet"
    static func lastUsed(_ when: String) -> String { "last used \(when)" }
    static func forgetTitle(_ name: String) -> String { "Forget \(name)?" }
    static let forgetMessage = "It will no longer be listed until you join it again, and iOS forgets the Wi-Fi settings EarDigger saved for it."
    static let forget = "Forget"
    static let cancel = "Cancel"
    static let open = "Open"
    static let seenBluetooth = "Bluetooth"
    static func security(_ s: CameraWifi.Security) -> String { s == .open ? "open" : "WPA" }

    static let bluetoothOff = "Bluetooth is off"
    static let bluetoothDenied = "Bluetooth permission not granted (Settings › EarDigger › Bluetooth)"
    static let bluetoothUnsupported = "This device has no Bluetooth LE"
    static let noWifiScanNote = "iOS does not let apps list Wi-Fi networks, so only Bluetooth can hear the scope here."

    static let sectionDebug = "Debug log"
    static let debugHelp = "Everything the app does while finding and joining scopes is recorded here. Share it (for example to the Claude app) to get help; it includes nearby network names and addresses. Hide puts this card away until the next shake."
    static let shareLog = "Share log"
    static let copyLog = "Copy"
    static let clearLog = "Clear"
    static let hideLog = "Hide"
    static let debugRevealed = "Debug log revealed. Shake again any time."
    static let debugCopied = "Debug log copied to the clipboard."

    static let privacyNote = "EarDigger only ever sends packets to the camera's own address on the scope's Wi-Fi. Bluetooth only listens on this phone. No accounts, no analytics, no update checks, no cloud."

    static func viewerConnecting(_ name: String) -> String { "Connecting to \(name)…" }
    static let viewerWaiting = "Waiting for video…"
    static func viewerError(_ reason: String) -> String { "Could not connect: \(reason)" }
    static let viewerLinkLost = "Lost the scope's Wi-Fi. Is it still switched on?"
    static func battery(_ percent: Int) -> String { "Battery \(percent)%" }
    static func batteryCharging(_ percent: Int) -> String { "Battery \(percent)% ⚡" }
    static let batteryUnknown = "Battery —"
    static func fps(_ n: Int) -> String { "\(n) fps" }
    static let light = "Light"
    static let snapshot = "Snapshot"
    static let rotationAuto = "Auto-rotate: on"
    static let rotationOff = "Auto-rotate: off"
    static let close = "Close"
    static func snapshotSaved(_ name: String) -> String { "Saved \(name) to Photos" }
    static let snapshotFailed = "Could not save snapshot"
    static let snapshotDenied = "EarDigger may not add to Photos (Settings › EarDigger › Photos)"
    static let snapshotNoFrame = "No frame yet"
}

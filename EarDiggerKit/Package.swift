// swift-tools-version:5.9
import PackageDescription

// Everything in here is plain Swift plus BSD sockets, so it builds and its tests run on
// Linux as well as on Apple platforms. The iOS app (../EarDigger) adds the UI and the
// Apple-only radios (Core Bluetooth, NEHotspotConfiguration) on top.
let package = Package(
    name: "EarDiggerKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EarDiggerKit", targets: ["EarDiggerKit"]),
    ],
    targets: [
        .target(name: "EarDiggerKit"),
        .testTarget(name: "EarDiggerKitTests", dependencies: ["EarDiggerKit"]),
    ]
)

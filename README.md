# EarDigger for iOS

EarDigger (repository `raisin`) is the iOS port of [EarDigger for Android](https://github.com/tiltbob/grape)
(`tiltbob/grape`): a clean-room viewer for Bebird Wi-Fi ear scopes (the cameras the
`com.molink.john.hummingbird` "Bebird" app drives). It connects to the scope's own Wi-Fi,
shows the live picture, reads the battery, sets the tip light and saves snapshots.

That is all it does. There are no accounts, no analytics, no crash reporting service, no
push messaging, no update checks, no ads and no cloud: the only network traffic the app
generates is UDP/TCP to the scope's own address on its own Wi-Fi.

## Supported scopes

Both protocol generations of the vendor app are implemented, byte for byte as in the Android
app (see [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire formats):

* **tube** (UDP 58080/58090, `192.168.5.1`): ES, ESU, UltraX, Note5, R1, R3, X3, W3 and
  other recent models;
* **ML** (UDP 50000 + UDP 8030 / TCP 7060, `192.168.10.123`): M9 Pro, X17 Pro, Note3,
  T15, P30, D3, E3 and other older models.

Like the Android app, it has not yet been exercised against real hardware; the protocol
code is tested against simulated scopes (see [Building and tests](#building-and-tests)). Reports and packet captures
are welcome.

## Using it

The scope is its own Wi-Fi access point, so there is nothing to configure:

1. Switch the scope on and open EarDigger. Tap **Find nearby**: the app listens for the
   scope over Bluetooth LE (the scope announces its Wi-Fi name there) and lists what it
   hears. iOS asks once for Bluetooth; after that the app listens by itself whenever it
   opens.
2. Tap the scope. iOS asks once whether EarDigger may join its Wi-Fi and remembers the
   answer; the app then asks once to use the local network, which is how it talks to the
   camera. It finds the camera on that network and opens the live view. A scope you used
   before is rejoined without a tap when it is heard again.
3. If Bluetooth cannot hear it, **Can't see it? Join any bebird Wi-Fi** lets iOS join
   whichever `bebird…` network is in range. Or join the scope's Wi-Fi yourself in
   **Settings › Wi-Fi**, come back and tap **Joined its Wi-Fi in Settings? Find the camera**.
   Scopes you have joined are remembered (name and what the camera said about itself) and
   listed as soon as the app opens, so you can tap one before Bluetooth has heard it.
   Long-press a remembered scope to forget it; that also removes the Wi-Fi settings
   EarDigger saved for it. The list lives in the app's private storage and never leaves
   the phone.
4. In the viewer: the slider sets the tip light, **Snapshot** saves the frame to Photos, and
   **Auto-rotate** toggles compensation of the scope's roll angle. With it on, the picture is
   shown as a circle: a disc looks the same at every angle, so only the scene moves, not the
   frame. The ✕ closes the viewer; it also closes by itself when the scope's Wi-Fi goes away.

Differences from Android, all down to what iOS allows apps to do: iOS has no Wi-Fi scan
results for apps, so only Bluetooth hears scopes; iOS never reveals Bluetooth addresses, so
the access point is joined by name; and iOS keeps broadcasts to apps holding a special
entitlement from Apple, so the app asks the scope's well-known addresses directly instead of
broadcasting (see [docs/PROTOCOL.md](docs/PROTOCOL.md#on-ios)).

**If a scope is not found:** shake the phone hard half a dozen times on the connect screen
(a "rage shake") to reveal the **Debug log** card. It records every step of pairing and
discovery (Bluetooth hits, the join, the Wi-Fi interface and its address, every probe sent
and reply received). **Share log** opens the share sheet, so the report can go straight to
the Claude app or anywhere else; **Copy** puts it on the clipboard; **Hide** puts the card
away again. It contains nearby scope names and local addresses, nothing else personal. After
a crash, a later report includes it (iOS hands its crash record to the app on a following
launch).

Every camera socket is pinned to the Wi-Fi interface, because the scope's network has no
internet and iOS may otherwise route the traffic over cellular.

## Installing

There is no App Store build. Two ways onto a phone:

### Sideloading a release

Releases on GitHub carry `eardigger-<version>.ipa`. Install it with a sideloading tool that
signs it with your own Apple ID: [AltStore](https://altstore.io) or
[SideStore](https://sidestore.io), [Sideloadly](https://sideloadly.io), or TrollStore where it
works. AltStore and SideStore can follow new releases: add this source

```
https://github.com/tiltbob/raisin/releases/latest/download/altstore-source.json
```

With a free Apple ID, apps signed this way expire after seven days unless the tool refreshes
them, and the account may not be allowed the Hotspot Configuration capability the app uses to
join the scope's Wi-Fi by itself. Without it, join the scope's Wi-Fi in Settings and use
**Joined its Wi-Fi in Settings? Find the camera**; everything else works the same.

### Building with Xcode

Needs a Mac with Xcode 16 or later.

```
git clone https://github.com/tiltbob/raisin.git && cd raisin
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your DEVELOPMENT_TEAM
open EarDigger.xcodeproj
```

Pick your iPhone and run. `Config/Local.xcconfig` (ignored by git) is where your team, a
bundle id of your own (needed with a free Apple ID) and, if your account cannot sign it,
the removal of the Hotspot Configuration entitlement go; the example file explains each.

### Cutting a release (maintainers)

The release workflow (`.github/workflows/release.yml`) runs when a tag like `v1.2.3` is
pushed (or from the Actions tab with a version, which creates the tag): it runs the tests,
builds the app with the version from the tag (build number
`major * 1000000 + minor * 1000 + patch`), ad-hoc signs it with its entitlements, and creates
a GitHub Release with `eardigger-1.2.3.ipa`, its SHA-256 and `altstore-source.json`. No
Apple certificate or secret is involved: the sideloading tool re-signs the app.

```
git tag v0.1.0
git push origin v0.1.0
```

Every push and pull request also runs `.github/workflows/ci.yml`: the protocol tests on Linux
and macOS, a check that the committed Xcode project matches `project.yml`, and simulator and
device builds (the unsigned `.ipa` is kept as a build artifact).

## Building and tests

The protocol code lives in a Swift package, `EarDiggerKit`, that uses nothing but Foundation
and BSD sockets, so it builds and its tests run anywhere Swift runs, Linux included:

```
swift test --package-path EarDiggerKit
```

The tests are the Android app's codec tests ported one for one, plus
loopback tests that run simulated tube and ML scopes on `127.0.0.1` and drive the real
discovery and camera clients against them: board-info probes, the beacon, video over UDP
(both generations) and TCP (ML), battery, light and the start/stop handshakes.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
2.46.0 and committed. After adding or removing source files or changing `project.yml`, run
`xcodegen generate` and commit the result; CI fails if the two disagree.

```
xcodebuild -project EarDigger.xcodeproj -scheme EarDigger \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Layout

```
EarDiggerKit/                     Swift package: everything that is not UI or an Apple radio
  Sources/EarDiggerKit/
    Camera/        CameraClient protocol, DeviceInfo, factory
    Protocol/Tube/ tube protocol: codecs, frame reassembly, client, discovery
    Protocol/ML/   ML protocol: codecs, UDP reassembly, TCP parser, client, discovery
    Discovery/     runs all discoveries concurrently
    Net/           sockets, interfaces, CameraWifi (naming / security rules), remembered scopes
    Debug/         the in-app debug log
    Support/       byte helpers, I/O threads, JSON, the rage-shake counter
  Tests/           ported codec tests and loopback tests against simulated scopes
EarDigger/                        the iOS app (SwiftUI)
  App/             app entry and the connect screen's model
  Net/             NetworkLink (joins the scope's Wi-Fi, pins sockets), NearbyScanner (Bluetooth)
  UI/              connect screen, viewer, CameraView, shake detector
  Debug/           the shareable report and the crash record
  Support/         strings, snapshots, version info
  Resources/       Info.plist, entitlements, icon
Config/                           build settings (and your Local.xcconfig)
project.yml                       XcodeGen spec for EarDigger.xcodeproj
docs/PROTOCOL.md                  protocol notes
```

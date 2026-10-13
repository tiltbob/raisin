@testable import EarDiggerKit
import XCTest

final class KnownScopeTests: XCTestCase {
    private let r1 = "bebird-R1-630136"
    private let w3 = "bebird-W3-1234"

    func testRememberPutsTheLatestJoinFirstAndKeepsDetails() {
        let device = DeviceInfo(host: "192.168.5.1", cameraProtocol: .tube, model: "R1")
        var list = KnownScope.remember([], ssid: r1, nowMs: 1000)
        list = KnownScope.learn(list, ssid: r1, device: device)
        list = KnownScope.remember(list, ssid: w3, nowMs: 2000)
        XCTAssertEqual([w3, r1], list.map(\.ssid))

        // Joining R1 again moves it to the front and keeps what we learned about it.
        list = KnownScope.remember(list, ssid: "BEBIRD-r1-630136", nowMs: 3000)
        XCTAssertEqual(r1, list[0].ssid)
        XCTAssertEqual(device, list[0].device)
        XCTAssertEqual(3000, list[0].lastJoinedMs)
        XCTAssertEqual(2, list.count)
    }

    func testRememberCapsTheListAtTheLeastRecentlyUsed() {
        var list: [KnownScope] = []
        for i in 1...(KnownScope.max + 3) {
            list = KnownScope.remember(list, ssid: "bebird-\(i)", nowMs: Int64(i))
        }
        XCTAssertEqual(KnownScope.max, list.count)
        XCTAssertEqual("bebird-\(KnownScope.max + 3)", list.first?.ssid)
        XCTAssertEqual("bebird-4", list.last?.ssid)
    }

    func testLearnAttachesTheCameraToTheRightScope() {
        let device = DeviceInfo(host: "192.168.5.1", cameraProtocol: .tube, model: "R1")
        var list = KnownScope.remember([], ssid: r1, nowMs: 1)
        list = KnownScope.remember(list, ssid: w3, nowMs: 2)
        list = KnownScope.learn(list, ssid: "BEBIRD-r1-630136", device: device)
        XCTAssertEqual(device, list.first { $0.ssid == r1 }?.device)
        XCTAssertNil(list.first { $0.ssid == w3 }?.device)
    }

    func testForgetRemovesOnlyThatScope() {
        var list = KnownScope.remember([], ssid: r1, nowMs: 1)
        list = KnownScope.remember(list, ssid: w3, nowMs: 2)
        list = KnownScope.forget(list, ssid: "bebird-r1-630136")
        XCTAssertEqual([w3], list.map(\.ssid))
    }

    func testListingShowsHeardScopesFirstThenSilentRememberedOnes() {
        var scopes = KnownScope.remember([], ssid: r1, nowMs: 1)
        scopes = KnownScope.remember(scopes, ssid: w3, nowMs: 2)
        // Only W3 is heard right now.
        let heard = [NearbyCamera(ssid: w3, seenByBluetooth: true, rssi: -60)]
        let shown = KnownScope.listing(heard: heard, scopes: scopes)

        XCTAssertEqual([w3, r1], shown.map(\.ssid))
        XCTAssertTrue(shown[0].heard)
        XCTAssertTrue(shown[0].remembered)
        XCTAssertEqual(-60, shown[0].rssi)
        XCTAssertEqual(2, shown[0].lastJoinedMs)
        XCTAssertFalse(shown[1].heard)
        XCTAssertTrue(shown[1].remembered)
        XCTAssertEqual(1, shown[1].lastJoinedMs)
    }

    func testListingLeavesUnknownScopesAlone() {
        let stranger = NearbyCamera(ssid: "bebird-ES-9999", seenByBluetooth: true)
        let shown = KnownScope.listing(heard: [stranger], scopes: KnownScope.remember([], ssid: r1, nowMs: 1))
        XCTAssertEqual(["bebird-ES-9999", r1], shown.map(\.ssid))
        XCTAssertFalse(shown[0].remembered)
    }

    func testStoreSurvivesARestart() throws {
        let suite = "eardigger-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = DeviceInfo(host: "192.168.10.123", cameraProtocol: .ml, model: "M9 Pro", rawInfo: "{}")
        let store = KnownScopes(defaults: defaults)
        var changes = 0
        store.onChange = { _ in changes += 1 }
        store.remember(r1)
        store.learn(r1, device: device)
        store.remember(w3)
        XCTAssertEqual(3, changes)
        XCTAssertEqual(w3, store.lastUsed?.ssid)

        let reloaded = KnownScopes(defaults: defaults)
        XCTAssertEqual([w3, r1], reloaded.scopes.map(\.ssid))
        XCTAssertEqual(device, reloaded.forSsid("BEBIRD-R1-630136")?.device)
        reloaded.forget(w3)
        XCTAssertEqual([r1], KnownScopes(defaults: defaults).scopes.map(\.ssid))
    }

    func testDeviceInfoDecodesWithMissingFields() throws {
        let json = #"{"host":"192.168.5.1","protocol":"ML","model":"X17 Pro"}"#
        let info = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(.ml, info.cameraProtocol)
        XCTAssertEqual("X17 Pro", info.model)
        XCTAssertFalse(info.floatAngle)
        XCTAssertEqual(0, info.rotateAngle)
    }
}

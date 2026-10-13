@testable import EarDiggerKit
import XCTest

final class CameraWifiTests: XCTestCase {
    func testRecognisesCameraNames() {
        XCTAssertTrue(CameraWifi.looksLikeCamera("bebird-ES-1A2B3C"))
        XCTAssertTrue(CameraWifi.looksLikeCamera("Bebird M9 Pro"))
        XCTAssertTrue(CameraWifi.looksLikeCamera("XLife-123"))
        XCTAssertFalse(CameraWifi.looksLikeCamera("HomeWifi"))
        XCTAssertFalse(CameraWifi.looksLikeCamera(nil))
        XCTAssertTrue(CameraWifi.looksLikeCamera("Note3-1234", prefixes: ["note3"]))
    }

    func testSecuredModelsNeedThePassphrase() {
        XCTAssertTrue(CameraWifi.isSecuredBySsid("bebird-W3-1234"))
        XCTAssertTrue(CameraWifi.isSecuredBySsid("bebird_E3_0001"))
        XCTAssertTrue(CameraWifi.isSecuredBySsid("bebird-Elite14W-77"))
        XCTAssertTrue(CameraWifi.isSecuredBySsid("bebird-Max 22-1"))
        XCTAssertFalse(CameraWifi.isSecuredBySsid("bebird-ES-1A2B3C"))
        XCTAssertFalse(CameraWifi.isSecuredBySsid("bebird"))
        XCTAssertFalse(CameraWifi.isSecuredBySsid(nil))
        XCTAssertEqual(.wpa, CameraWifi.security(forSsid: "bebird-W3-1"))
        XCTAssertEqual(.open, CameraWifi.security(forSsid: "bebird-ES-1"))
    }

    func testPrettyNamesDropTheUnitNumber() {
        XCTAssertEqual("Bebird R1", CameraWifi.prettyName(ssid: "bebird-R1-630136"))
        XCTAssertEqual("Bebird ES", CameraWifi.prettyName(ssid: "bebird-ES-1A2B3C"))
        XCTAssertEqual("Bebird M9 Pro", CameraWifi.prettyName(ssid: "Bebird M9 Pro"))
        XCTAssertEqual("Xlife W3", CameraWifi.prettyName(ssid: "xlife_W3_1234"))
        XCTAssertEqual("Bebird Note5", CameraWifi.prettyName(ssid: "bebird-Note5-77"))
        XCTAssertEqual("Bebird", CameraWifi.prettyName(ssid: "bebird-630136"))
        XCTAssertEqual("Bebird", CameraWifi.prettyName(ssid: "BEBIRD"))
        XCTAssertEqual("", CameraWifi.prettyName(ssid: nil))
        XCTAssertEqual("Bebird R1", CameraWifi.prettyName(brand: "bebird", model: "R1"))
        XCTAssertEqual("R1", CameraWifi.prettyName(brand: nil, model: "R1"))
        XCTAssertNil(CameraWifi.prettyName(brand: " ", model: ""))
    }

    func testMergeKeepsTheLatestSighting() {
        let old = NearbyCamera(ssid: "bebird-ES-1", bluetoothID: "A", seenByBluetooth: true, rssi: -60)
        let new = NearbyCamera(ssid: "bebird-ES-1", seenByBluetooth: true, rssi: -50, remembered: true)
        let m = old.merge(new)
        XCTAssertTrue(m.seenByBluetooth)
        XCTAssertTrue(m.remembered)
        XCTAssertEqual("A", m.bluetoothID)
        XCTAssertEqual(-50, m.rssi)
    }

    func testDisplayNameFallsBackFromBoardInfoToSsidToAddress() {
        XCTAssertEqual("Bebird R1", DeviceInfo(host: "192.168.5.1", cameraProtocol: .tube, model: "R1", ssid: "x", brand: "bebird").displayName)
        XCTAssertEqual("Bebird ES", DeviceInfo(host: "192.168.5.1", cameraProtocol: .tube, ssid: "bebird-ES-1A2B3C").displayName)
        XCTAssertEqual("192.168.5.1", DeviceInfo(host: "192.168.5.1", cameraProtocol: .tube).displayName)
    }

    func testInterfaceArithmetic() {
        let wifi = IPv4Interface(name: "en0", address: "192.168.5.23", netmask: "255.255.255.0", isUp: true, isLoopback: false)
        XCTAssertEqual(24, wifi.prefixLength)
        XCTAssertEqual("192.168.5.255", wifi.broadcast)
        XCTAssertEqual("192.168.5.1", wifi.firstHost)
        XCTAssertFalse(wifi.isLinkLocal)
        let gateway = IPv4Interface(name: "en0", address: "192.168.5.1", netmask: "255.255.255.0", isUp: true, isLoopback: false)
        XCTAssertNil(gateway.firstHost)
        XCTAssertTrue(IPv4Interface(name: "en0", address: "169.254.3.4", netmask: "255.255.0.0", isUp: true, isLoopback: false).isLinkLocal)
        XCTAssertFalse(NetInterfaces.ipv4().isEmpty) // at least loopback
    }
}

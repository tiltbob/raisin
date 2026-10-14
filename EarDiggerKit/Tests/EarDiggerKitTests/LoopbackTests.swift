@testable import EarDiggerKit
import XCTest

/// End-to-end runs of the discoveries and clients against fake cameras on loopback.
final class LoopbackTests: XCTestCase {
    private let host = "127.0.0.1"

    // ---- tube ---------------------------------------------------------------

    func testTubeProbeFindsTheCamera() throws {
        let cam = try FakeTubeCamera()
        defer { cam.stop() }
        let found = TubeDiscovery.probe(binding: .none, extraHosts: [host], timeout: 2, stopAtFirst: true, includeDefaults: false)
        XCTAssertEqual([host], found.map(\.host))
        XCTAssertEqual("R1", found.first?.model)
        XCTAssertEqual("bebird-R1-630136", found.first?.ssid)
        XCTAssertEqual(FakeTubeCamera.boardInfo, found.first?.rawInfo)
    }

    func testScanStopsAtTheFirstAnswer() async throws {
        let cam = try FakeTubeCamera()
        defer { cam.stop() }
        let started = Date()
        let found = await CameraDiscovery.scan(binding: .none, extraHosts: [host], timeout: 2.5, includeDefaults: false)
        XCTAssertEqual([CameraProtocol.tube], found.map(\.cameraProtocol))
        // The ML probe (no answer: 3 tries x 200 ms per command) is cancelled, not waited out.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testTubeClientStreamsAndControls() async throws {
        let cam = try FakeTubeCamera()
        defer { cam.stop() }
        let client = TubeCameraClient(info: DeviceInfo(host: host, cameraProtocol: .tube))
        try await client.connect()
        try await client.start()

        let frame = await first(client.frames, within: 5)
        XCTAssertEqual(cam.jpeg, frame?.jpeg)
        XCTAssertEqual(300, frame?.angleDegrees)
        XCTAssertTrue(cam.received.contains("START from \(TubeCameraClient.preferredVideoClientPort)"))
        await waitUntil { cam.received.contains("66 3f 00 01") }
        XCTAssertTrue(cam.received.contains("66 3f 00 01"), "tip light on when the stream starts")

        let battery = await first(client.battery, within: 3)
        XCTAssertEqual(BatteryStatus(percent: 65, charging: true, rawState: 2), battery)

        await client.setLight(42)
        await waitUntil { cam.lightLevel == 42 }
        XCTAssertEqual(42, cam.lightLevel)
        let level = await client.getLight()
        XCTAssertEqual(42, level)

        let info = await client.refreshInfo()
        XCTAssertEqual("R1", info?.model)
        XCTAssertEqual("Bebird R1", info?.displayName)

        await client.stop()
        // Fire-and-forget datagrams: give the fake a moment to read them.
        await waitUntil { cam.received.contains("66 3f 00 00") }
        XCTAssertTrue(cam.received.contains("STOP from \(TubeCameraClient.preferredVideoClientPort)"))
        XCTAssertTrue(cam.received.contains("66 3f 00 00"), "tip light off when the stream stops")
        await IO.run { client.close() }
    }

    // ---- ML -----------------------------------------------------------------

    func testMlProbeFindsTheCamera() throws {
        let cam = try FakeMlCamera(udpVideo: false, tcpVideo: false)
        defer { cam.stop() }
        let found = MlDiscovery.probe(binding: .none, extraHosts: [host], includeDefault: false)
        XCTAssertEqual([host], found.map(\.host))
        XCTAssertEqual(.ml, found.first?.cameraProtocol)
        XCTAssertEqual("M9 Pro", found.first?.model)
        XCTAssertEqual("ML-7", found.first?.firmware)
    }

    func testScanFindsAnMlCamera() async throws {
        let cam = try FakeMlCamera(udpVideo: false, tcpVideo: false)
        defer { cam.stop() }
        let found = await CameraDiscovery.scan(binding: .none, extraHosts: [host], timeout: 2.5, includeDefaults: false)
        XCTAssertEqual([CameraProtocol.ml], found.map(\.cameraProtocol))
    }

    func testMlClientOverUdp() async throws {
        let cam = try FakeMlCamera(udpVideo: true, tcpVideo: false)
        defer { cam.stop() }
        let client = MlCameraClient(info: DeviceInfo(host: host, cameraProtocol: .ml))
        try await client.connect()
        try await client.start()

        let frame = await first(client.frames, within: 5)
        XCTAssertEqual(cam.jpeg, frame?.jpeg)

        let battery = await first(client.battery, within: 3)
        XCTAssertEqual(83, battery?.percent) // (3900 - 3400) / 6
        XCTAssertEqual(false, battery?.charging)

        await client.setLight(55) // a request/reply: the fake has applied it when this returns
        XCTAssertEqual(55, cam.lightLevel)
        let level = await client.getLight()
        XCTAssertEqual(55, level)

        let info = await client.refreshInfo()
        XCTAssertEqual("M9 Pro", info?.model)
        XCTAssertEqual("M9 Pro", client.model)

        await client.stop()
        await waitUntil { cam.received.contains("UDP STOP") }
        XCTAssertTrue(cam.received.contains("UDP STOP"))
        await IO.run { client.close() }
    }

    func testMlClientOverTcp() async throws {
        let cam = try FakeMlCamera(udpVideo: false, tcpVideo: true)
        defer { cam.stop() }
        let client = MlCameraClient(info: DeviceInfo(host: host, cameraProtocol: .ml))
        try await client.connect()
        try await client.start()
        let frame = await first(client.frames, within: 5)
        XCTAssertEqual(cam.jpeg, frame?.jpeg)
        XCTAssertEqual(90, frame?.angleDegrees ?? 0, accuracy: 0.01)
        await client.stop()
        await IO.run { client.close() }
    }

    func testStartBeforeConnectIsAnError() async {
        let client = MlCameraClient(info: DeviceInfo(host: host, cameraProtocol: .ml))
        do {
            try await client.start()
            XCTFail("start() without connect() must throw")
        } catch {}
        let tube = TubeCameraClient(info: DeviceInfo(host: host, cameraProtocol: .tube))
        do {
            try await tube.start()
            XCTFail("start() without connect() must throw")
        } catch {}
    }

    // ---- beacon ---------------------------------------------------------------

    func testBeaconListenerReadsTheAdvertisedAddress() async throws {
        let port: UInt16 = 58_199 // not the real beacon port, which a real scope app may hold
        let listening = Task { await IO.run { TubeDiscovery.listenForBeacons(binding: .none, timeout: 1.5, port: port) } }
        let sender = try UDPSocket()
        defer { sender.close() }
        let beacon = Array(#"{"brand":"bebird","model":"ES","ssid":"bebird-ES-1A2B3C","ipaddr":"192.168.5.1","battery":65636}"#.utf8)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            try sender.send(beacon, to: host, port: port)
        }
        let found = await listening.value
        XCTAssertEqual(["192.168.5.1"], found.map(\.host))
        XCTAssertEqual("ES", found.first?.model)
        XCTAssertEqual("Bebird ES", found.first?.displayName)
    }

    // ---- helpers --------------------------------------------------------------

    /// The first element of [stream] within [timeout] seconds, or nil. Consumes the stream.
    private func first<T: Sendable>(_ stream: AsyncStream<T>, within timeout: TimeInterval) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await item in stream { return item }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

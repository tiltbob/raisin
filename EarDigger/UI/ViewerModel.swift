import EarDiggerKit
import Foundation
import ImageIO
import UIKit

/// One viewing session: connects the client, shows frames, battery and light, saves
/// snapshots. Started when the viewer appears or comes back to the foreground, stopped when
/// it goes away.
@MainActor
final class ViewerModel: ObservableObject {
    private static let tag = "Viewer"
    private static let angleHysteresisDegrees: Float = 2
    private static let stallNotice: TimeInterval = 3

    @Published private(set) var title: String
    /// The message in the middle of the screen; nil hides it.
    @Published private(set) var status: String?
    @Published private(set) var fps = ""
    @Published private(set) var battery = Strings.batteryUnknown
    @Published var light: Double = 0
    @Published private(set) var lightShown = false
    @Published private(set) var autoRotate = true
    @Published var toast: String?
    /// Set when the session ended by itself (the scope's Wi-Fi went away).
    @Published private(set) var endedBecause: String?

    private var info: DeviceInfo
    private let link: NetworkLink
    private weak var cameraView: CameraUIView?
    private var client: CameraClient?
    private var session: Task<Void, Never>?
    private var lastFrame: VideoFrame?
    private var lastFrameAt: Date?
    private var shownAngle: Float = 0

    init(info: DeviceInfo, link: NetworkLink) {
        self.info = info
        self.link = link
        title = info.displayName
    }

    func attach(_ view: CameraUIView) {
        cameraView = view
        view.circular = autoRotate
    }

    // ---- session -------------------------------------------------------------

    func start() {
        guard session == nil else { return }
        session = Task { await runSession() }
    }

    func stop() {
        guard session != nil || client != nil else { return }
        DebugLog.log(Self.tag, "close \(info.host)")
        session?.cancel()
        session = nil
        let c = client
        client = nil
        lastFrameAt = nil
        if let c {
            // Stop the stream politely, then drop the sockets, off the main thread.
            Task.detached {
                await c.stop()
                await IO.run { c.close() }
            }
        }
        cameraView?.clear()
        fps = ""
    }

    private func runSession() async {
        status = Strings.viewerConnecting(info.displayName)
        let binding = link.binding()
        DebugLog.log(Self.tag, "open \(info.host) \(info.cameraProtocol.rawValue) model=\(info.model ?? "-") via \(binding)")
        let c = CameraClients.create(info, binding: binding)
        do {
            try await c.connect()
            try await c.start()
        } catch {
            DebugLog.log(Self.tag, "connect failed", error)
            status = Strings.viewerError("\(error)")
            await IO.run { c.close() }
            return
        }
        if Task.isCancelled {
            await c.stop()
            await IO.run { c.close() }
            return
        }
        client = c
        status = Strings.viewerWaiting

        // Everything below ends with the session task.
        let needsInfo = info.rawInfo == nil
        await withTaskGroup(of: Void.self) { group in
            // Fill in details we did not have yet (beacon-only discovery, version-only reply).
            if needsInfo { group.addTask { await self.fillInInfo(c) } }
            group.addTask { await self.readLight(c) }
            group.addTask { await self.watchBattery(c) }
            group.addTask { await self.watchStall() }
            group.addTask { await self.watchLink() }
            group.addTask { await Self.decodeLoop(c, model: self) }
        }
    }

    private func fillInInfo(_ c: CameraClient) async {
        guard let parsed = await c.refreshInfo() else { return }
        info = parsed
        title = parsed.displayName
    }

    private func readLight(_ c: CameraClient) async {
        guard let level = await c.getLight() else { return }
        light = Double(level)
        lightShown = true
    }

    private func watchBattery(_ c: CameraClient) async {
        for await reading in c.battery {
            battery = reading.charging ? Strings.batteryCharging(reading.percent) : Strings.battery(reading.percent)
        }
    }

    private func watchStall() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let last = lastFrameAt, Date().timeIntervalSince(last) > Self.stallNotice, status == nil {
                status = Strings.viewerWaiting
            }
        }
    }

    /// The scope's Wi-Fi going away (switched off, walked out of range) ends the session.
    private func watchLink() async {
        var downFor = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            downFor = link.wifiAddress == nil ? downFor + 1 : 0
            if downFor >= 3 {
                DebugLog.log(Self.tag, "scope Wi-Fi gone: closing the viewer")
                endedBecause = Strings.viewerLinkLost
                return
            }
        }
    }

    /// Decodes off the main thread; only finished images reach it.
    private nonisolated static func decodeLoop(_ c: CameraClient, model: ViewerModel) async {
        var windowStart = Date()
        var windowFrames = 0
        for await frame in c.frames {
            guard let image = decode(frame.jpeg) else { continue }
            windowFrames += 1
            let now = Date()
            var fps: Int?
            let elapsed = now.timeIntervalSince(windowStart)
            if elapsed >= 1 {
                fps = Int((Double(windowFrames) / elapsed).rounded())
                windowStart = now
                windowFrames = 0
            }
            await model.show(frame, image: image, fps: fps)
        }
    }

    /// A fully decoded image, so the main thread only has to put it on screen.
    private nonisolated static func decode(_ jpeg: [UInt8]) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func show(_ frame: VideoFrame, image: CGImage, fps: Int?) {
        guard session != nil else { return }
        lastFrame = frame
        lastFrameAt = Date()
        if status != nil { status = nil }
        cameraView?.setFrame(image, angleDegrees: displayAngle(frame.angleDegrees))
        if let fps { self.fps = Strings.fps(fps) }
    }

    /// Apply the roll angle with a little hysteresis so the picture does not jitter.
    private func displayAngle(_ reported: Float) -> Float {
        guard autoRotate else { return 0 }
        var diff = abs(reported - shownAngle)
        if diff > 180 { diff = 360 - diff }
        if diff >= Self.angleHysteresisDegrees { shownAngle = reported }
        return shownAngle
    }

    // ---- controls ------------------------------------------------------------

    func lightEditing(_ editing: Bool) {
        if editing {
            lightShown = true
            return
        }
        let level = Int(light.rounded())
        guard let c = client else { return }
        Task { await c.setLight(level) }
    }

    func toggleRotation() {
        autoRotate.toggle()
        // A circle is the one shape that does not seem to turn when the picture is kept upright.
        cameraView?.circular = autoRotate
        if !autoRotate { shownAngle = 0 }
    }

    func snapshot() {
        guard let frame = lastFrame else {
            toast = Strings.snapshotNoFrame
            return
        }
        Task { toast = await Snapshots.save(Data(frame.jpeg)) }
    }
}

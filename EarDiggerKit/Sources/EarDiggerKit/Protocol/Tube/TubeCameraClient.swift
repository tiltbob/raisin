import Foundation

/// [CameraClient] for the UDP "tube" protocol. See [TubeProtocol] for the wire format.
public final class TubeCameraClient: CameraClient, @unchecked Sendable {
    public static let preferredVideoClientPort: UInt16 = 58081
    static let commandTimeout: TimeInterval = 0.5
    static let videoTimeout: TimeInterval = 0.1
    static let keepAliveInterval: TimeInterval = 1
    static let stallRestartMs: Int64 = 3000
    static let statsEveryTicks = 15

    public let info: DeviceInfo
    private let binding: SocketBinding

    /// Guards the fields below that more than one thread touches.
    private let lock = NSLock()
    /// Serialises request/reply exchanges on the command socket.
    private let commandLock = NSLock()

    private var state = ConnectionState.idle
    private var commandSocket: UDPSocket?
    private var videoSocket: UDPSocket?
    private var streamWorker: Worker?
    private var keepAliveWorker: Worker?
    private var lastFrameAtMs: Int64 = 0
    private var lastStartAtMs: Int64 = 0
    private var lastBatteryState = -1

    private let assembler: FrameAssembler

    public let frames: AsyncStream<VideoFrame>
    private let frameSink: AsyncStream<VideoFrame>.Continuation
    public let battery: AsyncStream<BatteryStatus>
    private let batterySink: AsyncStream<BatteryStatus>.Continuation

    public init(info: DeviceInfo, binding: SocketBinding = .none) {
        self.info = info
        self.binding = binding
        assembler = FrameAssembler(floatAngle: info.floatAngle)
        var frameSink: AsyncStream<VideoFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { frameSink = $0 }
        self.frameSink = frameSink
        var batterySink: AsyncStream<BatteryStatus>.Continuation!
        battery = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { batterySink = $0 }
        self.batterySink = batterySink
    }

    /// Frames fully reassembled since [start].
    public var framesReceived: Int { locked { assembler.framesCompleted } }

    /// Frames lost to missing chunks since [start].
    public var framesDropped: Int { locked { assembler.framesDropped } }

    /// Angle encoding used by this unit; discovered from board info, may be updated after connect.
    public var floatAngle: Bool {
        get { locked { assembler.floatAngle } }
        set { locked { assembler.floatAngle = newValue } }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // ---- CameraClient -----------------------------------------------------

    public func connect() async throws {
        try await IO.runThrowing { try self.connectBlocking() }
    }

    public func start() async throws {
        try await IO.runThrowing { try self.startBlocking() }
    }

    public func stop() async {
        await IO.run { self.stopBlocking() }
    }

    public func setLight(_ percent: Int) async {
        await IO.run {
            self.sendCommand(TubeProtocol.setBrightness(min(max(percent, 0), 100)))
            self.sendCommand(TubeProtocol.commitBrightness)
        }
    }

    public func getLight() async -> Int? {
        await IO.run {
            guard let reply = self.exchange(TubeProtocol.queryBrightness), let level = reply.first else { return nil }
            return level <= 100 ? Int(level) : nil
        }
    }

    public func refreshInfo() async -> DeviceInfo? {
        await IO.run {
            guard let text = self.readBoardInfo(), let parsed = TubeDiscovery.parseBoardInfo(host: self.info.host, text: text) else {
                return nil
            }
            self.floatAngle = parsed.floatAngle
            return parsed
        }
    }

    public func close() {
        let (stream, keepAlive, video) = locked { () -> (Worker?, Worker?, UDPSocket?) in
            state = .closed
            defer {
                streamWorker = nil
                keepAliveWorker = nil
                videoSocket = nil
            }
            return (streamWorker, keepAliveWorker, videoSocket)
        }
        keepAlive?.cancelAndJoin()
        stream?.cancelAndJoin()
        if let video {
            try? video.send(TubeProtocol.stopVideo)
            video.close()
        }
        commandLock.lock()
        commandSocket?.close()
        commandSocket = nil
        commandLock.unlock()
        frameSink.finish()
        batterySink.finish()
    }

    // ---- blocking implementations (I/O threads) ----------------------------

    func connectBlocking() throws {
        guard locked({ state == .idle }) else { return }
        let command = try UDPSocket(binding: binding)
        try command.bind()
        try command.connect(host: info.host, port: TubeProtocol.commandPort)
        let video = try openVideoSocket()
        DebugLog.log("TubeClient", "connected to \(info.host): cmd port \(command.localPort), video port \(video.localPort), via \(binding)")
        commandLock.lock()
        commandSocket = command
        commandLock.unlock()
        locked {
            videoSocket = video
            state = .connected
        }
    }

    /// The scope keeps streaming to every (address, port) that sent START until that port sends
    /// STOP, so a fixed client port lets us STOP a previous session of ourselves before START.
    private func openVideoSocket() throws -> UDPSocket {
        let socket = try UDPSocket(binding: binding)
        socket.setReuseAddress()
        do {
            try socket.bind(port: Self.preferredVideoClientPort)
        } catch {
            try socket.bind()
        }
        socket.setTrafficClass(0x10) // IPTOS_LOWDELAY
        socket.setReceiveBufferSize(5 * 1024 * 1024)
        try socket.connect(host: info.host, port: TubeProtocol.videoPort)
        return socket
    }

    func startBlocking() throws {
        let video: UDPSocket = try locked {
            guard let v = videoSocket else { throw CameraError.notConnected }
            return v
        }
        let alreadyStreaming = locked { () -> Bool in
            if state == .streaming { return true }
            assembler.reset()
            lastFrameAtMs = 0
            state = .streaming
            return false
        }
        if alreadyStreaming { return }
        let stream = Worker("tube-video") { [self] w in receiveLoop(video, w) }
        locked { streamWorker = stream }
        restartVideo(video)
        // Same as the vendor app entering its camera screen: tip light on at the saved level.
        sendCommand(TubeProtocol.triggerLed(0, on: true))
        let keepAlive = Worker("tube-keepalive") { [self] w in keepAliveLoop(video, w) }
        locked { keepAliveWorker = keepAlive }
    }

    func stopBlocking() {
        let workers = locked { () -> [Worker]? in
            guard state == .streaming else { return nil }
            defer {
                streamWorker = nil
                keepAliveWorker = nil
            }
            return [keepAliveWorker, streamWorker].compactMap { $0 }
        }
        guard let workers else { return }
        workers.forEach { $0.cancelAndJoin() }
        if let video = locked({ videoSocket }) { try? video.send(TubeProtocol.stopVideo) }
        sendCommand(TubeProtocol.triggerLed(0, on: false))
        locked { state = .connected }
    }

    /// Battery request/reply. Also acts as the stream keep-alive.
    public func readBattery() -> BatteryStatus? {
        guard let reply = exchange(TubeProtocol.getBattery) else {
            DebugLog.log("TubeClient", "battery: no reply from \(info.host):\(TubeProtocol.commandPort)")
            return nil
        }
        guard let b = TubeProtocol.parseBattery(reply) else { return nil }
        let changed = locked { () -> Bool in
            defer { lastBatteryState = b.state }
            return b.state != lastBatteryState
        }
        if changed { DebugLog.log("TubeClient", "battery: state \(b.state) (\(b.percent)%)") }
        return BatteryStatus(percent: min(max(b.percent, 0), 100), charging: b.charging || b.full, rawState: b.state)
    }

    /// The JSON board-info document, or nil on timeout.
    public func readBoardInfo() -> String? {
        guard let reply = exchange(TubeProtocol.getBoardInfo, maxDatagrams: 8, isComplete: TubeProtocol.isBoardInfoComplete) else {
            return nil
        }
        return String(decoding: reply, as: UTF8.self)
    }

    // ---- internals --------------------------------------------------------

    private func restartVideo(_ video: UDPSocket) {
        let (frames, dropped) = locked { (assembler.framesCompleted, assembler.framesDropped) }
        DebugLog.log("TubeClient", "video STOP+START (frames so far \(frames), dropped \(dropped))")
        try? video.send(TubeProtocol.stopVideo)
        Thread.sleep(forTimeInterval: 0.1)
        try? video.send(TubeProtocol.startVideo)
        locked { lastStartAtMs = Clock.ms() }
    }

    private func receiveLoop(_ video: UDPSocket, _ worker: Worker) {
        var buffer = [UInt8](repeating: 0, count: TubeProtocol.maxDatagram)
        while !worker.isCancelled && !video.isClosed {
            let datagram: Datagram?
            do {
                datagram = try video.receive(into: &buffer, timeout: Self.videoTimeout)
            } catch {
                if video.isClosed { return }
                // ICMP errors are reported once each; do not spin on a persistent one.
                worker.sleep(0.05)
                continue
            }
            guard let datagram else { continue }
            let (frame, first) = locked { () -> (FrameAssembler.Frame?, Bool) in
                guard let f = assembler.offer(buffer, length: datagram.length) else { return (nil, false) }
                defer { lastFrameAtMs = Clock.ms() }
                return (f, lastFrameAtMs == 0)
            }
            guard let frame else { continue }
            if first { DebugLog.log("TubeClient", "first frame: \(frame.jpeg.count) bytes, angle \(frame.angleDegrees)") }
            frameSink.yield(VideoFrame(jpeg: frame.jpeg, angleDegrees: frame.angleDegrees, receivedAtMs: Clock.ms()))
        }
    }

    /// Once a second: poll the battery (which the scope treats as a keep-alive) and, if the
    /// picture has stalled for a few seconds, bounce the stream the way the vendor app does.
    private func keepAliveLoop(_ video: UDPSocket, _ worker: Worker) {
        var ticks = 0
        while !worker.isCancelled {
            if let b = readBattery() { batterySink.yield(b) }
            ticks += 1
            if ticks % Self.statsEveryTicks == 0 {
                DebugLog.log("TubeClient", "stats: frames \(framesReceived), dropped \(framesDropped)")
            }
            let now = Clock.ms()
            let (lastFrame, lastStart) = locked { (lastFrameAtMs, lastStartAtMs) }
            let stalledSince = lastFrame > 0 ? lastFrame : lastStart
            if now - stalledSince > Self.stallRestartMs && now - lastStart > Self.stallRestartMs {
                restartVideo(video)
            }
            if !worker.sleep(Self.keepAliveInterval) { break }
        }
    }

    /// Fire-and-forget command on the command port.
    private func sendCommand(_ request: [UInt8]) {
        commandLock.lock()
        defer { commandLock.unlock() }
        try? commandSocket?.send(request)
    }

    /// Send [request] and collect up to [maxDatagrams] reply datagrams, stopping early once
    /// [isComplete] says the accumulated reply is whole. Nil on timeout / no reply.
    private func exchange(
        _ request: [UInt8],
        maxDatagrams: Int = 1,
        isComplete: ([UInt8], Int) -> Bool = { _, _ in true }
    ) -> [UInt8]? {
        commandLock.lock()
        defer { commandLock.unlock() }
        guard let socket = commandSocket else { return nil }
        var buffer = [UInt8](repeating: 0, count: TubeProtocol.maxDatagram)
        socket.drain(&buffer)
        do {
            try socket.send(request)
        } catch {
            return nil
        }
        var out: [UInt8] = []
        for _ in 0..<maxDatagrams {
            let datagram: Datagram?
            do {
                datagram = try socket.receive(into: &buffer, timeout: Self.commandTimeout)
            } catch {
                return nil // port unreachable or another error
            }
            guard let datagram else { return out.isEmpty ? nil : out }
            out += buffer[0..<datagram.length]
            if isComplete(out, out.count) { return out }
        }
        return out.isEmpty ? nil : out
    }
}

import Foundation

/// [CameraClient] for the "ML" protocol. See [MlProtocol] for the wire format.
///
/// Like the vendor's native library it listens on both video channels at once: the UDP stream
/// on port 8030 (which needs a START every 600 ms) and the TCP stream on port 7060 (which
/// starts as soon as someone connects).
public final class MlCameraClient: CameraClient, @unchecked Sendable {
    static let commandTimeout: TimeInterval = 0.2
    static let videoTimeout: TimeInterval = 0.1
    static let batteryInterval: TimeInterval = 1
    static let tcpConnectTimeout: TimeInterval = 3
    static let tcpRetryInterval: TimeInterval = 2

    public let info: DeviceInfo
    private let binding: SocketBinding

    private let lock = NSLock()
    private let commandLock = NSLock()

    private var state = ConnectionState.idle
    private var commandSocket: UDPSocket?
    private var sequence: Int32 = 1
    private var workers: [Worker] = []

    private let angleDecoder = MlProtocol.AngleDecoder()
    private var lastAngle: Float = 0
    private var _model: String?

    public let frames: AsyncStream<VideoFrame>
    private let frameSink: AsyncStream<VideoFrame>.Continuation
    public let battery: AsyncStream<BatteryStatus>
    private let batterySink: AsyncStream<BatteryStatus>.Continuation

    public init(info: DeviceInfo, binding: SocketBinding = .none) {
        self.info = info
        self.binding = binding
        _model = info.model
        var frameSink: AsyncStream<VideoFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(2)) { frameSink = $0 }
        self.frameSink = frameSink
        var batterySink: AsyncStream<BatteryStatus>.Continuation!
        battery = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { batterySink = $0 }
        self.batterySink = batterySink
    }

    /// Model name used to pick the battery voltage curve; refreshed from board info.
    public var model: String? {
        get { locked { _model } }
        set { locked { _model = newValue } }
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
        await IO.run { _ = self.exchange(MlProtocol.cmdSetLight, parameter: min(max(percent, 0), 100)) }
    }

    public func getLight() async -> Int? {
        await IO.run {
            guard let reply = self.exchange(MlProtocol.cmdGetLight),
                  let level = MlProtocol.replyInt(reply.0, length: reply.1) else { return nil }
            return (0...100).contains(level) ? level : nil
        }
    }

    public func refreshInfo() async -> DeviceInfo? {
        await IO.run {
            guard let text = self.readBoardInfo() else { return nil }
            let parsed = MlDiscovery.fromBoardInfo(host: self.info.host, text: text)
            self.model = parsed.model
            return parsed
        }
    }

    public func close() {
        let running = locked { () -> [Worker] in
            state = .closed
            defer { workers = [] }
            return workers
        }
        running.forEach { $0.cancel() }
        running.forEach { $0.cancelAndJoin() }
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
        let socket = try UDPSocket(binding: binding)
        try socket.bind()
        commandLock.lock()
        commandSocket = socket
        commandLock.unlock()
        DebugLog.log("MlClient", "connected to \(info.host): cmd port \(socket.localPort), via \(binding)")
        locked { state = .connected }
    }

    func startBlocking() throws {
        let current = locked { state }
        if current == .idle || current == .closed { throw CameraError.notConnected }
        if current == .streaming { return }
        locked { state = .streaming }
        let started = [
            Worker("ml-udp-video") { [self] w in udpVideoLoop(w) },
            Worker("ml-tcp-video") { [self] w in tcpVideoLoop(w) },
            Worker("ml-battery") { [self] w in
                while !w.isCancelled {
                    if let b = readBattery() { batterySink.yield(b) }
                    if !w.sleep(Self.batteryInterval) { break }
                }
            },
        ]
        locked { workers = started }
    }

    func stopBlocking() {
        let running = locked { () -> [Worker]? in
            guard state == .streaming else { return nil }
            defer { workers = [] }
            return workers
        }
        guard let running else { return }
        running.forEach { $0.cancel() }
        running.forEach { $0.cancelAndJoin() }
        locked { state = .connected }
    }

    public func readBattery() -> BatteryStatus? {
        guard let reply = exchange(MlProtocol.cmdGetBattery), let b = MlProtocol.parseBattery(reply.0, length: reply.1) else {
            return nil
        }
        return BatteryStatus(
            percent: b.percentDirect ?? b.percentEstimate(model: model),
            charging: b.charging,
            rawState: Int(b.raw)
        )
    }

    /// Firmware version number (the vendor app derives the model from its leading digits).
    public func readVersion() -> Int? {
        guard let reply = exchange(MlProtocol.cmdGetVersion) else { return nil }
        return MlProtocol.replyInt(reply.0, length: reply.1)
    }

    /// The JSON board-info document, or nil if the device does not answer.
    public func readBoardInfo() -> String? {
        guard let reply = exchange(MlProtocol.cmdGetBoardInfo, replySize: MlProtocol.maxCommandReply) else { return nil }
        return MlProtocol.parseBoardInfo(reply.0, length: reply.1)
    }

    // ---- internals --------------------------------------------------------

    /// Send a command and wait for the matching reply, retrying like the vendor library does.
    /// Returns the reply buffer and its length, or nil.
    private func exchange(
        _ command: Int,
        parameter: Int = 0,
        replySize: Int = 0x400,
        attempts: Int = 3
    ) -> ([UInt8], Int)? {
        commandLock.lock()
        defer { commandLock.unlock() }
        guard let socket = commandSocket else { return nil }
        let seq = locked { () -> Int32 in
            defer { sequence &+= 1 }
            return sequence
        }
        let request = MlProtocol.request(command, sequence: Int(seq), parameter: parameter)
        var buffer = [UInt8](repeating: 0, count: replySize)
        for _ in 0..<attempts {
            let datagram: Datagram?
            do {
                try socket.send(request, to: info.host, port: MlProtocol.commandPort)
                datagram = try socket.receive(into: &buffer, timeout: Self.commandTimeout)
            } catch {
                return nil
            }
            guard let datagram else { continue }
            if MlProtocol.replyMatches(buffer, length: datagram.length, command: command) {
                return (buffer, datagram.length)
            }
        }
        return nil
    }

    private func udpVideoLoop(_ worker: Worker) {
        let socket: UDPSocket
        do {
            socket = try UDPSocket(binding: binding)
            try socket.bind()
            socket.setReceiveBufferSize(2 * 1024 * 1024)
        } catch {
            DebugLog.log("MlClient", "udp video: could not open socket", error)
            return
        }
        let start = MlProtocol.videoControl(MlProtocol.videoStart)
        let stop = MlProtocol.videoControl(MlProtocol.videoStop)
        let assembler = MlFrameAssembler()
        var buffer = [UInt8](repeating: 0, count: MlProtocol.maxVideoDatagram)
        var lastStartMs: Int64 = 0
        defer {
            try? socket.send(stop, to: info.host, port: MlProtocol.videoPort)
            socket.close()
        }
        while !worker.isCancelled {
            let now = Clock.ms()
            if now - lastStartMs > MlProtocol.videoKeepAliveMs {
                try? socket.send(start, to: info.host, port: MlProtocol.videoPort)
                lastStartMs = now
            }
            let datagram: Datagram?
            do {
                datagram = try socket.receive(into: &buffer, timeout: Self.videoTimeout)
            } catch {
                worker.sleep(0.05)
                continue
            }
            guard let datagram,
                  let chunk = MlProtocol.parseVideoChunk(buffer, length: datagram.length),
                  let frame = assembler.offer(chunk, datagram: buffer) else { continue }
            if assembler.framesCompleted == 1 { DebugLog.log("MlClient", "first UDP frame: \(frame.jpeg.count) bytes") }
            emit(frame.jpeg, angleRaw: frame.angleRaw)
        }
    }

    private func tcpVideoLoop(_ worker: Worker) {
        var block = [UInt8](repeating: 0, count: 32 * 1024)
        while !worker.isCancelled {
            do {
                let socket = try TCPSocket(binding: binding)
                defer { socket.close() }
                try socket.connect(host: info.host, port: MlProtocol.tcpVideoPort, timeout: Self.tcpConnectTimeout)
                let parser = MlTcpStreamParser { [self] jpeg, header in
                    if parserFrames == 0 { DebugLog.log("MlClient", "first TCP frame: \(jpeg.count) bytes") }
                    parserFrames += 1
                    emit(jpeg, angleRaw: header.angleRaw)
                }
                while !worker.isCancelled {
                    // A quiet stream is not an error: keep the connection and wait.
                    guard let n = try socket.read(into: &block, timeout: 0.25) else { continue }
                    if n == 0 { break }
                    parser.feed(block, count: n)
                }
            } catch {
                DebugLog.log("MlClient", "tcp \(info.host):\(MlProtocol.tcpVideoPort): \(error)")
            }
            if !worker.sleep(Self.tcpRetryInterval) { break }
        }
    }

    /// Only touched by the TCP loop.
    private var parserFrames = 0

    private func emit(_ jpeg: [UInt8], angleRaw: UInt32) {
        let angle = locked { () -> Float in
            if let a = angleDecoder.decode(angleRaw) { lastAngle = a }
            return lastAngle
        }
        frameSink.yield(VideoFrame(jpeg: jpeg, angleDegrees: angle, receivedAtMs: Clock.ms()))
    }
}

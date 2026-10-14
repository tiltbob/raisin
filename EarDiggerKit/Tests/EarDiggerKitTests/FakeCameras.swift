@testable import EarDiggerKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Stand-ins for the scopes, listening on loopback on the real ports, so the clients and
/// discoveries can be exercised end to end without hardware.

/// Thread-safe recorder for what a fake camera received.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ s: String) {
        lock.lock()
        items.append(s)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func contains(_ s: String) -> Bool { all.contains(s) }
}

/// Runs [body] repeatedly on a thread until stopped.
final class Loop: @unchecked Sendable {
    private let flag = CancelFlag()
    private let done = DispatchSemaphore(value: 0)

    init(_ body: @escaping (CancelFlag) -> Void) {
        let flag = self.flag
        let done = self.done
        Thread {
            body(flag)
            done.signal()
        }.start()
    }

    func stop() {
        flag.cancel()
        _ = done.wait(timeout: .now() + 3)
    }
}

/// A tube scope: commands on 58090, video on 58080, a fixed JPEG streamed in 1000-byte chunks.
final class FakeTubeCamera: @unchecked Sendable {
    static let boardInfo = #"{"brand":"bebird","model":"R1","firmware":"T1.0","ssid":"bebird-R1-630136","float_angle":0,"rotate_angle":0,"battery":131137}"#
    let jpeg = FrameAssemblerTests.fakeJpeg(7_500)
    let received = Recorder()
    private let lock = NSLock()
    private var light = 70
    private var pendingLight = 70
    private var viewer: (String, UInt16)?
    private var loops: [Loop] = []
    private let command: UDPSocket
    private let video: UDPSocket

    init() throws {
        command = try UDPSocket()
        command.setReuseAddress()
        try command.bind(port: TubeProtocol.commandPort)
        video = try UDPSocket()
        video.setReuseAddress()
        try video.bind(port: TubeProtocol.videoPort)
        loops.append(Loop { [self] flag in serveCommands(flag) })
        loops.append(Loop { [self] flag in serveVideo(flag) })
        loops.append(Loop { [self] flag in stream(flag) })
    }

    var lightLevel: Int {
        lock.lock()
        defer { lock.unlock() }
        return light
    }

    func stop() {
        loops.forEach { $0.stop() }
        command.close()
        video.close()
    }

    private func serveCommands(_ flag: CancelFlag) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while !flag.isCancelled {
            guard let d = try? command.receive(into: &buf, timeout: 0.05) else { continue }
            let req = Array(buf[0..<d.length])
            received.add(DebugLog.hex(req, length: req.count))
            func reply(_ bytes: [UInt8]) { try? command.send(bytes, to: d.host, port: d.port) }
            switch req {
            case TubeProtocol.getBoardInfo:
                // Two datagrams, like a long board-info document.
                let all = Array(Self.boardInfo.utf8)
                reply(Array(all[0..<40]))
                reply(Array(all[40...]))
            case TubeProtocol.getBattery:
                reply([0x00, 0x02, 0x00, 0x41]) // charging, 65 %
            case TubeProtocol.queryBrightness:
                lock.lock()
                let level = light
                lock.unlock()
                reply([UInt8(level)])
            case TubeProtocol.commitBrightness:
                lock.lock()
                light = pendingLight
                lock.unlock()
            default:
                if req.count == 3, req[0] == 0x66, req[1] == 0x3C {
                    lock.lock()
                    pendingLight = Int(req[2])
                    lock.unlock()
                }
            }
        }
    }

    private func serveVideo(_ flag: CancelFlag) {
        var buf = [UInt8](repeating: 0, count: 64)
        while !flag.isCancelled {
            guard let d = try? video.receive(into: &buf, timeout: 0.05) else { continue }
            let req = Array(buf[0..<d.length])
            lock.lock()
            if req == TubeProtocol.startVideo {
                viewer = (d.host, d.port)
                received.add("START from \(d.port)")
            } else if req == TubeProtocol.stopVideo {
                viewer = nil
                received.add("STOP from \(d.port)")
            }
            lock.unlock()
        }
    }

    private func stream(_ flag: CancelFlag) {
        var frameId = 0
        while !flag.isCancelled {
            Thread.sleep(forTimeInterval: 0.04)
            lock.lock()
            let target = viewer
            lock.unlock()
            guard let (host, port) = target else { continue }
            frameId = (frameId + 1) % 256
            // angle 300 degrees in integer mode: low byte 44, flag 2
            for d in FrameAssemblerTests.chunk(jpeg, 1000, frameId: frameId, lastFlag: 2, angleLow: 44) {
                try? video.send(d, to: host, port: port)
            }
        }
    }
}

/// An ML scope: commands on 50000, UDP video on 8030 and/or TCP video on 7060.
final class FakeMlCamera: @unchecked Sendable {
    static let boardInfo = #"{"model":"M9 Pro","brand":"bebird","hardware":"ML-7","uuid":"x"}"#
    let jpeg = MlFrameAssemblerTests.jpeg(9_000)
    let received = Recorder()
    private let lock = NSLock()
    private var light = 40
    private var viewer: (String, UInt16)?
    private var lastStartMs: Int64 = 0
    private var loops: [Loop] = []
    private let command: UDPSocket
    private let video: UDPSocket?
    private let tcp: TestTCPServer?

    init(udpVideo: Bool, tcpVideo: Bool) throws {
        command = try UDPSocket()
        command.setReuseAddress()
        try command.bind(port: MlProtocol.commandPort)
        if udpVideo {
            let v = try UDPSocket()
            v.setReuseAddress()
            try v.bind(port: MlProtocol.videoPort)
            video = v
        } else {
            video = nil
        }
        tcp = tcpVideo ? try TestTCPServer(port: MlProtocol.tcpVideoPort) : nil
        loops.append(Loop { [self] flag in serveCommands(flag) })
        if video != nil {
            loops.append(Loop { [self] flag in serveVideoControl(flag) })
            loops.append(Loop { [self] flag in streamUdp(flag) })
        }
        if tcp != nil { loops.append(Loop { [self] flag in streamTcp(flag) }) }
    }

    var lightLevel: Int {
        lock.lock()
        defer { lock.unlock() }
        return light
    }

    func stop() {
        loops.forEach { $0.stop() }
        command.close()
        video?.close()
        tcp?.close()
    }

    private func serveCommands(_ flag: CancelFlag) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while !flag.isCancelled {
            guard let d = try? command.receive(into: &buf, timeout: 0.05), d.length >= 24 else { continue }
            let cmd = Bytes.u16le(buf, 2)
            let param = Bytes.u32le(buf, 8)
            received.add(String(format: "0x%04x %d", cmd, param))
            var reply = [UInt8](repeating: 0, count: 24)
            Bytes.putU16le(&reply, 0, 0x9999)
            Bytes.putU16le(&reply, 2, UInt16(cmd))
            switch cmd {
            case MlProtocol.cmdGetBoardInfo:
                reply = MlProtocolTests.boardInfoReply(Self.boardInfo)
            case MlProtocol.cmdGetBattery:
                Bytes.putU32le(&reply, 8, 3900) // not charging, 3.9 V
            case MlProtocol.cmdGetLight:
                lock.lock()
                Bytes.putU32le(&reply, 8, UInt32(light))
                lock.unlock()
            case MlProtocol.cmdSetLight:
                lock.lock()
                light = Int(param)
                lock.unlock()
            case MlProtocol.cmdGetVersion:
                Bytes.putU32le(&reply, 8, 718)
            default:
                break
            }
            try? command.send(reply, to: d.host, port: d.port)
        }
    }

    private func serveVideoControl(_ flag: CancelFlag) {
        guard let video else { return }
        var buf = [UInt8](repeating: 0, count: 64)
        while !flag.isCancelled {
            guard let d = try? video.receive(into: &buf, timeout: 0.05), d.length >= 4 else { continue }
            let cmd = Bytes.u16le(buf, 2)
            lock.lock()
            if cmd == MlProtocol.videoStart {
                viewer = (d.host, d.port)
                lastStartMs = Clock.ms()
            } else if cmd == MlProtocol.videoStop {
                viewer = nil
                received.add("UDP STOP")
            }
            lock.unlock()
        }
    }

    private func streamUdp(_ flag: CancelFlag) {
        guard let video else { return }
        var frameId = 100
        while !flag.isCancelled {
            Thread.sleep(forTimeInterval: 0.04)
            lock.lock()
            // Like the real scope, stop streaming when the START repeats stop coming.
            let target = Clock.ms() - lastStartMs < 2000 ? viewer : nil
            lock.unlock()
            guard let (host, port) = target else { continue }
            frameId += 1
            let key = UInt32(frameId * 7919)
            for d in MlFrameAssemblerTests.datagrams(frameId: frameId, jpeg, chunkSize: 2900, key: key, plain: false) {
                try? video.send(d, to: host, port: port)
            }
        }
    }

    private func streamTcp(_ flag: CancelFlag) {
        guard let tcp else { return }
        while !flag.isCancelled {
            guard let client = tcp.accept(timeout: 0.1) else { continue }
            received.add("TCP connect")
            // Absolute angle of 90 degrees in the orientation word.
            let frame = MlTcpStreamParserTests.frame(jpeg, trailing: 2, angleRaw: 0x8000_0000 | 90_000)
            while !flag.isCancelled && client.send(frame) {
                Thread.sleep(forTimeInterval: 0.04)
            }
            client.close()
        }
    }
}

/// A minimal TCP listener for the fake ML camera.
final class TestTCPServer: @unchecked Sendable {
    private var fd: Int32

    init(port: UInt16) throws {
        #if canImport(Darwin)
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SocketError("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = try IPv4.address("127.0.0.1", port: port)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0, listen(fd, 4) == 0 else { throw SocketError("bind/listen") }
    }

    func accept(timeout: TimeInterval) -> Connection? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        #if canImport(Darwin)
        let c = Darwin.accept(fd, nil, nil)
        #else
        let c = Glibc.accept(fd, nil, nil)
        #endif
        return c >= 0 ? Connection(fd: c) : nil
    }

    func close() {
        if fd >= 0 {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
            fd = -1
        }
    }

    final class Connection {
        let fd: Int32

        init(fd: Int32) {
            self.fd = fd
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
        }

        /// False once the peer has gone.
        func send(_ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                #if canImport(Darwin)
                let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
                #else
                let n = bytes[off...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                #endif
                if n <= 0 { return false }
                off += n
            }
            return true
        }

        func close() {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
        }
    }
}

import Dispatch
import Foundation

/// Finds ML-protocol cameras. There is no broadcast discovery in this generation: the camera
/// is always the access point at [MlProtocol.defaultHost], so we simply ask it (and the
/// other candidate addresses of the joined Wi-Fi, in case the address differs) for its
/// board info.
public enum MlDiscovery {
    private static let tag = "MlDiscovery"

    public static func probe(
        binding: SocketBinding,
        extraHosts: [String],
        includeDefault: Bool = true,
        cancel: CancelFlag = CancelFlag()
    ) -> [DeviceInfo] {
        let hosts = unique((includeDefault ? [MlProtocol.defaultHost] : []) + extraHosts)
        let results = Results(count: hosts.count)
        let group = DispatchGroup()
        for (i, host) in hosts.enumerated() {
            IO.queue.async(group: group) {
                results.set(i, probeHost(binding: binding, host: host, cancel: cancel))
            }
        }
        group.wait()
        return results.found
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DeviceInfo?]

        init(count: Int) { items = Array(repeating: nil, count: count) }

        func set(_ i: Int, _ info: DeviceInfo?) {
            lock.lock()
            items[i] = info
            lock.unlock()
        }

        var found: [DeviceInfo] {
            lock.lock()
            defer { lock.unlock() }
            return items.compactMap { $0 }
        }
    }

    public static func probeHost(
        binding: SocketBinding,
        host: String,
        port: UInt16 = MlProtocol.commandPort,
        cancel: CancelFlag = CancelFlag()
    ) -> DeviceInfo? {
        guard IPv4.isLiteral(host) else { return nil }
        let s: UDPSocket
        do {
            s = try UDPSocket(binding: binding)
            try s.bind()
        } catch {
            DebugLog.log(tag, "probe \(host): could not open socket", error)
            return nil
        }
        defer { s.close() }
        let raw = exchange(s, host: host, port: port, command: MlProtocol.cmdGetBoardInfo, replySize: MlProtocol.maxCommandReply, cancel: cancel)
        let boardInfo = raw.flatMap { MlProtocol.parseBoardInfo($0.0, length: $0.1) }
        let replyText = raw.map { "\($0.1)" } ?? "none"
        DebugLog.log(tag, "probe \(host): board info reply=\(replyText) bytes, parsed=\(boardInfo != nil)\(boardInfo.map { ": " + $0.prefix(200) } ?? "")")
        if let boardInfo { return fromBoardInfo(host: host, text: boardInfo) }
        if cancel.isCancelled { return nil }
        let version = exchange(s, host: host, port: port, command: MlProtocol.cmdGetVersion, replySize: 0x400, cancel: cancel)
            .flatMap { MlProtocol.replyInt($0.0, length: $0.1) }
        DebugLog.log(tag, "probe \(host): version reply=\(version.map(String.init) ?? "none")")
        guard let version else { return nil }
        return DeviceInfo(host: host, cameraProtocol: .ml, firmware: String(version))
    }

    public static func fromBoardInfo(host: String, text: String) -> DeviceInfo {
        let json = JSON.object(text)
        return DeviceInfo(
            host: host,
            cameraProtocol: .ml,
            model: json.flatMap { JSON.string($0, "model") },
            firmware: json.flatMap { JSON.string($0, "hardware") },
            brand: json.flatMap { JSON.string($0, "brand") },
            rawInfo: text
        )
    }

    private static func exchange(
        _ socket: UDPSocket,
        host: String,
        port: UInt16,
        command: Int,
        replySize: Int,
        cancel: CancelFlag,
        attempts: Int = 3
    ) -> ([UInt8], Int)? {
        var buffer = [UInt8](repeating: 0, count: replySize)
        for attempt in 0..<attempts {
            if cancel.isCancelled { return nil }
            let request = MlProtocol.request(command, sequence: attempt + 1)
            let datagram: Datagram?
            do {
                try socket.send(request, to: host, port: port)
                datagram = try socket.receive(into: &buffer, timeout: 0.2)
            } catch {
                DebugLog.log(tag, "cmd 0x\(String(command, radix: 16)) to \(host): io error", error)
                return nil
            }
            guard let datagram else { continue }
            if MlProtocol.replyMatches(buffer, length: datagram.length, command: command) { return (buffer, datagram.length) }
            DebugLog.log(tag, "cmd 0x\(String(command, radix: 16)): unexpected \(datagram.length) bytes from \(datagram.host): \(DebugLog.hex(buffer, length: datagram.length))")
        }
        return nil
    }
}

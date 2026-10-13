import Foundation

/// Finds tube-protocol cameras on the local Wi-Fi.
///
/// Two independent mechanisms, both exactly what the vendor app does:
///  - [probe]: send the board-info request to port 58090 (the well-known AP addresses, the
///    subnet broadcasts and any extra hosts) and collect the JSON replies;
///  - [listenForBeacons]: the scope broadcasts a JSON status beacon to port 58099 roughly ten
///    times a second, so just listening finds it without sending anything.
///
/// iOS only lets apps holding Apple's multicast entitlement send or receive broadcasts, so
/// there the unicast probes do the work and the broadcast paths simply find nothing.
public enum TubeDiscovery {
    private static let tag = "TubeDiscovery"

    /// Send a board-info request to the usual addresses plus [extraHosts] and collect the
    /// replies. With [stopAtFirst] the first parsed reply ends the wait: a scope's own
    /// network only ever has the one camera on it. [includeDefaults] adds the broadcast and
    /// well-known addresses (the tests turn it off to stay on loopback).
    public static func probe(
        binding: SocketBinding,
        extraHosts: [String],
        timeout: TimeInterval,
        stopAtFirst: Bool = false,
        includeDefaults: Bool = true,
        cancel: CancelFlag = CancelFlag()
    ) -> [DeviceInfo] {
        let s: UDPSocket
        do {
            s = try UDPSocket(binding: binding)
            s.setReuseAddress()
            try s.bind()
            s.setBroadcast()
        } catch {
            DebugLog.log(tag, "probe: could not open socket", error)
            return []
        }
        defer { s.close() }

        var targets: [String] = []
        if includeDefaults {
            targets += NetInterfaces.active().map(\.broadcast) + ["255.255.255.255"] + TubeProtocol.knownHosts
        }
        targets += extraHosts
        targets = unique(targets.filter(IPv4.isLiteral))
        DebugLog.log(tag, "probe: local port \(s.localPort), via \(binding), interfaces=\(NetInterfaces.summary()), targets=\(targets)")

        func sendProbes() {
            for t in targets {
                do {
                    try s.send(TubeProtocol.getBoardInfo, to: t, port: TubeProtocol.commandPort)
                } catch {
                    DebugLog.log(tag, "probe: send to \(t):\(TubeProtocol.commandPort) failed: \(error)")
                }
            }
        }
        sendProbes()

        var found: [DeviceInfo] = []
        var partial: [String: [UInt8]] = [:]
        var buffer = [UInt8](repeating: 0, count: TubeProtocol.maxDatagram)
        let start = Clock.ms()
        let timeoutMs = Int64(timeout * 1000)
        var resent = false
        while !cancel.isCancelled && Clock.ms() - start < timeoutMs {
            let datagram: Datagram?
            do {
                datagram = try s.receive(into: &buffer, timeout: 0.2)
            } catch {
                DebugLog.log(tag, "probe: receive failed", error)
                break
            }
            guard let datagram else {
                if !resent && Clock.ms() - start > timeoutMs / 2 {
                    sendProbes()
                    resent = true
                }
                continue
            }
            let host = datagram.host
            DebugLog.log(tag, "probe: \(datagram.length) bytes from \(host):\(datagram.port): \(DebugLog.hex(buffer, length: datagram.length))")
            if found.contains(where: { $0.host == host }) { continue }
            var acc = partial[host] ?? []
            acc += buffer[0..<datagram.length]
            partial[host] = acc
            if TubeProtocol.isBoardInfoComplete(acc, length: acc.count) {
                partial[host] = nil
                let text = String(decoding: acc, as: UTF8.self)
                let info = parseBoardInfo(host: host, text: text)
                DebugLog.log(tag, "probe: board info from \(host) parsed=\(info != nil): \(text)")
                if let info { found.append(info) }
                if stopAtFirst && !found.isEmpty { break }
            }
        }
        for (host, acc) in partial { DebugLog.log(tag, "probe: incomplete reply from \(host) (\(acc.count) bytes)") }
        DebugLog.log(tag, "probe: done, found \(found.map(\.host))")
        return found
    }

    public static func listenForBeacons(
        binding: SocketBinding,
        timeout: TimeInterval,
        port: UInt16 = TubeProtocol.beaconPort,
        cancel: CancelFlag = CancelFlag()
    ) -> [DeviceInfo] {
        let s: UDPSocket
        do {
            s = try UDPSocket(binding: binding)
            s.setReuseAddress()
            try s.bind(port: port)
        } catch {
            DebugLog.log(tag, "beacon: could not bind port \(port) (another app may hold it; the probe does not need it)", error)
            return []
        }
        defer { s.close() }
        DebugLog.log(tag, "beacon: listening on port \(port)")
        var found: [DeviceInfo] = []
        var datagrams = 0
        var buffer = [UInt8](repeating: 0, count: TubeProtocol.maxDatagram)
        let start = Clock.ms()
        let timeoutMs = Int64(timeout * 1000)
        while !cancel.isCancelled && Clock.ms() - start < timeoutMs {
            let datagram: Datagram?
            do {
                datagram = try s.receive(into: &buffer, timeout: 0.2)
            } catch {
                DebugLog.log(tag, "beacon: receive failed", error)
                break
            }
            guard let datagram else { continue }
            datagrams += 1
            let text = String(decoding: buffer[0..<datagram.length], as: UTF8.self)
            if datagrams <= 3 { DebugLog.log(tag, "beacon: from \(datagram.host): \(text.prefix(300))") }
            guard let json = JSON.object(text) else { continue }
            let host = JSON.string(json, "ipaddr") ?? datagram.host
            if found.contains(where: { $0.host == host }) { continue }
            found.append(
                DeviceInfo(
                    host: host,
                    cameraProtocol: .tube,
                    model: JSON.string(json, "model"),
                    ssid: JSON.string(json, "ssid"),
                    brand: JSON.string(json, "brand")
                )
            )
        }
        DebugLog.log(tag, "beacon: done, \(datagrams) datagrams, found \(found.map(\.host))")
        return found
    }

    /// Turn a board-info JSON document into a [DeviceInfo].
    public static func parseBoardInfo(host: String, text: String) -> DeviceInfo? {
        guard let json = JSON.object(text) else { return nil }
        return DeviceInfo(
            host: host,
            cameraProtocol: .tube,
            model: JSON.string(json, "model"),
            firmware: JSON.string(json, "firmware"),
            ssid: JSON.string(json, "ssid") ?? JSON.string(json, "ssid_prefix"),
            brand: JSON.string(json, "brand"),
            floatAngle: JSON.flag(json, "float_angle"),
            rotateAngle: JSON.int(json, "rotate_angle", default: 0),
            rawInfo: text
        )
    }
}

func unique(_ list: [String]) -> [String] {
    var seen = Set<String>()
    return list.filter { seen.insert($0).inserted }
}

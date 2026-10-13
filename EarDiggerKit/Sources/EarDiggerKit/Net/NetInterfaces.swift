import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One IPv4 address of a local network interface.
public struct IPv4Interface: Sendable, CustomStringConvertible {
    public let name: String
    public let address: String
    public let netmask: String
    public let isUp: Bool
    public let isLoopback: Bool

    var addressValue: UInt32 { IPv4.value(address) ?? 0 }
    var maskValue: UInt32 { IPv4.value(netmask) ?? 0 }

    public var prefixLength: Int { maskValue.nonzeroBitCount }

    /// The subnet's broadcast address.
    public var broadcast: String { IPv4.string(value: addressValue | ~maskValue) }

    /// The first host of the subnet (`x.y.z.1` on a /24), which on the scope's own network
    /// is the access point, i.e. the camera.
    public var firstHost: String? {
        let network = addressValue & maskValue
        guard maskValue != 0, ~maskValue > 1 else { return nil }
        let first = network | 1
        return first == addressValue ? nil : IPv4.string(value: first)
    }

    /// Link-local (169.254/16): what an interface has before DHCP answers.
    public var isLinkLocal: Bool { addressValue >> 16 == 0xA9FE }

    public var description: String { "\(name)=\(address)/\(prefixLength)(bc \(broadcast))" }
}

public enum NetInterfaces {
    // Flag values are the same on Linux and the BSDs.
    private static let iffUp: UInt32 = 0x1
    private static let iffLoopback: UInt32 = 0x8

    /// Every IPv4 address on the phone's interfaces.
    public static func ipv4() -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [IPv4Interface] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4.string($0.pointee.sin_addr) }
            var netmask = "255.255.255.255"
            if let mask = ifa.ifa_netmask {
                netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4.string($0.pointee.sin_addr) }
            }
            let flags = UInt32(ifa.ifa_flags)
            out.append(
                IPv4Interface(
                    name: String(cString: ifa.ifa_name),
                    address: address,
                    netmask: netmask,
                    isUp: flags & iffUp != 0,
                    isLoopback: flags & iffLoopback != 0
                )
            )
        }
        return out
    }

    /// Up, non-loopback IPv4 interfaces.
    public static func active() -> [IPv4Interface] {
        ipv4().filter { $0.isUp && !$0.isLoopback }
    }

    /// One-line summary for the debug log.
    public static func summary() -> String {
        let list = active()
        return list.isEmpty ? "none" : list.map(\.description).joined(separator: "; ")
    }
}

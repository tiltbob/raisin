import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Thin BSD-socket wrappers with the semantics the camera code needs (receive with a
// timeout, a fixed local port, broadcast, a connected UDP "peer"). Plain POSIX, so the
// same code runs on iOS and in the Linux tests.

#if canImport(Darwin)
private let sockDgram = SOCK_DGRAM
private let sockStream = SOCK_STREAM
private let c_socket = Darwin.socket
private let c_bind = Darwin.bind
private let c_connect = Darwin.connect
private let c_send = Darwin.send
private let c_sendto = Darwin.sendto
private let c_recv = Darwin.recv
private let c_recvfrom = Darwin.recvfrom
private let c_close = Darwin.close
private let c_poll = Darwin.poll
#else
private let sockDgram = Int32(SOCK_DGRAM.rawValue)
private let sockStream = Int32(SOCK_STREAM.rawValue)
private let c_socket = Glibc.socket
private let c_bind = Glibc.bind
private let c_connect = Glibc.connect
private let c_send = Glibc.send
private let c_sendto = Glibc.sendto
private let c_recv = Glibc.recv
private let c_recvfrom = Glibc.recvfrom
private let c_close = Glibc.close
private let c_poll = Glibc.poll
#endif

public struct SocketError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    init(_ operation: String, _ code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    /// The peer answered with ICMP port unreachable (or refused the TCP connection).
    public var isRefused: Bool { code == ECONNREFUSED }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Where camera sockets are pinned. The scope's Wi-Fi has no internet, so the phone may
/// keep its default route on cellular; binding to the Wi-Fi interface keeps every camera
/// packet on the scope's network (the Android app's `Network.bindSocket`).
public struct SocketBinding: Sendable, Equatable, CustomStringConvertible {
    public var interfaceName: String?
    public var interfaceIndex: UInt32?

    public init(interfaceName: String? = nil, interfaceIndex: UInt32? = nil) {
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
    }

    public static let none = SocketBinding()

    public var description: String {
        guard let index = interfaceIndex else { return "default route" }
        return "\(interfaceName ?? "if") (#\(index))"
    }

    fileprivate func apply(to fd: Int32) {
        #if canImport(Darwin)
        guard var index = interfaceIndex else { return }
        let ipBoundIf: Int32 = 25 // IP_BOUND_IF from <netinet/in.h>
        if setsockopt(fd, Int32(IPPROTO_IP), ipBoundIf, &index, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
            DebugLog.log("Socket", "bind to \(self) failed: \(SocketError("setsockopt(IP_BOUND_IF)"))")
        }
        #endif
        // Linux needs privileges to bind to a device; the tests run on loopback anyway.
    }
}

/// One received datagram: its length in the caller's buffer and who sent it.
public struct Datagram {
    public let length: Int
    public let host: String
    public let port: UInt16
}

enum IPv4 {
    static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw CameraError.badAddress(host) }
        return addr
    }

    static func isLiteral(_ host: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, host, &a) == 1
    }

    static func string(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: 16) // INET_ADDRSTRLEN
        guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return "?" }
        return String(cString: buf)
    }

    /// Host-order value of a dotted quad.
    static func value(_ host: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, host, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func string(value: UInt32) -> String {
        string(in_addr(s_addr: value.bigEndian))
    }
}

private func withSockaddr<T>(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// Wait until [fd] is readable (or writable). False on timeout.
private func waitFor(_ fd: Int32, events: Int16, timeout: TimeInterval) throws -> Bool {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    let ms = Int32(max(0, min(timeout, 3600)) * 1000)
    while true {
        let r = c_poll(&pfd, 1, ms)
        if r > 0 { return true }
        if r == 0 { return false }
        if errno == EINTR { continue }
        throw SocketError("poll")
    }
}

/// A UDP socket. Not thread-safe for concurrent receives; one loop owns each socket and
/// [close] is called once nothing is using it any more.
public final class UDPSocket {
    private let lock = NSLock()
    private var fd: Int32

    public init(binding: SocketBinding = .none) throws {
        fd = c_socket(AF_INET, sockDgram, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        binding.apply(to: fd)
    }

    deinit { close() }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd < 0
    }

    private func handle(_ op: String) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SocketError(op, EBADF) }
        return fd
    }

    private func setOption(_ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        guard let fd = try? handle("setsockopt") else { return false }
        var v = value
        return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    @discardableResult public func setReuseAddress(_ on: Bool = true) -> Bool {
        setOption(SOL_SOCKET, SO_REUSEADDR, on ? 1 : 0)
    }

    @discardableResult public func setBroadcast(_ on: Bool = true) -> Bool {
        setOption(SOL_SOCKET, SO_BROADCAST, on ? 1 : 0)
    }

    @discardableResult public func setReceiveBufferSize(_ bytes: Int) -> Bool {
        setOption(SOL_SOCKET, SO_RCVBUF, Int32(bytes))
    }

    @discardableResult public func setTrafficClass(_ tos: Int) -> Bool {
        setOption(Int32(IPPROTO_IP), Int32(IP_TOS), Int32(tos))
    }

    /// Bind to [port] on every local address; 0 picks a free port.
    public func bind(port: UInt16 = 0) throws {
        let fd = try handle("bind")
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: 0) // INADDR_ANY
        let r = withSockaddr(&addr) { c_bind(fd, $0, $1) }
        if r != 0 { throw SocketError("bind(:\(port))") }
    }

    public var localPort: UInt16 {
        guard let fd = try? handle("getsockname") else { return 0 }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return r == 0 ? UInt16(bigEndian: addr.sin_port) : 0
    }

    /// Fix the peer: sends go to it and only its datagrams are received.
    public func connect(host: String, port: UInt16) throws {
        let fd = try handle("connect")
        var addr = try IPv4.address(host, port: port)
        let r = withSockaddr(&addr) { c_connect(fd, $0, $1) }
        if r != 0 { throw SocketError("connect(\(host):\(port))") }
    }

    /// Send to the connected peer.
    public func send(_ bytes: [UInt8]) throws {
        let fd = try handle("send")
        let n = bytes.withUnsafeBytes { c_send(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 { throw SocketError("send") }
    }

    public func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        let fd = try handle("sendto")
        var addr = try IPv4.address(host, port: port)
        let n = bytes.withUnsafeBytes { buf in
            withSockaddr(&addr) { c_sendto(fd, buf.baseAddress, buf.count, 0, $0, $1) }
        }
        if n < 0 { throw SocketError("sendto(\(host):\(port))") }
    }

    /// Receive one datagram into [buffer], waiting at most [timeout] seconds. Nil on timeout.
    public func receive(into buffer: inout [UInt8], timeout: TimeInterval) throws -> Datagram? {
        let fd = try handle("receive")
        guard try waitFor(fd, events: Int16(POLLIN), timeout: timeout) else { return nil }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { c_recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len) }
            }
        }
        if n < 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return nil }
            throw SocketError("receive", e)
        }
        return Datagram(length: n, host: IPv4.string(addr.sin_addr), port: UInt16(bigEndian: addr.sin_port))
    }

    /// Throw away anything already queued, so the next receive matches the next request.
    public func drain(_ buffer: inout [UInt8]) {
        while (try? receive(into: &buffer, timeout: 0)) != nil {}
    }

    public func close() {
        lock.lock()
        let old = fd
        fd = -1
        lock.unlock()
        if old >= 0 { _ = c_close(old) }
    }
}

/// A TCP client socket for the ML video stream.
public final class TCPSocket {
    private let lock = NSLock()
    private var fd: Int32

    public init(binding: SocketBinding = .none) throws {
        fd = c_socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        binding.apply(to: fd)
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    deinit { close() }

    private func handle(_ op: String) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { throw SocketError(op, EBADF) }
        return fd
    }

    /// Connect, giving up after [timeout] seconds.
    public func connect(host: String, port: UInt16, timeout: TimeInterval) throws {
        let fd = try handle("connect")
        var addr = try IPv4.address(host, port: port)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let r = withSockaddr(&addr) { c_connect(fd, $0, $1) }
        if r == 0 { return }
        guard errno == EINPROGRESS else { throw SocketError("connect(\(host):\(port))") }
        guard try waitFor(fd, events: Int16(POLLOUT), timeout: timeout) else {
            throw SocketError("connect(\(host):\(port))", ETIMEDOUT)
        }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        if err != 0 { throw SocketError("connect(\(host):\(port))", err) }
    }

    /// Read what is available into [buffer], waiting at most [timeout] seconds.
    /// Nil on timeout, 0 when the peer closed the connection.
    public func read(into buffer: inout [UInt8], timeout: TimeInterval) throws -> Int? {
        let fd = try handle("read")
        guard try waitFor(fd, events: Int16(POLLIN), timeout: timeout) else { return nil }
        let n = buffer.withUnsafeMutableBytes { c_recv(fd, $0.baseAddress, $0.count, 0) }
        if n < 0 {
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { return nil }
            throw SocketError("read", e)
        }
        return n
    }

    public func close() {
        lock.lock()
        let old = fd
        fd = -1
        lock.unlock()
        if old >= 0 { _ = c_close(old) }
    }
}

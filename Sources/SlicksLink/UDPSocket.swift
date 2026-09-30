import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Bad network on demand, for testing on one machine. Applied to outgoing datagrams.
public struct NetConditions: Sendable, Equatable {
    /// Fraction of datagrams dropped, 0...1.
    public var loss = 0.0
    /// One-way delay in seconds.
    public var lag = 0.0
    /// Extra random delay up to this many seconds; reorders datagrams.
    public var jitter = 0.0
    /// Fraction of datagrams sent twice.
    public var duplicate = 0.0

    public init(loss: Double = 0, lag: Double = 0, jitter: Double = 0, duplicate: Double = 0) {
        self.loss = loss
        self.lag = lag
        self.jitter = jitter
        self.duplicate = duplicate
    }

    public static let none = NetConditions()
    public var isNone: Bool { self == .none }

    /// `SLIDEWAYS_NET_LOSS` (0-1), `SLIDEWAYS_NET_LAG_MS`, `SLIDEWAYS_NET_JITTER_MS`, `SLIDEWAYS_NET_DUP` (0-1).
    public static func fromEnvironment() -> NetConditions {
        let env = ProcessInfo.processInfo.environment
        func num(_ key: String) -> Double { Double(env[key] ?? "") ?? 0 }
        return NetConditions(loss: num("SLIDEWAYS_NET_LOSS"), lag: num("SLIDEWAYS_NET_LAG_MS") / 1000,
                             jitter: num("SLIDEWAYS_NET_JITTER_MS") / 1000, duplicate: num("SLIDEWAYS_NET_DUP"))
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)

    public var description: String {
        switch self {
        case let .system(what, code): "\(what) failed: \(String(cString: strerror(code)))"
        }
    }

    public var isAddressInUse: Bool {
        if case let .system(_, code) = self { return code == EADDRINUSE }
        return false
    }
}

/// A UDP socket that delivers datagrams on a dispatch queue. By default it's dual-stack
/// (IPv6 with IPv4-mapped addresses), so one socket serves both families.
public final class UDPSocket {
    public let port: UInt16
    public let isIPv4Only: Bool
    /// Called on the socket's queue for each datagram.
    public var onReceive: (([UInt8], SocketAddress) -> Void)?
    public var conditions: NetConditions
    public private(set) var isClosed = false

    /// Largest datagram accepted. Game packets are kept well under this.
    public static let maxDatagram = 2048

    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?

    /// - Parameters:
    ///   - port: 0 picks any free port.
    ///   - ipv4Only: an AF_INET socket, needed for IPv4 multicast (UPnP discovery).
    public init(port: UInt16 = 0, ipv4Only: Bool = false, queue: DispatchQueue = .main,
                conditions: NetConditions = .fromEnvironment()) throws {
        self.queue = queue
        self.conditions = conditions
        var ipv4Only = ipv4Only
        var fd = socket(ipv4Only ? AF_INET : AF_INET6, sockDgram, 0)
        if fd < 0, !ipv4Only, errno == EAFNOSUPPORT {
            // A machine with IPv6 switched off: IPv4 alone will do.
            ipv4Only = true
            fd = socket(AF_INET, sockDgram, 0)
        }
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        self.isIPv4Only = ipv4Only
        self.fd = fd
        var no: Int32 = 0
        var yes: Int32 = 1
        if !ipv4Only { setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size)) }
        #if canImport(Darwin)
        // Don't die on writes to a socket the peer can't receive on.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var buf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        _ = yes

        let any = SocketAddress(ip: ipv4Only ? [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0] : [UInt8](repeating: 0, count: 16),
                                port: port)
        let socketFD = fd
        let bound = any.withSockAddr(ipv4Socket: ipv4Only) { bind(socketFD, $0, $1) } ?? -1
        guard bound == 0 else {
            let e = errno
            Darwin_close(fd)
            throw SocketError.system("bind", e)
        }
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &len) }
        }
        self.port = SocketAddress(storage: &storage)?.port ?? port
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { Darwin_close(socketFD) }
        src.resume()
        source = src
    }

    deinit { close() }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
    }

    /// Joins an IPv4 multicast group (IPv4-only sockets).
    public func joinMulticast(_ group: String) {
        var mreq = ip_mreq()
        inet_pton(AF_INET, group, &mreq.imr_multiaddr)
        mreq.imr_interface.s_addr = 0
        setsockopt(fd, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
    }

    /// Sends now and returns the error code (0 on success). Ignores simulated conditions.
    @discardableResult
    public func sendNow(_ bytes: [UInt8], to address: SocketAddress) -> Int32 {
        guard !isClosed else { return EBADF }
        let n = address.withSockAddr(ipv4Socket: isIPv4Only) { sa, len in
            bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, bytes.count, 0, sa, len) }
        } ?? -1
        return n < 0 ? errno : 0
    }

    public func send(_ bytes: [UInt8], to address: SocketAddress) {
        guard !isClosed else { return }
        if conditions.isNone { return transmit(bytes, to: address) }
        if Double.random(in: 0..<1) < conditions.loss { return }
        let copies = Double.random(in: 0..<1) < conditions.duplicate ? 2 : 1
        for _ in 0..<copies {
            let delay = conditions.lag + Double.random(in: 0...max(conditions.jitter, 0))
            if delay <= 0 {
                transmit(bytes, to: address)
            } else {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.transmit(bytes, to: address) }
            }
        }
    }

    private func transmit(_ bytes: [UInt8], to address: SocketAddress) {
        guard !isClosed else { return }
        _ = address.withSockAddr(ipv4Socket: isIPv4Only) { sa, len in
            bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, bytes.count, 0, sa, len) }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !isClosed {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len) }
                }
            }
            if n < 0 { return } // EAGAIN (drained) or an ICMP-reported error; either way wait for more.
            guard n <= Self.maxDatagram, let from = SocketAddress(storage: &storage) else { continue }
            onReceive?(Array(buffer[0..<n]), from)
        }
    }
}

/// `close` is shadowed by the method above inside the class.
@inline(__always) private func Darwin_close(_ fd: Int32) {
    #if canImport(Glibc)
    _ = Glibc.close(fd)
    #elseif canImport(Musl)
    _ = Musl.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

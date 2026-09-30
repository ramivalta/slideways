import Foundation
#if canImport(Glibc)
import Glibc
let sockDgram = Int32(SOCK_DGRAM.rawValue)
#elseif canImport(Musl)
import Musl
let sockDgram = Int32(SOCK_DGRAM)
#elseif canImport(Darwin)
import Darwin
let sockDgram = SOCK_DGRAM
#endif

/// An IP address and UDP port. IPv4 addresses are kept in IPv4-mapped IPv6 form so one
/// dual-stack socket can talk to both.
public struct SocketAddress: Hashable, Sendable, CustomStringConvertible {
    /// 16 bytes, network order.
    public let ip: [UInt8]
    public let port: UInt16
    public let scopeID: UInt32

    public init(ip: [UInt8], port: UInt16, scopeID: UInt32 = 0) {
        precondition(ip.count == 16)
        self.ip = ip
        self.port = port
        self.scopeID = scopeID
    }

    /// Numeric addresses only ("192.168.1.5", "::1", "fe80::1%en0"). Use `resolve` for names.
    public init?(numeric host: String, port: UInt16) {
        var h = host
        var scope: UInt32 = 0
        if let pct = h.firstIndex(of: "%") {
            scope = if_nametoindex(String(h[h.index(after: pct)...]))
            h = String(h[..<pct])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            self.init(ip: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + b, port: port)
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            self.init(ip: withUnsafeBytes(of: &v6) { Array($0) }, port: port, scopeID: scope)
            return
        }
        return nil
    }

    public var isIPv4: Bool { ip[0..<10].allSatisfy { $0 == 0 } && ip[10] == 0xFF && ip[11] == 0xFF }
    public var isLoopback: Bool {
        isIPv4 ? ip[12] == 127 : ip == [UInt8](repeating: 0, count: 15) + [1]
    }

    /// Private, link-local or loopback: the other side is on the same network as us.
    public var isLocalNetwork: Bool {
        if isIPv4 {
            let a = ip[12], b = ip[13]
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
                || (a == 100 && (64...127).contains(b)) // carrier-grade NAT / Tailscale
        }
        return isLoopback || (ip[0] == 0xFE && ip[1] & 0xC0 == 0x80) || ip[0] & 0xFE == 0xFC
    }

    /// Text without the port.
    public var host: String {
        if isIPv4 { return ip[12...].map(String.init).joined(separator: ".") }
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: ip) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    public var description: String { isIPv4 ? "\(host):\(port)" : "[\(host)]:\(port)" }

    /// Same address with another port.
    public func with(port: UInt16) -> SocketAddress { SocketAddress(ip: ip, port: port, scopeID: scopeID) }

    // MARK: sockaddr bridging

    func withSockAddr<R>(ipv4Socket: Bool, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        if ipv4Socket {
            guard isIPv4 else { return nil }
            var sa = sockaddr_in()
            #if canImport(Darwin)
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &sa.sin_addr) { $0.copyBytes(from: ip[12...]) }
            return withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var sa = sockaddr_in6()
        #if canImport(Darwin)
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        sa.sin6_family = sa_family_t(AF_INET6)
        sa.sin6_port = port.bigEndian
        sa.sin6_scope_id = scopeID
        withUnsafeMutableBytes(of: &sa.sin6_addr) { $0.copyBytes(from: ip) }
        return withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    init?(storage: UnsafePointer<sockaddr_storage>) {
        switch Int32(storage.pointee.ss_family) {
        case AF_INET:
            let sa = UnsafeRawPointer(storage).assumingMemoryBound(to: sockaddr_in.self).pointee
            var addr = sa.sin_addr
            let b = withUnsafeBytes(of: &addr) { Array($0) }
            self.init(ip: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + b, port: UInt16(bigEndian: sa.sin_port))
        case AF_INET6:
            let sa = UnsafeRawPointer(storage).assumingMemoryBound(to: sockaddr_in6.self).pointee
            var addr = sa.sin6_addr
            self.init(ip: withUnsafeBytes(of: &addr) { Array($0) }, port: UInt16(bigEndian: sa.sin6_port), scopeID: sa.sin6_scope_id)
        default:
            return nil
        }
    }

    // MARK: Parsing and lookup

    /// Splits "host", "host:port", "1.2.3.4:5678", "[::1]:5678". Missing port gives `defaultPort`.
    public static func split(_ text: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.isEmpty { return host.isEmpty ? nil : (host, defaultPort) }
            guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()), p != 0 else { return nil }
            return (host, p)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let colon = s.firstIndex(of: ":") {
            guard let p = UInt16(s[s.index(after: colon)...]), p != 0 else { return nil }
            let host = String(s[..<colon])
            return host.isEmpty ? nil : (host, p)
        }
        // Bare IPv6 without brackets, or a plain host name.
        return (s, defaultPort)
    }

    /// Resolves a name or numeric address off the calling thread, then calls back on `queue`.
    public static func resolve(_ text: String, defaultPort: UInt16, queue: DispatchQueue = .main,
                               completion: @escaping ([SocketAddress]) -> Void) {
        guard let (host, port) = split(text, defaultPort: defaultPort) else { return queue.async { completion([]) } }
        if let numeric = SocketAddress(numeric: host, port: port) { return queue.async { completion([numeric]) } }
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = sockDgram
            var list: UnsafeMutablePointer<addrinfo>?
            var out: [SocketAddress] = []
            if getaddrinfo(host, String(port), &hints, &list) == 0, let first = list {
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if let sa = ai.pointee.ai_addr {
                        var storage = sockaddr_storage()
                        withUnsafeMutableBytes(of: &storage) { dst in
                            dst.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(ai.pointee.ai_addrlen)))
                        }
                        if let a = SocketAddress(storage: &storage), !out.contains(a) { out.append(a) }
                    }
                    p = ai.pointee.ai_next
                }
                freeaddrinfo(first)
            }
            // IPv4 first: more likely to get through home routers than a firewalled IPv6 path.
            out.sort { $0.isIPv4 && !$1.isIPv4 }
            let result = out
            queue.async { completion(result) }
        }
    }

    /// This machine's addresses on interfaces that are up (no loopback), IPv4 first.
    public static func localAddresses(port: UInt16) -> [SocketAddress] {
        var out: [SocketAddress] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let sa = ifa.pointee.ifa_addr, flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var storage = sockaddr_storage()
            let len = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: len)) }
            guard let a = SocketAddress(storage: &storage)?.with(port: port) else { continue }
            // Skip link-local IPv6 (needs a scope to be usable) and self-assigned IPv4.
            if !a.isIPv4 && a.ip[0] == 0xFE && a.ip[1] & 0xC0 == 0x80 { continue }
            if a.isIPv4 && a.ip[12] == 169 && a.ip[13] == 254 { continue }
            if !out.contains(a) { out.append(a) }
        }
        return out.sorted { $0.isIPv4 && !$1.isIPv4 }
    }
}

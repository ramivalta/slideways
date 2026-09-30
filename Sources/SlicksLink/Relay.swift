import Foundation
import SlicksBytes

/// Short codes for games. Letters and digits that can't be mistaken for each other.
public enum RoomCode {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func random(length: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Uppercases and drops spaces and dashes. Nil if anything outside the alphabet is left
    /// (O, 0, I and 1 are never used, so there's nothing to confuse them with).
    public static func normalize(_ text: String) -> String? {
        let out = String(text.uppercased().filter { $0 != "-" && $0 != " " })
        return out.allSatisfy(alphabet.contains) ? out : nil
    }
}

/// Messages between games and the rendezvous/relay server. Every packet starts with "SR" so
/// a game socket can tell them apart from game packets ("SW").
public enum RelayMessage: Equatable, Sendable {
    /// Host to server, every few seconds: keep my room open. `hostKey` proves it's the same host.
    case register(hostKey: [UInt8], local: [SocketAddress])
    /// Server to host: your room code, and the address you appear to come from.
    case registered(room: String, publicAddress: SocketAddress)
    case unregister(hostKey: [UInt8])
    /// Player to server: where is this room?
    case lookup(room: String)
    /// Server to player: the host's addresses, and a session for relaying if direct fails.
    case peer(room: String, session: UInt64, hostPublic: SocketAddress, hostLocal: [SocketAddress])
    case notFound(room: String)
    /// Server to host: a player is coming from this address; punch a hole toward it.
    case intro(session: UInt64, client: SocketAddress)
    /// Either way: forward this game packet to the other end of the session.
    case relay(session: UInt64, payload: [UInt8])
    case refused(reason: String)

    public static let magic: [UInt8] = [0x53, 0x52]
    public static let defaultPort: UInt16 = 47810
    public static let roomLength = 4
    public static let hostKeyLength = 16
    public static let maxPayload = 1400

    public static func isRelayPacket(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[0] == magic[0] && bytes[1] == magic[1]
    }

    private enum Kind: UInt8 {
        case register = 1, registered, unregister, lookup, peer, notFound, intro, relay, refused
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter(capacity: 64)
        w.raw(Self.magic)
        func addr(_ a: SocketAddress) { w.raw(a.ip); w.u16(a.port) }
        func addrs(_ list: [SocketAddress]) { w.u8(UInt8(min(list.count, 4))); list.prefix(4).forEach(addr) }
        switch self {
        case let .register(key, local): w.u8(Kind.register.rawValue); w.raw(key); addrs(local)
        case let .registered(room, a): w.u8(Kind.registered.rawValue); w.string(room); addr(a)
        case let .unregister(key): w.u8(Kind.unregister.rawValue); w.raw(key)
        case let .lookup(room): w.u8(Kind.lookup.rawValue); w.string(room)
        case let .peer(room, s, pub, local): w.u8(Kind.peer.rawValue); w.string(room); w.u64(s); addr(pub); addrs(local)
        case let .notFound(room): w.u8(Kind.notFound.rawValue); w.string(room)
        case let .intro(s, client): w.u8(Kind.intro.rawValue); w.u64(s); addr(client)
        case let .relay(s, payload): w.u8(Kind.relay.rawValue); w.u64(s); w.raw(payload)
        case let .refused(reason): w.u8(Kind.refused.rawValue); w.string(reason)
        }
        return w.bytes
    }

    public init(decoding bytes: [UInt8]) throws {
        guard Self.isRelayPacket(bytes) else { throw WireError.invalid("relay magic") }
        var r = ByteReader(slice: bytes.dropFirst(2))
        func addr() throws -> SocketAddress { SocketAddress(ip: try r.raw(16), port: try r.u16()) }
        func addrs() throws -> [SocketAddress] {
            let n = Int(try r.u8())
            guard n <= 4 else { throw WireError.invalid("address count") }
            return try (0..<n).map { _ in try addr() }
        }
        func room() throws -> String {
            let s = try r.string(maxLength: 16)
            guard s.count == Self.roomLength, s.allSatisfy(RoomCode.alphabet.contains) else { throw WireError.invalid("room") }
            return s
        }
        guard let kind = Kind(rawValue: try r.u8()) else { throw WireError.invalid("relay type") }
        switch kind {
        case .register: self = .register(hostKey: try r.raw(Self.hostKeyLength), local: try addrs())
        case .registered: self = .registered(room: try room(), publicAddress: try addr())
        case .unregister: self = .unregister(hostKey: try r.raw(Self.hostKeyLength))
        case .lookup: self = .lookup(room: try room())
        case .peer: self = .peer(room: try room(), session: try r.u64(), hostPublic: try addr(), hostLocal: try addrs())
        case .notFound: self = .notFound(room: try room())
        case .intro: self = .intro(session: try r.u64(), client: try addr())
        case .relay:
            let s = try r.u64()
            let payload = r.rest()
            guard payload.count <= Self.maxPayload else { throw WireError.invalid("relay size") }
            self = .relay(session: s, payload: payload)
        case .refused: self = .refused(reason: try r.string())
        }
        guard r.isAtEnd else { throw WireError.invalid("trailing bytes") }
    }
}

/// Token bucket: `rate` per second, holding at most `burst`.
struct TokenBucket {
    let rate: Double
    let burst: Double
    private var tokens: Double
    private(set) var last: Double

    init(rate: Double, burst: Double, now: Double) {
        self.rate = rate
        self.burst = burst
        tokens = burst
        last = now
    }

    mutating func take(_ n: Double = 1, now: Double) -> Bool {
        tokens = min(burst, tokens + (now - last) * rate)
        last = now
        guard tokens >= n else { return false }
        tokens -= n
        return true
    }
}

func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// The rendezvous/relay server. Hosts register a room; players look it up by code and get the
/// host's addresses so both sides can punch through their routers. When that fails, game
/// packets are relayed through here. They're encrypted end to end, so the server can't read
/// or alter them (it only sees sizes and timing).
public final class RelayServer {
    struct Room {
        let code: String
        let hostKey: [UInt8]
        let owner: [UInt8]
        var host: SocketAddress
        var local: [SocketAddress]
        var lastSeen: Double
        var sessions: Set<UInt64> = []
    }

    struct Session {
        let room: String
        let client: SocketAddress
        var lastSeen: Double
        /// Relay traffic seen, i.e. someone is actually playing through it.
        var active = false
    }

    public struct Limits: Sendable {
        public var maxRooms = 20_000
        /// Rooms one source (IPv4 address or IPv6 /64) may hold open.
        public var roomsPerSource = 4
        public var maxSessionsPerRoom = 32
        /// Sessions one source may hold in one room (a household with a few machines).
        public var sessionsPerSourcePerRoom = 4
        public var roomTimeout = 30.0
        public var sessionTimeout = 90.0
        /// A looked-up session nobody relays through can be reclaimed after this long.
        public var idleSessionTimeout = 15.0
        /// Per source.
        public var packetsPerSecond = 3000.0
        public var bytesPerSecond = 3_000_000.0
        public var lookupsPerMinute = 30.0
        public init() {}
    }

    /// Rate limits and quotas key on this: the IPv4 address, or the IPv6 /64 (what one
    /// household or server usually gets, so hopping addresses within it doesn't help).
    static func sourceKey(_ a: SocketAddress) -> [UInt8] { a.isIPv4 ? a.ip : Array(a.ip[0..<8]) }

    public let socket: UDPSocket
    public var log: (String) -> Void = { print($0) }
    public let limits: Limits

    private var rooms: [String: Room] = [:]
    private var roomByKey: [[UInt8]: String] = [:]
    private var sessions: [UInt64: Session] = [:]
    private var sessionByClient: [String: UInt64] = [:]
    private var packetBuckets: [[UInt8]: TokenBucket] = [:]
    private var byteBuckets: [[UInt8]: TokenBucket] = [:]
    private var lookupBuckets: [[UInt8]: TokenBucket] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private let queue: DispatchQueue
    public private(set) var relayedBytes = 0

    public init(port: UInt16 = RelayMessage.defaultPort, queue: DispatchQueue = .main, limits: Limits = Limits()) throws {
        self.queue = queue
        self.limits = limits
        socket = try UDPSocket(port: port, queue: queue, conditions: .none)
        socket.onReceive = { [weak self] bytes, from in self?.handle(bytes, from: from) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        sweepTimer = t
    }

    deinit { sweepTimer?.cancel() }

    public var roomCount: Int { rooms.count }
    public var sessionCount: Int { sessions.count }

    private func send(_ m: RelayMessage, to a: SocketAddress) { socket.send(m.encoded(), to: a) }

    private func handle(_ bytes: [UInt8], from: SocketAddress) {
        let now = monotonicSeconds()
        let ip = Self.sourceKey(from)
        var pb = packetBuckets[ip] ?? TokenBucket(rate: limits.packetsPerSecond, burst: limits.packetsPerSecond * 2, now: now)
        var bb = byteBuckets[ip] ?? TokenBucket(rate: limits.bytesPerSecond, burst: limits.bytesPerSecond * 2, now: now)
        let allowed = pb.take(now: now) && bb.take(Double(bytes.count), now: now)
        packetBuckets[ip] = pb
        byteBuckets[ip] = bb
        guard allowed, let message = try? RelayMessage(decoding: bytes) else { return }

        switch message {
        case let .register(key, rawLocal):
            // Only private addresses make sense as "the host's LAN"; anything else would have
            // players send hellos to strangers.
            let local = rawLocal.filter { $0.isLocalNetwork && !$0.isLoopback }
            if let code = roomByKey[key], var room = rooms[code] {
                room.host = from
                room.local = local
                room.lastSeen = now
                rooms[code] = room
                send(.registered(room: code, publicAddress: from), to: from)
                return
            }
            guard rooms.count < limits.maxRooms else { return send(.refused(reason: "server is full"), to: from) }
            guard rooms.values.filter({ $0.owner == ip }).count < limits.roomsPerSource else {
                return send(.refused(reason: "too many games from this address"), to: from)
            }
            var code = RoomCode.random(length: RelayMessage.roomLength)
            while rooms[code] != nil { code = RoomCode.random(length: RelayMessage.roomLength) }
            rooms[code] = Room(code: code, hostKey: key, owner: ip, host: from, local: local, lastSeen: now)
            roomByKey[key] = code
            log("room \(code) opened by \(from)")
            send(.registered(room: code, publicAddress: from), to: from)

        case let .unregister(key):
            if let code = roomByKey[key] { close(room: code) }

        case let .lookup(code):
            var lb = lookupBuckets[ip] ?? TokenBucket(rate: limits.lookupsPerMinute / 60, burst: limits.lookupsPerMinute / 3, now: now)
            let ok = lb.take(now: now)
            lookupBuckets[ip] = lb
            // Over the limit: drop silently. Answering would reflect traffic at spoofed sources.
            guard ok else { return }
            guard var room = rooms[code] else { return send(.notFound(room: code), to: from) }
            // Players repeat lookups while waiting; reuse (and refresh) their session.
            let key = "\(code)|\(from)"
            let session: UInt64
            if let existing = sessionByClient[key], sessions[existing] != nil {
                session = existing
                sessions[existing]?.lastSeen = now
            } else {
                let mine = room.sessions.filter { s in sessions[s].map { Self.sourceKey($0.client) == ip } ?? false }
                guard mine.count < limits.sessionsPerSourcePerRoom else { return }
                if room.sessions.count >= limits.maxSessionsPerRoom {
                    // Make room by reclaiming a session nobody ever relayed through.
                    let idle = room.sessions.compactMap { s in sessions[s].map { (s, $0) } }
                        .filter { !$0.1.active && now - $0.1.lastSeen > limits.idleSessionTimeout }
                        .min { $0.1.lastSeen < $1.1.lastSeen }
                    guard let (victim, _) = idle else { return send(.refused(reason: "room is busy"), to: from) }
                    dropSession(victim)
                    room = rooms[code] ?? room
                }
                var s = UInt64.random(in: 1...UInt64.max)
                while sessions[s] != nil { s = UInt64.random(in: 1...UInt64.max) }
                session = s
                sessions[s] = Session(room: code, client: from, lastSeen: now)
                sessionByClient[key] = s
                room.sessions.insert(s)
                rooms[code] = room
            }
            send(.peer(room: code, session: session, hostPublic: room.host, hostLocal: room.local), to: from)
            send(.intro(session: session, client: from), to: room.host)

        case let .relay(s, payload):
            guard var session = sessions[s], let room = rooms[session.room] else { return }
            session.lastSeen = now
            session.active = true
            sessions[s] = session
            if from == session.client {
                socket.send(RelayMessage.relay(session: s, payload: payload).encoded(), to: room.host)
            } else if from == room.host {
                socket.send(RelayMessage.relay(session: s, payload: payload).encoded(), to: session.client)
            } else {
                return
            }
            relayedBytes += payload.count

        case .registered, .peer, .notFound, .intro, .refused:
            break // Server-to-game messages; ignore if echoed at us.
        }
    }

    private func close(room code: String) {
        guard let room = rooms.removeValue(forKey: code) else { return }
        roomByKey[room.hostKey] = nil
        for s in room.sessions {
            if let session = sessions.removeValue(forKey: s) { sessionByClient["\(code)|\(session.client)"] = nil }
        }
        log("room \(code) closed")
    }

    private func dropSession(_ s: UInt64) {
        guard let session = sessions.removeValue(forKey: s) else { return }
        sessionByClient["\(session.room)|\(session.client)"] = nil
        rooms[session.room]?.sessions.remove(s)
    }

    private func sweep() {
        let now = monotonicSeconds()
        for (code, room) in rooms where now - room.lastSeen > limits.roomTimeout { close(room: code) }
        for (s, session) in sessions where now - session.lastSeen > limits.sessionTimeout { dropSession(s) }
        // Forget limiter state for sources that went quiet. (Evicting only stale entries, never
        // everything, so nobody can reset the limits by flooding the table.)
        packetBuckets = packetBuckets.filter { now - $0.value.last < 60 }
        byteBuckets = byteBuckets.filter { now - $0.value.last < 60 }
        lookupBuckets = lookupBuckets.filter { now - $0.value.last < 180 }
    }
}

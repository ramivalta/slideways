import CryptoKit
import Foundation
import SlicksCore
import SlicksLink

/// How packets reach a peer: straight to its address, or wrapped through the relay server.
public enum Route: Hashable, CustomStringConvertible, Sendable {
    case direct(SocketAddress)
    case relay(server: SocketAddress, session: UInt64)

    public var description: String {
        switch self {
        case let .direct(a): "\(a)"
        case let .relay(server, _): "relay \(server)"
        }
    }

    public var isRelayed: Bool {
        if case .relay = self { return true }
        return false
    }

    /// The peer's IP when known (relayed peers hide theirs behind the server).
    public var directAddress: SocketAddress? {
        if case let .direct(a) = self { return a }
        return nil
    }
}

/// Game packet types. Every game packet starts with "SW" and one of these.
enum PacketKind: UInt8 {
    /// Player to host, in the clear: my ephemeral key. Padded to `helloSize` so a spoofed
    /// hello can't make the host send back more than it received.
    case hello = 1
    /// Host to player, in the clear: the host's ephemeral key and the connection id.
    case challenge
    /// Encrypted frames.
    case data
    /// Host to player, in the clear: not letting you in (wrong code, full, wrong version).
    case refuse
    /// Host to player through the relay's introduction: opens the host's router toward them.
    case punch

    static let magic: [UInt8] = [0x53, 0x57]
    static let helloSize = 1200
    /// Largest datagram built (before relay wrapping), safe on nearly every path.
    static let maxDatagram = 1200
    /// magic + kind + connection id + packet number.
    static let dataHeader = 19
    static let tagSize = 16

    static func of(_ bytes: [UInt8]) -> PacketKind? {
        guard bytes.count >= 3, bytes[0] == magic[0], bytes[1] == magic[1] else { return nil }
        return PacketKind(rawValue: bytes[2])
    }
}

/// Session keys for one connection, one per direction.
struct SessionKeys {
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey

    /// Both sides derive the same keys from the key exchange. The join secret is mixed in, so a
    /// player with the wrong code ends up with different keys and the host can't read them.
    init(shared: SharedSecret, secret: String, clientPublic: [UInt8], hostPublic: [UInt8],
         clientNonce: [UInt8], hostNonce: [UInt8], connectionID: UInt64) {
        let salt = Data(SHA256.hash(data: Data("slideways/join/v2".utf8) + Data(secret.utf8)))
        var info = Data("slideways/keys".utf8)
        info += clientPublic + hostPublic + clientNonce + hostNonce
        withUnsafeBytes(of: connectionID.littleEndian) { info += $0 }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 64)
        let bytes = key.withUnsafeBytes { Array($0) }
        clientToHost = SymmetricKey(data: bytes[0..<32])
        hostToClient = SymmetricKey(data: bytes[32..<64])
    }
}

/// Which packet numbers have been seen, so replayed or duplicated packets are dropped.
struct ReplayWindow {
    private(set) var largest: UInt64 = 0
    private var seen: UInt64 = 0 // bit i: largest - 1 - i

    func isFresh(_ pn: UInt64) -> Bool {
        guard pn > 0 else { return false }
        if pn > largest { return true }
        let back = largest - pn
        return back > 0 && back <= 64 && seen & (1 << (back - 1)) == 0
    }

    mutating func mark(_ pn: UInt64) {
        if pn > largest {
            let shift = pn - largest
            seen = shift >= 64 ? 0 : (seen << shift) | (largest > 0 ? 1 << (shift - 1) : 0)
            largest = pn
        } else if pn < largest {
            seen |= 1 << (largest - pn - 1)
        }
    }

    /// For ack frames: `largest` and the 64 before it.
    var ackBits: (largest: UInt64, bits: UInt64) { (largest, seen) }
}

/// A reliable-when-needed message link over one encrypted UDP connection.
///
/// Reliable messages (lobby, setup, control) are fragmented, acknowledged and resent until
/// they arrive, in order. Unreliable ones (inputs, race state) are fragmented but never
/// resent: a newer one is always on its way. There's no head-of-line blocking between the two.
public final class Link {
    public let connectionID: UInt64
    public private(set) var route: Route
    public let isHostSide: Bool
    /// Smoothed round trip in seconds, from acknowledgements.
    public private(set) var rtt: Double?
    public private(set) var isClosed = false

    var onMessage: ((_ reliable: Bool, _ bytes: [UInt8]) -> Void)?
    var onClose: ((String) -> Void)?

    static let fragmentSize = 1100
    static let maxFragments = 2048
    static let reliableWindow = 512 * 1024
    static let maxBuffered = 8 << 20
    static let timeout = 8.0
    static let keepalive = 0.5

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let transmit: ([UInt8], Route) -> Void

    private struct Fragment {
        let id: UInt64
        let reliable: Bool
        let seq: UInt32
        let index: UInt16
        let count: UInt16
        let data: [UInt8]
        var wireSize: Int { 11 + data.count }
    }

    private struct Sent {
        let time: Double
        let fragments: [UInt64]
        /// Presumed lost and its fragments queued again. Kept a while: a late ack still gives
        /// a round-trip sample, which is how the estimate recovers when latency jumps.
        var lost = false
    }

    private struct Partial {
        let count: Int
        var parts: [Int: [UInt8]] = [:]
        var size = 0
    }

    // Sending.
    private var nextPacket: UInt64 = 1
    private var nextFragmentID: UInt64 = 1
    private var nextReliableSeq: UInt32 = 0
    private var nextUnreliableID: UInt32 = 0
    private var unreliableQueue: [Fragment] = []
    private var reliableQueue: [Fragment] = []
    private var retransmit: [UInt64] = []
    private var unacked: [UInt64: Fragment] = [:]
    private var unackedBytes = 0
    private var inFlight: [UInt64: Sent] = [:]
    private var largestAcked: UInt64 = 0
    private var rttVar = 0.0
    private var lastSend = 0.0

    // Receiving.
    private var window = ReplayWindow()
    private var ackPending = false
    private var ackPendingSince = 0.0
    private var lastHeard: Double
    private var nextDeliver: UInt32 = 0
    private var reliableParts: [UInt32: Partial] = [:]
    private var unreliableParts: [UInt32: Partial] = [:]
    private var buffered = 0

    init(connectionID: UInt64, route: Route, keys: SessionKeys, isHostSide: Bool,
         transmit: @escaping ([UInt8], Route) -> Void) {
        self.connectionID = connectionID
        self.route = route
        self.isHostSide = isHostSide
        sendKey = isHostSide ? keys.hostToClient : keys.clientToHost
        receiveKey = isHostSide ? keys.clientToHost : keys.hostToClient
        self.transmit = transmit
        lastHeard = monotonicNow()
    }

    // MARK: Sending

    public func send(_ bytes: [UInt8], reliable: Bool) {
        guard !isClosed else { return }
        let chunks = stride(from: 0, to: max(bytes.count, 1), by: Self.fragmentSize).map {
            Array(bytes[$0..<min($0 + Self.fragmentSize, bytes.count)])
        }
        guard chunks.count <= Self.maxFragments else { return fail("message too large to send") }
        let seq: UInt32
        if reliable {
            seq = nextReliableSeq
            nextReliableSeq &+= 1
        } else {
            seq = nextUnreliableID
            nextUnreliableID &+= 1
        }
        for (i, c) in chunks.enumerated() {
            let f = Fragment(id: nextFragmentID, reliable: reliable, seq: seq, index: UInt16(i), count: UInt16(chunks.count), data: c)
            nextFragmentID += 1
            if reliable { reliableQueue.append(f) } else { unreliableQueue.append(f) }
        }
        flush(now: monotonicNow())
    }

    /// Tells the peer why we're leaving (a few times, since nothing will resend it) and stops.
    public func close(reason: String) {
        guard !isClosed else { return }
        var w = ByteWriter()
        w.u8(Frame.close.rawValue)
        w.string(String(reason.prefix(200)))
        for _ in 0..<3 { sendPacket(frames: w.bytes, fragments: [], ackEliciting: false, now: monotonicNow()) }
        isClosed = true
    }

    private enum Frame: UInt8 {
        /// `probe` asks for an ack and carries nothing else: a player sends it right after the
        /// handshake, and the host's encrypted ack proves the host derived the same keys.
        case ack = 1, reliable, unreliable, close, probe
    }

    /// Something from the peer decrypted: it has the same keys, so it's who we think it is.
    public private(set) var hasHeardFromPeer = false

    /// Asks the peer to prove it can read us (see `Frame.probe`).
    func probe() {
        guard !isClosed else { return }
        sendPacket(frames: ackFrame() + [Frame.probe.rawValue], fragments: [], ackEliciting: true, now: monotonicNow())
    }

    private var maxPlaintext: Int { PacketKind.maxDatagram - PacketKind.dataHeader - PacketKind.tagSize }

    private func ackFrame() -> [UInt8] {
        guard window.largest > 0 else { return [] }
        var w = ByteWriter(capacity: 17)
        let bits = window.ackBits
        w.u8(Frame.ack.rawValue)
        w.u64(bits.largest)
        w.u64(bits.bits)
        return w.bytes
    }

    private func append(_ f: Fragment, to w: inout ByteWriter) {
        w.u8(f.reliable ? Frame.reliable.rawValue : Frame.unreliable.rawValue)
        w.u32(f.seq)
        w.u16(f.index)
        w.u16(f.count)
        w.u16(UInt16(f.data.count))
        w.raw(f.data)
    }

    /// Sends everything that's waiting, packing frames into as few packets as fit.
    func flush(now: Double) {
        guard !isClosed else { return }
        while true {
            var w = ByteWriter(capacity: PacketKind.maxDatagram)
            w.raw(ackFrame())
            let ackOnly = w.count
            var fragments: [UInt64] = []
            // Latest inputs and race state first: they matter most for how the race feels.
            while let f = unreliableQueue.first, w.count + f.wireSize <= maxPlaintext {
                append(f, to: &w)
                unreliableQueue.removeFirst()
            }
            while let id = retransmit.first, w.count + (unacked[id]?.wireSize ?? 0) <= maxPlaintext {
                retransmit.removeFirst()
                guard let f = unacked[id] else { continue }
                append(f, to: &w)
                fragments.append(id)
            }
            while let f = reliableQueue.first, unackedBytes + f.data.count <= Self.reliableWindow,
                  w.count + f.wireSize <= maxPlaintext {
                reliableQueue.removeFirst()
                append(f, to: &w)
                unacked[f.id] = f
                unackedBytes += f.data.count
                fragments.append(f.id)
            }
            let hasPayload = w.count > ackOnly
            if !hasPayload {
                // Nothing but an ack: send it if the peer is waiting for one or we've been quiet.
                // (Keepalives keep routers' mappings open; they aren't acked, so acks can't ping-pong.)
                if (ackPending && now - ackPendingSince >= 0.005) || now - lastSend >= Self.keepalive {
                    sendPacket(frames: w.bytes, fragments: [], ackEliciting: false, now: now)
                }
                return
            }
            sendPacket(frames: w.bytes, fragments: fragments, ackEliciting: true, now: now)
            if unreliableQueue.isEmpty && retransmit.isEmpty
                && (reliableQueue.isEmpty || unackedBytes + (reliableQueue.first?.data.count ?? 0) > Self.reliableWindow) {
                return
            }
        }
    }

    private func sendPacket(frames: [UInt8], fragments: [UInt64], ackEliciting: Bool, now: Double) {
        let pn = nextPacket
        nextPacket += 1
        var header = ByteWriter(capacity: PacketKind.dataHeader)
        header.raw(PacketKind.magic)
        header.u8(PacketKind.data.rawValue)
        header.u64(connectionID)
        header.u64(pn)
        guard let sealed = try? ChaChaPoly.seal(frames, using: sendKey, nonce: Self.nonce(pn), authenticating: header.bytes) else { return }
        transmit(header.bytes + sealed.ciphertext + sealed.tag, route)
        if ackEliciting || !fragments.isEmpty {
            inFlight[pn] = Sent(time: now, fragments: fragments)
        }
        ackPending = false
        lastSend = now
    }

    static func nonce(_ pn: UInt64) -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: pn.littleEndian) { for (i, b) in $0.enumerated() { n[4 + i] = b } }
        return try! ChaChaPoly.Nonce(data: n)
    }

    // MARK: Receiving

    /// Decrypts and handles a data packet. Returns false if it wasn't genuine (wrong key,
    /// tampered, or a replay), in which case nothing changed.
    @discardableResult
    func receive(_ packet: [UInt8], from: Route) -> Bool {
        guard !isClosed, packet.count >= PacketKind.dataHeader + PacketKind.tagSize else { return false }
        var r = ByteReader(slice: packet[3..<PacketKind.dataHeader])
        guard (try? r.u64()) == connectionID, let pn = try? r.u64(), window.isFresh(pn) else { return false }
        let header = Array(packet[0..<PacketKind.dataHeader])
        let body = packet[PacketKind.dataHeader..<(packet.count - PacketKind.tagSize)]
        let tag = packet[(packet.count - PacketKind.tagSize)...]
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(pn), ciphertext: body, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: receiveKey, authenticating: header) else { return false }
        let isNewest = pn > window.largest
        window.mark(pn)
        let now = monotonicNow()
        lastHeard = now
        hasHeardFromPeer = true
        // Authenticated traffic from a new address: the peer's router remapped it, or we
        // switched between direct and relayed. Follow it, but only for the newest packet, so a
        // captured copy that arrives first (or a late straggler) can't pull traffic elsewhere.
        if from != route, isNewest { route = from }
        var elicits = false
        var reader = ByteReader(plain)
        do {
            while !reader.isAtEnd {
                guard let kind = Frame(rawValue: try reader.u8()) else { throw WireError.invalid("frame") }
                switch kind {
                case .ack:
                    handleAck(largest: try reader.u64(), bits: try reader.u64(), now: now)
                case .reliable, .unreliable:
                    elicits = true
                    let seq = try reader.u32(), index = Int(try reader.u16()), count = Int(try reader.u16())
                    let data = try reader.raw(Int(try reader.u16()))
                    guard count >= 1, count <= Self.maxFragments, index < count else { throw WireError.invalid("fragment") }
                    if kind == .reliable {
                        receiveReliable(seq: seq, index: index, count: count, data: data)
                    } else {
                        receiveUnreliable(id: seq, index: index, count: count, data: data)
                    }
                    if isClosed { return true }
                case .close:
                    let reason = (try? reader.string()) ?? "disconnected"
                    isClosed = true
                    onClose?(reason)
                    return true
                case .probe:
                    elicits = true
                }
            }
        } catch {
            fail("peer sent a malformed packet")
            return true
        }
        if elicits {
            if !ackPending { ackPendingSince = now }
            ackPending = true
        }
        return true
    }

    /// Whether a data packet decrypts with this link's keys, without acting on it.
    func canOpen(_ packet: [UInt8]) -> Bool {
        guard packet.count >= PacketKind.dataHeader + PacketKind.tagSize else { return false }
        var r = ByteReader(slice: packet[3..<PacketKind.dataHeader])
        guard (try? r.u64()) == connectionID, let pn = try? r.u64() else { return false }
        let header = Array(packet[0..<PacketKind.dataHeader])
        guard let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(pn), ciphertext: packet[PacketKind.dataHeader..<(packet.count - PacketKind.tagSize)],
                                                  tag: packet[(packet.count - PacketKind.tagSize)...]) else { return false }
        return (try? ChaChaPoly.open(box, using: receiveKey, authenticating: header)) != nil
    }

    private func handleAck(largest: UInt64, bits: UInt64, now: Double) {
        guard largest < nextPacket else { return }
        var acked = [largest]
        for i in 0..<64 where bits & (1 << UInt64(i)) != 0 && largest > UInt64(i) + 1 {
            acked.append(largest - UInt64(i) - 1)
        }
        for pn in acked {
            guard let sent = inFlight.removeValue(forKey: pn) else { continue }
            if pn == largest {
                let sample = now - sent.time
                if let r = rtt {
                    rttVar = 0.75 * rttVar + 0.25 * abs(r - sample)
                    rtt = 0.875 * r + 0.125 * sample
                } else {
                    rtt = sample
                    rttVar = sample / 2
                }
            }
            for id in sent.fragments {
                if let f = unacked.removeValue(forKey: id) { unackedBytes -= f.data.count }
            }
        }
        largestAcked = max(largestAcked, largest)
    }

    private func receiveReliable(seq: UInt32, index: Int, count: Int, data: [UInt8]) {
        // Behind us (a resend of something delivered) wraps to a huge distance. Anything ahead
        // is kept, however far: dropping it after acking would stall the stream for good, and
        // `maxBuffered` bounds the memory instead.
        let ahead = seq &- nextDeliver
        guard ahead < 1 << 30 else { return }
        var p = reliableParts[seq] ?? Partial(count: count)
        guard p.count == count, p.parts[index] == nil else { return }
        p.parts[index] = data
        p.size += data.count
        buffered += data.count
        guard buffered <= Self.maxBuffered else { return fail("peer sent too much data") }
        reliableParts[seq] = p
        while let next = reliableParts[nextDeliver], next.parts.count == next.count {
            reliableParts[nextDeliver] = nil
            buffered -= next.size
            nextDeliver &+= 1
            onMessage?(true, (0..<next.count).flatMap { next.parts[$0]! })
            if isClosed { return }
        }
    }

    /// Unreliable messages are "newest wins": one that arrives after a later one is dropped,
    /// so reordering can't make race state or inputs jump backwards.
    private var lastUnreliable: UInt32?

    private func deliverUnreliable(_ id: UInt32, _ data: [UInt8]) {
        if let last = lastUnreliable, Int32(bitPattern: id &- last) <= 0 { return }
        lastUnreliable = id
        onMessage?(false, data)
    }

    /// Bytes held in incomplete unreliable messages; they're disposable, so the cap is small.
    private var unreliableBuffered = 0
    static let maxUnreliableBuffered = 256 * 1024

    private func receiveUnreliable(id: UInt32, index: Int, count: Int, data: [UInt8]) {
        // Older than something already delivered: it would be dropped anyway.
        if let last = lastUnreliable, Int32(bitPattern: id &- last) <= 0 { return }
        if count == 1 { return deliverUnreliable(id, data) }
        var p = unreliableParts[id] ?? Partial(count: count)
        guard p.count == count, p.parts[index] == nil else { return }
        p.parts[index] = data
        p.size += data.count
        unreliableBuffered += data.count
        if p.parts.count == count {
            unreliableParts[id] = nil
            unreliableBuffered -= p.size
            deliverUnreliable(id, (0..<count).flatMap { p.parts[$0]! })
            // Anything older can't be delivered any more.
            for (k, old) in unreliableParts where Int32(bitPattern: k &- id) <= 0 {
                unreliableParts[k] = nil
                unreliableBuffered -= old.size
            }
            return
        }
        unreliableParts[id] = p
        // Only the last few partial messages are worth finishing: evict the oldest.
        while unreliableParts.count > 8 || unreliableBuffered > Self.maxUnreliableBuffered,
              let oldest = unreliableParts.keys.max(by: { (id &- $0) < (id &- $1) }) {
            unreliableBuffered -= unreliableParts[oldest]?.size ?? 0
            unreliableParts[oldest] = nil
        }
    }

    // MARK: Timers

    private var rto: Double {
        guard let rtt else { return 0.3 }
        return min(2, max(0.05, rtt + 4 * rttVar + 0.01))
    }

    /// Resends lost reliable fragments, sends due acks and keepalives, and notices silence.
    func tick(now: Double) {
        guard !isClosed else { return }
        if now - lastHeard > Self.timeout { return fail("connection timed out") }
        let limit = rto
        var lost: [UInt64] = []
        var expired: [UInt64] = []
        for (pn, sent) in inFlight {
            if now - sent.time > 5 {
                expired.append(pn)
            } else if !sent.lost, now - sent.time > limit || pn + 3 <= largestAcked {
                lost.append(pn)
            }
        }
        for pn in expired { inFlight[pn] = nil }
        for pn in lost.sorted() {
            inFlight[pn]?.lost = true
            for id in inFlight[pn]?.fragments ?? [] where unacked[id] != nil && !retransmit.contains(id) { retransmit.append(id) }
        }
        flush(now: now)
    }

    private func fail(_ reason: String) {
        guard !isClosed else { return }
        close(reason: reason)
        onClose?(reason)
    }
}

func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

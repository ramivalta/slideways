import dnssd
import Foundation
import Network
import SlicksLink

/// Lists a hosted game on the local network. The TXT record carries what a player needs to
/// connect straight away (addresses, port, room, whether a code is needed), so there's no
/// separate resolve step.
final class BonjourAdvertiser {
    private var ref: DNSServiceRef?
    private let name: String
    private let port: UInt16

    init(name: String, port: UInt16, txt: [String: String]) {
        self.name = name
        self.port = port
        register(txt: txt)
    }

    deinit { stop() }

    func update(txt: [String: String]) {
        guard let ref else { return register(txt: txt) }
        let record = Self.encode(txt)
        _ = record.withUnsafeBytes { DNSServiceUpdateRecord(ref, nil, 0, UInt16(record.count), $0.baseAddress, 0) }
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    private func register(txt: [String: String]) {
        let record = Self.encode(txt)
        var r: DNSServiceRef?
        let err = record.withUnsafeBytes { buf in
            DNSServiceRegister(&r, 0, 0, name, NetProtocol.bonjourType, nil, nil, port.bigEndian,
                               UInt16(record.count), buf.baseAddress, nil, nil)
        }
        guard err == kDNSServiceErr_NoError, let r else { return }
        DNSServiceSetDispatchQueue(r, .main)
        ref = r
    }

    /// Length-prefixed "key=value" strings, as DNS-SD expects.
    static func encode(_ txt: [String: String]) -> [UInt8] {
        var out: [UInt8] = []
        for (k, v) in txt.sorted(by: { $0.key < $1.key }) {
            let entry = Array("\(k)=\(v)".utf8.prefix(255))
            out.append(UInt8(entry.count))
            out += entry
        }
        return out.isEmpty ? [0] : out
    }
}

/// Games hosted on the local network, found over Bonjour.
public final class HostBrowser {
    public struct Found: Equatable {
        public var name: String
        public var room: String
        public var needsCode: Bool
        public var version: Int
        public var addresses: [SocketAddress]

        public var isCompatible: Bool { version == Int(NetProtocol.version) }
    }

    public private(set) var hosts: [Found] = []
    public var onChange: (() -> Void)?
    public private(set) var error: String?
    private var browser: NWBrowser?

    public init() {}

    deinit { browser?.cancel() }

    /// The nearby game with this room code, if any.
    public func host(room: String) -> Found? { hosts.first { $0.room == room } }

    public func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NetProtocol.bonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.hosts = results.compactMap(Self.parse).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.onChange?()
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(e), let .waiting(e):
                self?.error = "can't search for games (\(e))"
                self?.onChange?()
            case .ready:
                self?.error = nil
            default:
                break
            }
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    static func parse(_ r: NWBrowser.Result) -> Found? {
        guard case let .service(name, _, _, _) = r.endpoint, case let .bonjour(txt) = r.metadata else { return nil }
        let d = txt.dictionary
        guard let port = d["port"].flatMap(UInt16.init), port != 0, let room = d["room"] else { return nil }
        let addresses = (d["ip"] ?? "").split(separator: ",").compactMap { SocketAddress(numeric: String($0), port: port) }
        guard !addresses.isEmpty else { return nil }
        return Found(name: name, room: room, needsCode: d["code"] != "0", version: Int(d["v"] ?? "") ?? 0, addresses: addresses)
    }
}

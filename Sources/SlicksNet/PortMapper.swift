import Foundation
import SlicksLink
#if os(macOS)
import SystemConfiguration
#endif

/// Asks the home router to forward the game's UDP port, so players on the internet can reach
/// the host without anyone configuring port forwarding. Tries NAT-PMP, then UPnP IGD. The
/// mapping is renewed while hosting and removed when hosting stops.
public final class PortMapper {
    public enum State: Equatable {
        case off
        case trying
        /// Players can reach the host at `external`.
        case mapped(external: SocketAddress, method: String)
        case unavailable(String)
    }

    public private(set) var state = State.off {
        didSet { if state != oldValue { onChange?() } }
    }
    public var onChange: (() -> Void)?
    public let internalPort: UInt16

    /// Where to find the router. `.system` asks the OS for the default gateway and discovers
    /// UPnP devices by multicast; tests point these at fakes.
    public struct Discovery {
        public var natpmpGateway: SocketAddress?
        public var upnpDescription: URL?
        public var useSystem: Bool

        public static let system = Discovery(natpmpGateway: nil, upnpDescription: nil, useSystem: true)

        public init(natpmpGateway: SocketAddress?, upnpDescription: URL?, useSystem: Bool = false) {
            self.natpmpGateway = natpmpGateway
            self.upnpDescription = upnpDescription
            self.useSystem = useSystem
        }
    }

    private let discovery: Discovery

    static let lease: UInt32 = 3600

    private var natpmpSocket: UDPSocket?
    private var natpmpGateway: SocketAddress?
    private var natpmpMapped = false
    private var ssdpSocket: UDPSocket?
    private var upnp: (control: URL, service: String, externalPort: UInt16)?
    private var renewTimer: DispatchSourceTimer?
    private var stopped = false
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 5
        return URLSession(configuration: c)
    }()

    public init(internalPort: UInt16, discovery: Discovery = .system) {
        self.internalPort = internalPort
        self.discovery = discovery
    }

    deinit { stop() }

    /// The public address players can use, once mapped.
    public var externalAddress: SocketAddress? {
        if case let .mapped(a, _) = state { return a }
        return nil
    }

    public func start() {
        state = .trying
        if let gw = discovery.useSystem ? Self.defaultGateway() : discovery.natpmpGateway {
            natpmp(gateway: gw)
        } else {
            upnpDiscover()
        }
    }

    /// Removes the mapping. With `wait`, blocks briefly so it's gone before the app quits.
    public func stop(wait: Bool = false) {
        guard !stopped else { return }
        stopped = true
        renewTimer?.cancel()
        // Delete whatever the router made, even if it turned out useless (double NAT).
        if natpmpMapped, let gw = natpmpGateway, let s = natpmpSocket {
            s.sendNow(Self.natpmpMapRequest(internal: internalPort, external: 0, lifetime: 0), to: gw)
        }
        if let u = upnp {
            let done = DispatchSemaphore(value: 0)
            // Signalled from URLSession's own queue: waiting here blocks main.
            soap(u.control, u.service, "DeletePortMapping", [
                ("NewRemoteHost", ""), ("NewExternalPort", "\(u.externalPort)"), ("NewProtocol", "UDP"),
            ], onMain: false) { _ in done.signal() }
            if wait { _ = done.wait(timeout: .now() + 1) }
        }
        let s = natpmpSocket
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { s?.close() }
        ssdpSocket?.close()
        state = .off
    }

    /// What sending to the router fails with when macOS hasn't let the app onto the local network.
    static func isBlocked(_ error: Int32) -> Bool { error == EHOSTUNREACH || error == EPERM || error == EACCES }
    static let blockedMessage = "macOS blocked local network access; allow Slideways in System Settings > Privacy & Security > Local Network"

    // MARK: NAT-PMP (RFC 6886)

    /// NAT-PMP is big-endian. Lifetime 0 deletes the mapping.
    static func natpmpMapRequest(internal inPort: UInt16, external exPort: UInt16, lifetime: UInt32) -> [UInt8] {
        [0, 1, 0, 0, UInt8(inPort >> 8), UInt8(inPort & 0xFF), UInt8(exPort >> 8), UInt8(exPort & 0xFF),
         UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xFF), UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF)]
    }

    private func natpmp(gateway: SocketAddress) {
        guard let s = try? UDPSocket(port: 0, ipv4Only: true, queue: .main, conditions: .none) else { return upnpDiscover() }
        natpmpSocket = s
        // The system gateway is always asked on the NAT-PMP port; a test fake keeps its own.
        let gw = discovery.useSystem ? gateway.with(port: 5351) : gateway
        natpmpGateway = gw
        var publicIP: [UInt8]?
        var mappedPort: UInt16?
        var lifetime: UInt32 = Self.lease
        s.onReceive = { [weak self] bytes, from in
            guard let self, !self.stopped, from.ip == gw.ip, bytes.count >= 8, bytes[0] == 0 else { return }
            let result = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            guard result == 0 else {
                self.natpmpSocket = nil
                s.close()
                return self.upnpDiscover()
            }
            if bytes[1] == 128, bytes.count >= 12 {
                publicIP = Array(bytes[8..<12])
            } else if bytes[1] == 129, bytes.count >= 16 {
                self.natpmpMapped = true
                mappedPort = UInt16(bytes[10]) << 8 | UInt16(bytes[11])
                lifetime = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            }
            if let ip = publicIP, let port = mappedPort {
                self.mapped(ip: ip, port: port, method: "NAT-PMP")
                self.scheduleRenew(after: Double(max(lifetime, 120)) / 2) { [weak self] in
                    guard let self else { return }
                    s.send(Self.natpmpMapRequest(internal: self.internalPort, external: port, lifetime: Self.lease), to: gw)
                }
            }
        }
        // Retry with backoff like the RFC suggests (shortened: routers answer fast or never).
        for (k, delay) in [0.0, 0.25, 0.75, 1.75].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.stopped, self.natpmpSocket === s, mappedPort == nil || publicIP == nil else { return }
                if publicIP == nil, Self.isBlocked(s.sendNow([0, 0], to: gw)) {
                    self.natpmpSocket = nil
                    s.close()
                    self.state = .unavailable(Self.blockedMessage)
                    return
                }
                if mappedPort == nil {
                    s.send(Self.natpmpMapRequest(internal: self.internalPort, external: self.internalPort, lifetime: Self.lease), to: gw)
                }
                if k == 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, !self.stopped, self.natpmpSocket === s, mappedPort == nil || publicIP == nil else { return }
                        self.natpmpSocket = nil
                        s.close()
                        self.upnpDiscover()
                    }
                }
            }
        }
    }

    private func mapped(ip: [UInt8], port: UInt16, method: String) {
        let external = SocketAddress(ip: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + ip, port: port)
        if external.isLocalNetwork {
            // The router itself sits behind another one (or the ISP's CGNAT): a mapping here
            // doesn't make us reachable from the internet.
            state = .unavailable("the router is behind another network (\(external.host)), so it can't open a port")
        } else {
            state = .mapped(external: external, method: method)
        }
    }

    private func scheduleRenew(after seconds: Double, _ renew: @escaping () -> Void) {
        renewTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: renew)
        t.resume()
        renewTimer = t
    }

    static func defaultGateway() -> SocketAddress? {
        #if os(macOS)
        guard let dict = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = dict["Router"] as? String else { return nil }
        return SocketAddress(numeric: router, port: 5351)
        #else
        return nil
        #endif
    }

    // MARK: UPnP IGD

    private func upnpDiscover() {
        guard !stopped else { return }
        if !discovery.useSystem {
            guard let url = discovery.upnpDescription else {
                state = .unavailable("the router didn't answer (no NAT-PMP or UPnP)")
                return
            }
            fetchDescription(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !self.stopped, self.upnp == nil, case .trying = self.state else { return }
                self.state = .unavailable("the router didn't answer (no NAT-PMP or UPnP)")
            }
            return
        }
        guard let s = try? UDPSocket(port: 0, ipv4Only: true, queue: .main, conditions: .none),
              let group = SocketAddress(numeric: "239.255.255.250", port: 1900) else {
            state = .unavailable("the router didn't answer (no NAT-PMP or UPnP)")
            return
        }
        ssdpSocket = s
        var locations: Set<String> = []
        s.onReceive = { [weak self] bytes, _ in
            guard let self, !self.stopped, let text = String(bytes: bytes, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
                let loc = parts[1].trimmingCharacters(in: .whitespaces)
                if locations.insert(loc).inserted, let url = URL(string: loc) { self.fetchDescription(url) }
            }
        }
        let targets = ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
                       "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"]
        func search(_ st: String) -> Int32 {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
            return s.sendNow(Array(msg.utf8), to: group)
        }
        if Self.isBlocked(search(targets[0])) {
            s.close()
            state = .unavailable(Self.blockedMessage)
            return
        }
        for (k, st) in (targets + targets).enumerated().dropFirst() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k / targets.count) * 0.8) { _ = search(st) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.stopped, self.upnp == nil, case .trying = self.state else { return }
            s.close()
            self.state = .unavailable("the router didn't answer (no NAT-PMP or UPnP)")
        }
    }

    private func fetchDescription(_ url: URL) {
        // Only the router itself gets to say how to open ports: any device on the network can
        // answer discovery, and a stray one shouldn't decide what we show as our address.
        guard url.scheme == "http" else { return }
        if discovery.useSystem, let gw = Self.defaultGateway()?.host, url.host != gw { return }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let services = UPnPDescription.parse(data, base: url) else { return }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.upnp == nil,
                      let service = services.first(where: { $0.type.contains("WANIPConnection") }) ?? services.first(where: { $0.type.contains("WANPPPConnection") })
                else { return }
                self.addMapping(control: service.control, service: service.type, host: url.host ?? "", attempt: 0, lease: Self.lease)
            }
        }.resume()
    }

    private func addMapping(control: URL, service: String, host: String, attempt: Int, lease: UInt32) {
        guard let localIP = Self.localIP(towards: host) else { return }
        let external = internalPort &+ UInt16(attempt)
        soap(control, service, "AddPortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", "\(external)"), ("NewProtocol", "UDP"),
            ("NewInternalPort", "\(internalPort)"), ("NewInternalClient", localIP), ("NewEnabled", "1"),
            ("NewPortMappingDescription", "Slideways"), ("NewLeaseDuration", "\(lease)"),
        ]) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success:
                self.upnp = (control, service, external)
                // Found the router; stop listening to other devices' discovery replies.
                self.ssdpSocket?.close()
                self.ssdpSocket = nil
                self.soap(control, service, "GetExternalIPAddress", []) { [weak self] r in
                    guard let self, !self.stopped else { return }
                    if case let .success(body) = r, let ip = UPnPDescription.value("NewExternalIPAddress", in: body),
                       let a = SocketAddress(numeric: ip, port: external), a.isIPv4 {
                        self.mapped(ip: Array(a.ip[12...]), port: external, method: "UPnP")
                    } else {
                        self.state = .unavailable("the router opened a port but didn't say its public address")
                    }
                }
                if lease > 0 {
                    self.scheduleRenew(after: Double(lease) / 2) { [weak self] in
                        self?.addMapping(control: control, service: service, host: host, attempt: attempt, lease: lease)
                    }
                }
            case let .failure(error):
                let code = error.code
                if code == 725, lease != 0 {
                    // Only permanent mappings allowed; stop() removes it.
                    self.addMapping(control: control, service: service, host: host, attempt: attempt, lease: 0)
                } else if code == 718, attempt < 5 {
                    // That external port is taken by another mapping: try the next one.
                    self.addMapping(control: control, service: service, host: host, attempt: attempt + 1, lease: lease)
                } else {
                    self.state = .unavailable("the router refused to open a port (UPnP error \(code))")
                }
            }
        }
    }

    /// Our IPv4 address on the router's subnet (same first three octets), or the first one.
    static func localIP(towards host: String) -> String? {
        if host == "127.0.0.1" || host == "localhost" { return "127.0.0.1" }
        let mine = SocketAddress.localAddresses(port: 0).filter(\.isIPv4).map(\.host)
        let prefix = host.split(separator: ".").prefix(3).joined(separator: ".") + "."
        return mine.first { $0.hasPrefix(prefix) } ?? mine.first
    }

    /// - Parameter onMain: deliver `completion` on the main queue (otherwise on URLSession's).
    private func soap(_ control: URL, _ service: String, _ action: String, _ args: [(String, String)],
                      onMain: Bool = true, completion: @escaping (Result<String, SOAPError>) -> Void) {
        var req = URLRequest(url: control)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let body = args.map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        req.httpBody = Data("""
        <?xml version="1.0"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        session.dataTask(with: req) { data, response, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let code = UPnPDescription.value("errorCode", in: text).flatMap(Int.init) ?? -1
            let result: Result<String, SOAPError> = ok ? .success(text) : .failure(SOAPError(code: code))
            if onMain { DispatchQueue.main.async { completion(result) } } else { completion(result) }
        }.resume()
    }

    struct SOAPError: Error, Equatable {
        /// UPnP error code from the fault, or -1.
        let code: Int
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Just enough of a UPnP device description to find the WAN connection's control URL.
enum UPnPDescription {
    struct Service {
        let type: String
        let control: URL
    }

    static func parse(_ data: Data, base: URL) -> [Service]? {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse() else { return nil }
        let root = d.urlBase.flatMap(URL.init(string:)) ?? base
        return d.services.compactMap { type, control in
            URL(string: control, relativeTo: root).map { Service(type: type, control: $0.absoluteURL) }
        }
    }

    /// Text of the first `<name>` element (namespace prefixes ignored) in a SOAP body.
    static func value(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "<([A-Za-z0-9]+:)?\(name)>([^<]*)</", options: .regularExpression) else { return nil }
        let match = String(xml[r])
        guard let open = match.firstIndex(of: ">") else { return nil }
        return String(match[match.index(after: open)...].dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var services: [(String, String)] = []
        var urlBase: String?
        private var text = ""
        private var type: String?
        private var control: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "service" { type = nil; control = nil }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "serviceType": type = t
            case "controlURL": control = t
            case "URLBase": urlBase = t
            case "service":
                if let type, let control { services.append((type, control)) }
            default: break
            }
        }
    }
}

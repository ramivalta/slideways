import Foundation
import Network
import SlicksLink
import SlicksNet

@discardableResult
private func wait(_ timeout: Double, until done: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while !done() {
        if Date() > end { return false }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    return true
}

/// Answers NAT-PMP like a home router would, with a chosen public address.
private final class FakeNATPMP {
    let socket: UDPSocket
    var publicIP: [UInt8]
    var mappings: [(internal: UInt16, external: UInt16, lifetime: UInt32)] = []

    init(publicIP: [UInt8]) throws {
        self.publicIP = publicIP
        socket = try UDPSocket(port: 0, ipv4Only: true, conditions: .none)
        socket.onReceive = { [unowned self] b, from in
            let epoch: [UInt8] = [0, 0, 1, 0]
            if b == [0, 0] {
                socket.send([0, 128, 0, 0] + epoch + publicIP, to: from)
            } else if b.count == 12, b[0] == 0, b[1] == 1 {
                let inPort = UInt16(b[4]) << 8 | UInt16(b[5])
                let exPort = UInt16(b[6]) << 8 | UInt16(b[7])
                let life = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
                mappings.append((inPort, exPort, life))
                socket.send([0, 129, 0, 0] + epoch + Array(b[4..<12]), to: from)
            }
        }
    }

    var address: SocketAddress { SocketAddress(numeric: "127.0.0.1", port: socket.port)! }
}

/// A UPnP internet gateway device over plain HTTP: device description plus SOAP control.
private final class FakeUPnP {
    let listener: NWListener
    var port: UInt16 = 0
    var actions: [(action: String, body: String)] = []
    /// Answer the first AddPortMapping with "conflict" (718), like a port someone else mapped.
    var conflictOnce = true

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [unowned self] c in serve(c) }
        listener.stateUpdateHandler = { [unowned self] s in if case .ready = s { port = listener.port?.rawValue ?? 0 } }
        listener.start(queue: .main)
    }

    var descriptionURL: URL { URL(string: "http://127.0.0.1:\(port)/rootDesc.xml")! }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        var buffer = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [unowned self] data, _, done, _ in
                if let data { buffer += data }
                guard let text = String(data: buffer, encoding: .utf8), let split = text.range(of: "\r\n\r\n") else {
                    return done ? c.cancel() : read()
                }
                let head = String(text[..<split.lowerBound])
                // (Split on isNewline: "\r\n" is a single Character in Swift.)
                let length = head.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("content-length") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = String(text[split.upperBound...])
                guard body.utf8.count >= length else { return read() }
                respond(c, head: head, body: body)
            }
        }
        read()
    }

    private func respond(_ c: NWConnection, head: String, body: String) {
        var status = "200 OK"
        var reply: String
        if head.hasPrefix("GET") {
            reply = """
            <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>\
            <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><deviceList><device><deviceList><device>\
            <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>\
            <controlURL>/ctl/IPConn</controlURL></service></serviceList></device></deviceList></device></deviceList></device></root>
            """
        } else {
            let action = head.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("soapaction") }
                .flatMap { $0.split(separator: "#").last }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\r ")) } ?? ""
            actions.append((action, body))
            switch action {
            case "AddPortMapping" where conflictOnce:
                conflictOnce = false
                status = "500 Internal Server Error"
                reply = "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>718</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
            case "GetExternalIPAddress":
                reply = "<s:Envelope><s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress>198.51.100.9</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>"
            default:
                reply = "<s:Envelope><s:Body><u:\(action)Response/></s:Body></s:Envelope>"
            }
        }
        let bytes = Data(reply.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/xml\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Router port mapping against fake routers (the real one is only asked when hosting for real).
func portMapperChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    print("== Router port mapping (fake routers)")

    // NAT-PMP: mapped, then removed on stop.
    do {
        let router = try! FakeNATPMP(publicIP: [203, 0, 113, 7])
        let m = PortMapper(internalPort: 47999, discovery: .init(natpmpGateway: router.address, upnpDescription: nil))
        m.start()
        check(wait(3) { m.externalAddress != nil }, "NAT-PMP mapping failed: \(m.state)")
        check(m.externalAddress?.description == "203.0.113.7:47999", "NAT-PMP external address \(m.externalAddress.map { "\($0)" } ?? "-")")
        m.stop()
        check(wait(1) { router.mappings.contains { $0.lifetime == 0 } }, "NAT-PMP mapping not removed on stop")
    }
    // NAT-PMP behind another NAT: the router's "public" address is private, so it's no use.
    do {
        let router = try! FakeNATPMP(publicIP: [10, 1, 2, 3])
        let m = PortMapper(internalPort: 47998, discovery: .init(natpmpGateway: router.address, upnpDescription: nil))
        m.start()
        check(wait(3) { if case .unavailable = m.state { return true }; return false }, "double NAT not detected: \(m.state)")
        m.stop()
    }
    // UPnP: first port is taken, the next one works; removed on stop.
    do {
        let router = try! FakeUPnP()
        wait(2) { router.port != 0 }
        let m = PortMapper(internalPort: 47997, discovery: .init(natpmpGateway: nil, upnpDescription: router.descriptionURL))
        m.start()
        check(wait(5) { m.externalAddress != nil }, "UPnP mapping failed: \(m.state)")
        if m.externalAddress == nil { for a in router.actions { print("    fake got \(a.action): \(a.body.prefix(300))") } }
        check(m.externalAddress?.description == "198.51.100.9:47998", "UPnP didn't move past the taken port: \(m.externalAddress.map { "\($0)" } ?? "-")")
        let add = router.actions.last { $0.action == "AddPortMapping" }?.body ?? ""
        check(add.contains("<NewProtocol>UDP</NewProtocol>") && add.contains("<NewInternalClient>127.0.0.1</NewInternalClient>"),
              "UPnP request malformed")
        m.stop(wait: true)
        check(wait(2) { router.actions.contains { $0.action == "DeletePortMapping" && $0.body.contains("47998") } },
              "UPnP mapping not removed on stop")
    }
    // Nobody answers: give up with a reason instead of hanging.
    do {
        let silent = try! UDPSocket(port: 0, ipv4Only: true, conditions: .none)
        let m = PortMapper(internalPort: 47996, discovery: .init(natpmpGateway: SocketAddress(numeric: "127.0.0.1", port: silent.port)!, upnpDescription: nil))
        m.start()
        check(wait(6) { if case .unavailable = m.state { return true }; return false }, "silent router not given up on: \(m.state)")
        m.stop()
        silent.close()
    }
    if problems == 0 { print("  port mapping OK (NAT-PMP, UPnP with a taken port, double NAT, silent router)") }
    return problems
}

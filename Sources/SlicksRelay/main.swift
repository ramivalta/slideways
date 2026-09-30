import Foundation
import SlicksLink

// Slideways rendezvous and relay server.
//
// Lets players join a game with just its code, without the host forwarding ports: the host
// registers a room, players look it up, and both sides try to reach each other directly. If
// their routers won't allow that, game traffic is relayed through here. Game packets are
// encrypted end to end; this server never sees join secrets or race data.
//
// Usage: SlicksRelay [port]      (default 47810, UDP)
// Needs a publicly reachable machine with that UDP port open. Builds on macOS and Linux:
//   swift build -c release --product SlicksRelay

setvbuf(stdout, nil, _IOLBF, 0)
let port = CommandLine.arguments.dropFirst().first.flatMap { UInt16($0) } ?? RelayMessage.defaultPort
do {
    let server = try RelayServer(port: port)
    print("Slideways relay listening on UDP port \(server.socket.port)")
    let stats = DispatchSource.makeTimerSource(queue: .main)
    stats.schedule(deadline: .now() + 60, repeating: 60)
    stats.setEventHandler {
        print("rooms \(server.roomCount), sessions \(server.sessionCount), relayed \(server.relayedBytes / 1024) KB")
    }
    stats.resume()
    withExtendedLifetime((server, stats)) { dispatchMain() }
} catch {
    print("can't start: \(error)")
    exit(1)
}

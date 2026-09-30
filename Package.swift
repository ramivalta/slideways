// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Slideways",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "SlicksMac", targets: ["SlicksMac"]),
        .executable(name: "SlicksSim", targets: ["SlicksSim"]),
        .executable(name: "SlicksRelay", targets: ["SlicksRelay"]),
    ],
    targets: [
        // Little-endian byte coding shared by the game and the relay server.
        .target(name: "SlicksBytes"),
        // Platform-independent simulation: tracks, physics, AI, race rules.
        .target(name: "SlicksCore", dependencies: ["SlicksBytes"]),
        // UDP sockets and the rendezvous/relay protocol. Foundation only, so it builds on Linux.
        .target(name: "SlicksLink", dependencies: ["SlicksBytes"]),
        // Online play: encrypted UDP transport, lobby and race sync (no UI).
        .target(name: "SlicksNet", dependencies: ["SlicksCore", "SlicksLink"]),
        // Rendezvous/relay server for internet play without port forwarding.
        .executableTarget(name: "SlicksRelay", dependencies: ["SlicksLink"]),
        // SpriteKit presentation shared by all Apple platforms.
        .target(name: "SlicksGame", dependencies: ["SlicksCore", "SlicksLink", "SlicksNet"]),
        // macOS host application.
        .executableTarget(name: "SlicksMac", dependencies: ["SlicksGame"]),
        // Headless tool: validates tracks, runs AI-only races and online loopback tests.
        .executableTarget(name: "SlicksSim", dependencies: ["SlicksCore", "SlicksLink", "SlicksNet", "SlicksGame"]),
    ],
    swiftLanguageModes: [.v5]
)

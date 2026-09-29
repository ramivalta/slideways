// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Slideways",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "SlicksMac", targets: ["SlicksMac"]),
        .executable(name: "SlicksSim", targets: ["SlicksSim"]),
    ],
    targets: [
        // Platform-independent simulation: tracks, physics, AI, race rules.
        .target(name: "SlicksCore"),
        // SpriteKit presentation shared by all Apple platforms.
        .target(name: "SlicksGame", dependencies: ["SlicksCore"]),
        // macOS host application.
        .executableTarget(name: "SlicksMac", dependencies: ["SlicksGame"]),
        // Headless tool: validates tracks and runs AI-only races.
        .executableTarget(name: "SlicksSim", dependencies: ["SlicksCore", "SlicksGame"]),
    ],
    swiftLanguageModes: [.v5]
)

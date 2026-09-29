#if DEBUG && os(macOS)
import AppKit
import Foundation
import ImageIO
import SpriteKit
import UniformTypeIdentifiers

/// Debug-only smoke test: set SLIDEWAYS_SNAPSHOT_DIR to have the app capture the menu,
/// run a 1-lap AI-only race, save frames along the way, then quit.
public enum DebugHarness {
    @MainActor
    public static func runIfRequested(view: SKView) {
        guard let dir = ProcessInfo.processInfo.environment["SLIDEWAYS_SNAPSHOT_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let track = Int(ProcessInfo.processInfo.environment["SLIDEWAYS_TRACK"] ?? "") ?? 1

        func snap(_ name: String) {
            guard let scene = view.scene, let cg = view.texture(from: scene)?.cgImage(),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else {
                print("snapshot \(name) failed")
                return
            }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("snapshot \(name) saved")
        }

        func after(_ t: Double, _ block: @escaping () -> Void) {
            Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in block() }
        }

        after(1) { snap("menu") }
        after(1.5) {
            var s = RaceSettings()
            s.trackIndex = track
            s.laps = 1
            s.humanPlayers = 0
            s.aiOpponents = 8
            GameCoordinator.shared.settings = s
            GameCoordinator.shared.startRace(persist: false)
        }
        after(3) { snap("countdown") }
        for (i, t) in [7.0, 8.5, 10.0, 11.5].enumerated() {
            after(t) { snap("racing\(i + 1)") }
        }
        after(34) { snap("results") }
        after(35) { NSApplication.shared.terminate(nil) }
    }
}
#endif

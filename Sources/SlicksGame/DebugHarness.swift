#if DEBUG && os(macOS)
import AppKit
import Foundation
import ImageIO
import SlicksCore
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

        if ProcessInfo.processInfo.environment["SLIDEWAYS_EDITOR_TEST"] != nil {
            return runEditorScript(view: view, snap: snap, after: after)
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

    /// Walks the level editor through each tool with synthetic pointer input.
    @MainActor
    static func runEditorScript(view: SKView, snap: @escaping (String) -> Void,
                                after: @escaping (Double, @escaping () -> Void) -> Void) {
        let coordinator = GameCoordinator.shared
        var editor: EditorScene? { view.scene as? EditorScene }
        func log(_ what: String) { print("editor test: \(what) -> \(editor?.debugSummary ?? "no editor")") }
        var t = 0.5
        func step(_ gap: Double = 1.2, _ block: @escaping () -> Void) {
            t += gap
            after(t, block)
        }

        step(0.5) { coordinator.showEditor(editing: nil) }
        step { snap("editor-1-blank"); log("blank") }
        step {
            guard let e = editor else { return }
            e.debugClick("Road")
            e.pointerMoved(to: e.toScene(Vec2(470, 470)))
            snap("editor-2-road-hover")
            e.debugDrag(from: Vec2(470, 470), to: Vec2(480, 380))
            log("added road point")
        }
        step { snap("editor-3-road-added") }
        step {
            // Mid-drag frame: the quick vector preview stands in for the raster.
            guard let e = editor else { return }
            let a = e.toScene(Vec2(480, 380))
            e.pointerDown(at: a)
            for k in 1...6 { e.pointerDragged(to: e.toScene(Vec2(480 + Double(k) * 20, 380 + Double(k) * 10))) }
            snap("editor-3b-mid-drag")
            e.pointerUp(at: e.toScene(Vec2(600, 440)))
            log("dragged point")
        }
        step {
            guard let e = editor else { return }
            e.debugClick("Patch")
            e.debugClick("Ice")
            e.debugClick("Yes")
            e.debugDrag(from: Vec2(830, 300), to: Vec2(880, 300))
            // A freshly drawn patch stays selected, so deselect before picking the next look.
            e.debugClick("Done")
            e.debugClick("Wall")
            e.debugClick("No")
            e.debugClick("Capsule")
            e.debugDrag(from: Vec2(300, 260), to: Vec2(420, 260))
            e.debugClick("Done")
            e.debugClick("Sand")
            e.debugClick("Rect")
            e.debugDrag(from: Vec2(20, 20), to: Vec2(140, 110))
            log("patches")
        }
        step { snap("editor-4-patches") }
        step {
            guard let e = editor else { return }
            e.debugClick("Select")
            e.select(.none)
            e.debugClick("Winter")
            e.debugClick("Undo")
            e.debugClick("Redo")
            e.debugClick("Off")
            log("winter, no barrier")
        }
        step { snap("editor-5-theme"); log("theme settled") }
        step {
            guard let e = editor else { return }
            e.debugClick("Open")
            snap("editor-6-confirm")
            e.debugClick("Discard")
            snap("editor-7-open")
            e.debugClick("Overpass")
            e.debugClick("Bridge")
            log("opened overpass copy")
        }
        step { snap("editor-8-bridge-tool") }
        step {
            guard let e = editor else { return }
            let p = e.toScene(Vec2(440, 300))
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            log("flipped bridge")
        }
        step(1.8) { snap("editor-9-bridge-flipped") }
        step {
            guard let e = editor else { return }
            e.debugClick("Save")
            log("saved")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: TrackStore.directory.path)) ?? []
            print("editor test: track files \(files)")
        }
        step { editor?.debugClick("Test >") }
        step(4) { snap("editor-10-test-drive") }
        step { coordinator.returnToEditor() }
        step { snap("editor-11-back"); log("back from test drive") }
        step {
            guard let e = editor else { return }
            e.debugClick("Select")
            let p = e.toScene(Vec2(440, 300))
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            log("selected bridge point")
        }
        step { snap("editor-12-bridge-inspector") }
        step {
            // Widen the far right sweeper by dragging its edge handle, then narrow the bridge's
            // lower road with the stepper.
            guard let e = editor else { return }
            let p = e.toScene(e.def.controlPoints[3])
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            guard let h = e.debugWidthHandle else { return print("editor test: no width handle") }
            let out = h + (h - e.def.controlPoints[3]).normalized * 30
            e.debugDrag(from: h, to: out)
            log("widened point 4")
            let q = e.toScene(e.def.controlPoints[15])
            e.pointerMoved(to: q)
            e.pointerDown(at: q)
            e.pointerUp(at: q)
            // Point 16 shares its spot with the bridge point; step it down 10 times.
            for _ in 0..<10 { e.debugClick("-") }
            log("narrowed a point")
        }
        step(0.6) {
            // Mid-drag of the edge handle, to see the quick preview follow.
            guard let e = editor else { return }
            let p = e.toScene(e.def.controlPoints[11])
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            guard let h = e.debugWidthHandle else { return }
            e.pointerMoved(to: e.toScene(h))
            e.pointerDown(at: e.toScene(h))
            e.pointerDragged(to: e.toScene(h + (h - e.def.controlPoints[11]).normalized * 25))
            snap("editor-14-width-mid-drag")
            e.pointerUp(at: e.toScene(h + (h - e.def.controlPoints[11]).normalized * 25))
            log("widened point 12")
        }
        step(2) { snap("editor-15-widths"); log("widths settled") }
        step {
            guard let e = editor else { return }
            e.debugClick("Test >")
        }
        step(4) { snap("editor-16-width-test-drive") }
        step { coordinator.returnToEditor() }
        step { editor?.debugClick("< Menu"); editor?.debugClick("Discard") }
        step { snap("editor-13-menu") }
        step(0.5) { NSApplication.shared.terminate(nil) }
    }
}
#endif

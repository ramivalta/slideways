#if os(macOS)
import AppKit
import SpriteKit

/// SKView that also delivers mouse-moved, scroll and pinch events to the scene, which the
/// level editor uses for hover feedback, panning and zooming.
public final class GameView: SKView {
    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        if let scene { scene.mouseMoved(with: event) } else { super.mouseMoved(with: event) }
    }

    public override func scrollWheel(with event: NSEvent) {
        if let scene { scene.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    public override func magnify(with event: NSEvent) {
        if let scene { scene.magnify(with: event) } else { super.magnify(with: event) }
    }

    /// Command-Return toggles full screen, the shortcut many games use, alongside the View
    /// menu's standard Control-Command-F.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, mods == .command, event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { window?.toggleFullScreen(nil) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension SKScene {
    /// True while the game window fills the screen.
    var isFullScreen: Bool { view?.window?.styleMask.contains(.fullScreen) ?? false }

    /// Enters or leaves full screen. The switch animates; the window posts
    /// didEnter/didExitFullScreen notifications when it's done.
    func toggleFullScreen() { view?.window?.toggleFullScreen(nil) }
}
#endif

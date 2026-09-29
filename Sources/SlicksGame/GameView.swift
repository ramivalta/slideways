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
}
#endif

import CoreGraphics
import Foundation
import SlicksCore
import SpriteKit

/// Draws the rubber a race lays on the road as a dark sheen over the asphalt, so the grippy
/// rubbered-in line is visible. Drawn one pixel per track cell, smoothly blended between
/// rubber cells and only over road that takes rubber.
final class RubberLayer: SKSpriteNode {
    /// Frames between texture uploads. Rubber builds slowly; skid marks show the instant detail.
    private static let uploadInterval = 12
    /// Opacity of fully rubbered road.
    private static let fullAlpha = 0.42

    private let track: Track
    private let w: Int
    private let h: Int
    /// Which pixels are road that takes rubber.
    private let holds: [Bool]
    private var pixels: [UInt8]
    private var dirty = false
    private var framesSinceUpload = 0

    init(track: Track) {
        self.track = track
        w = track.width
        h = track.height
        holds = track.surfaces.map(Rubber.holdsRubber)
        pixels = [UInt8](repeating: 0, count: track.width * track.height * 4)
        super.init(texture: nil, color: .clear, size: CGSize(width: track.width, height: track.height))
        anchorPoint = .zero
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    /// Call once per frame after stepping the race.
    func update(from rubber: Rubber) {
        let changes = rubber.drainChanges()
        if !changes.isEmpty {
            for i in changes { repaint(cell: i, of: rubber) }
            dirty = true
        }
        framesSinceUpload += 1
        if dirty && framesSinceUpload >= Self.uploadInterval { upload() }
    }

    /// Repaints every pixel a rubber cell's value blends into: from the neighbouring cell
    /// centres on either side.
    private func repaint(cell i: Int, of rubber: Rubber) {
        let s = Rubber.cellSize
        let cx = i % rubber.columns, cy = i / rubber.columns
        let x0 = max(0, cx * s - s / 2), x1 = min(w, (cx + 1) * s + s / 2)
        let y0 = max(0, cy * s - s / 2), y1 = min(h, (cy + 1) * s + s / 2)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = ((h - 1 - y) * w + x) * 4
                guard holds[y * w + x] else { continue }
                let r = rubber.level(at: Vec2(Double(x) + 0.5, Double(y) + 0.5))
                // A little grain so it reads as worn-in rubber rather than a flat tint.
                let alpha = clamp(r * Self.fullAlpha * (0.85 + 0.3 * hash01(x, y, 41)), 0, 1)
                let shade = 14.0 * alpha
                pixels[o] = UInt8(shade)
                pixels[o + 1] = UInt8(shade)
                pixels[o + 2] = UInt8(clamp(shade * 1.1, 0, 255))
                pixels[o + 3] = UInt8(alpha * 255)
            }
        }
    }

    private func upload() {
        let t = SKTexture(cgImage: TrackRenderer.makeCGImage(pixels: pixels, width: w, height: h))
        t.filteringMode = .nearest
        texture = t
        isHidden = false
        dirty = false
        framesSinceUpload = 0
    }
}

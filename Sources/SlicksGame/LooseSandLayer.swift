import CoreGraphics
import Foundation
import SlicksCore
import SpriteKit

/// Draws a race's loose sand over the ground: one pixel per cell, like the track itself.
/// A thin dusting shows as scattered grains; a thick layer as solid sand.
final class LooseSandLayer: SKSpriteNode {
    /// Frames between texture uploads while sand is moving.
    private static let uploadInterval = 6

    private let w: Int
    private let h: Int
    private let sandColor: RGB
    private var pixels: [UInt8]
    private var dirty = false
    private var framesSinceUpload = 0

    init(width: Int, height: Int, theme: TrackTheme) {
        w = width
        h = height
        sandColor = TrackRenderer.palette(theme).sand
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        super.init(texture: nil, color: .clear, size: CGSize(width: width, height: height))
        anchorPoint = .zero
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    /// Call once per frame after stepping the race.
    func update(from sand: LooseSand) {
        let changes = sand.drainChanges()
        if !changes.isEmpty {
            for i in changes { paint(cell: i, amount: Double(sand.amount[i])) }
            dirty = true
        }
        framesSinceUpload += 1
        if dirty && framesSinceUpload >= Self.uploadInterval { upload() }
    }

    private func paint(cell i: Int, amount a: Double) {
        let x = i % w, y = i / w
        let o = ((h - 1 - y) * w + x) * 4
        // Each pixel shows once there's enough sand for its grain; about half a trap's worth
        // covers the ground completely.
        guard a > 0, hash01(x, y, 23) < a * 1.9 else {
            pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
            return
        }
        let c = sandColor.scaled(0.82 + 0.26 * hash01(x, y, 29))
        let alpha = min(1, 0.55 + a)
        pixels[o] = UInt8(clamp(c.r * alpha, 0, 255))
        pixels[o + 1] = UInt8(clamp(c.g * alpha, 0, 255))
        pixels[o + 2] = UInt8(clamp(c.b * alpha, 0, 255))
        pixels[o + 3] = UInt8(clamp(alpha * 255, 0, 255))
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

import CoreGraphics
import SlicksCore
import SpriteKit

/// Tire marks that last the whole race.
///
/// New segments show up immediately as small sprites, and are also painted into a bitmap
/// covering the world. Every so often the bitmap becomes the texture of one big sprite and the
/// live segment sprites are recycled, so the node count stays small no matter how many marks
/// pile up.
final class SkidMarks: SKNode {
    /// Bitmap pixels per world unit.
    private static let scale: CGFloat = 2
    /// Bake after this many live segments, or after `bakeInterval` frames with any pending.
    private static let bakeThreshold = 240
    private static let bakeInterval = 30

    private var canvas: CGContext?
    private let baked = SKSpriteNode()
    private var live: [SKSpriteNode] = []
    private var spare: [SKSpriteNode] = []
    private var framesSinceBake = 0

    override init() {
        super.init()
        baked.anchorPoint = .zero
        baked.zPosition = -0.01
        addChild(baked)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    /// Sets up the bitmap for a world of the given size. Call before adding segments.
    func configure(worldSize: CGSize) {
        let s = Self.scale
        let ctx = CGContext(data: nil, width: Int(worldSize.width * s), height: Int(worldSize.height * s),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.scaleBy(x: s, y: s)
        ctx?.setLineCap(.butt)
        ctx?.setShouldAntialias(true)
        canvas = ctx
        baked.size = worldSize
        baked.texture = nil
        baked.isHidden = true
    }

    func addSegment(from a: CGPoint, to b: CGPoint, color: SKColor, width: CGFloat = 2.2) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.5 else { return }

        let node = spare.popLast() ?? {
            let n = SKSpriteNode(color: color, size: .zero)
            n.anchorPoint = CGPoint(x: 0, y: 0.5)
            return n
        }()
        node.color = color
        node.size = CGSize(width: len + 0.6, height: width)
        node.position = a
        node.zRotation = atan2(dy, dx)
        if node.parent == nil { addChild(node) }
        live.append(node)

        // Same rectangle as the sprite: from a, slightly past b.
        if let canvas {
            let ux = dx / len, uy = dy / len
            canvas.setStrokeColor(color.cgColor)
            canvas.setLineWidth(width)
            canvas.move(to: a)
            canvas.addLine(to: CGPoint(x: a.x + ux * (len + 0.6), y: a.y + uy * (len + 0.6)))
            canvas.strokePath()
        }
    }

    /// Call once per frame. Folds live segments into the baked texture now and then.
    func tick() {
        framesSinceBake += 1
        guard !live.isEmpty, canvas != nil else { return }
        if live.count >= Self.bakeThreshold || framesSinceBake >= Self.bakeInterval { bake() }
    }

    private func bake() {
        guard let image = canvas?.makeImage() else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        baked.texture = texture
        baked.isHidden = false
        for node in live { node.removeFromParent() }
        spare.append(contentsOf: live)
        live.removeAll(keepingCapacity: true)
        framesSinceBake = 0
    }

    static func color(for surface: Surface, theme: TrackTheme) -> SKColor? {
        switch surface {
        case .asphalt, .curb: SKColor(white: 0.05, alpha: 0.32)
        case .grass: theme == .winter ? SKColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 0.45)
            : theme == .desert ? SKColor(red: 0.45, green: 0.3, blue: 0.16, alpha: 0.4)
            : SKColor(red: 0.18, green: 0.3, blue: 0.1, alpha: 0.5)
        case .sand: SKColor(red: 0.55, green: 0.42, blue: 0.24, alpha: 0.45)
        case .ice: SKColor(white: 1, alpha: 0.4)
        case .wall: nil
        }
    }
}

import SlicksCore
import SpriteKit

/// Tire marks as short line segments, recycled from a fixed pool so old marks fade out of existence.
final class SkidMarks: SKNode {
    private let capacity: Int
    private var pool: [SKSpriteNode] = []
    private var next = 0

    init(capacity: Int = 3000) {
        self.capacity = capacity
        super.init()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    func addSegment(from a: CGPoint, to b: CGPoint, color: SKColor, width: CGFloat = 2.2) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.5 else { return }
        let node: SKSpriteNode
        if pool.count < capacity {
            node = SKSpriteNode(color: color, size: .zero)
            node.anchorPoint = CGPoint(x: 0, y: 0.5)
            pool.append(node)
            addChild(node)
        } else {
            node = pool[next]
            next = (next + 1) % capacity
        }
        node.color = color
        node.size = CGSize(width: len + 0.6, height: width)
        node.position = a
        node.zRotation = atan2(dy, dx)
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

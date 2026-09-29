#if os(macOS)
import SlicksCore
import SpriteKit

// Small SpriteKit widget kit for the level editor. The views ignore sibling order, so every
// node gets an explicit zPosition relative to its parent.

/// A clickable rounded button. Fires on mouse down.
final class EditorButton: SKNode {
    let size: CGSize
    let action: () -> Void
    /// Shown in the status bar while hovered.
    var tip: String?
    var isSelected = false { didSet { restyle() } }
    var isEnabled = true { didSet { restyle() } }
    var isHovered = false { didSet { if isHovered != oldValue { restyle() } } }
    var title: String { didSet { label.text = title } }

    private let tint: SKColor?
    private let bg: SKShapeNode
    private let label: SKLabelNode

    init(_ title: String, size: CGSize, fontSize: CGFloat = 10, tint: SKColor? = nil, alignLeft: Bool = false,
         tip: String? = nil, action: @escaping () -> Void) {
        self.size = size
        self.title = title
        self.tint = tint
        self.tip = tip
        self.action = action
        bg = SKShapeNode(rect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                         cornerRadius: 4)
        label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = title
        label.fontSize = fontSize
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = alignLeft ? .left : .center
        label.position = CGPoint(x: alignLeft ? -size.width / 2 + 7 : 0, y: 0)
        label.zPosition = 1
        super.init()
        addChild(bg)
        addChild(label)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    /// Whether a scene point lands on this button, taking visibility into account.
    func hit(_ scenePoint: CGPoint, in scene: SKScene) -> Bool {
        guard isEnabled, isEffectivelyVisible else { return false }
        let p = convert(scenePoint, from: scene)
        return abs(p.x) <= size.width / 2 && abs(p.y) <= size.height / 2
    }

    private var isEffectivelyVisible: Bool {
        var n: SKNode? = self
        while let node = n {
            if node.isHidden || node.alpha == 0 { return false }
            n = node.parent
        }
        return true
    }

    private func restyle() {
        alpha = isEnabled ? 1 : 0.35
        if let tint {
            bg.fillColor = isHovered && !isSelected ? tint.blended(withFraction: 0.2, of: .white) ?? tint : tint
            bg.strokeColor = isSelected ? .accent : SKColor(white: 1, alpha: 0.25)
            bg.lineWidth = isSelected ? 2.5 : 1
            label.fontColor = tint.luminance > 0.55 ? SKColor(white: 0.08, alpha: 1) : .white
        } else if isSelected {
            bg.fillColor = .accent
            bg.strokeColor = .accent
            bg.lineWidth = 1
            label.fontColor = SKColor(white: 0.08, alpha: 1)
        } else {
            bg.fillColor = SKColor(white: isHovered ? 0.26 : 0.16, alpha: 1)
            bg.strokeColor = SKColor(white: 1, alpha: isHovered ? 0.45 : 0.18)
            bg.lineWidth = 1
            label.fontColor = .white
        }
    }
}

/// Top-to-bottom layout for inspector panels and dialogs. The node's origin is the top-left
/// corner; content grows downward (negative y).
final class PanelLayout {
    struct Option {
        var title: String
        var selected = false
        var tint: SKColor? = nil
        var enabled = true
        var tip: String? = nil
        var action: () -> Void
    }

    let node = SKNode()
    let width: CGFloat
    let pad: CGFloat = 10
    let labelWidth: CGFloat = 68
    private(set) var y: CGFloat = -6
    private let rowHeight: CGFloat = 22

    init(width: CGFloat) { self.width = width }

    var height: CGFloat { -y + 8 }
    private var inner: CGFloat { width - pad * 2 }

    @discardableResult
    func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 10, color: SKColor = .white,
               align: SKLabelHorizontalAlignmentMode = .left) -> SKLabelNode {
        let l = SKLabelNode(fontNamed: "Menlo-Bold")
        l.text = text
        l.fontSize = size
        l.fontColor = color
        l.horizontalAlignmentMode = align
        l.verticalAlignmentMode = .center
        l.position = CGPoint(x: x, y: y)
        l.zPosition = 1
        node.addChild(l)
        return l
    }

    func gap(_ h: CGFloat) { y -= h }

    func header(_ text: String) {
        y -= 12
        label(text, x: pad, y: y, size: 12, color: .accent)
        y -= 12
    }

    /// Wrapped dim text.
    func note(_ text: String, color: SKColor = .dim) {
        for line in PanelLayout.wrap(text, width: Int(inner / 6.1)) {
            y -= 7
            label(line, x: pad, y: y, color: color)
            y -= 7
        }
        y -= 3
    }

    /// A row of mutually exclusive or independent buttons, optionally labelled on the left,
    /// wrapping after `perRow` buttons.
    func choices(_ title: String?, _ options: [Option], perRow: Int? = nil) {
        guard !options.isEmpty else { return }
        let x0 = title == nil ? pad : pad + labelWidth
        let perRow = max(1, perRow ?? options.count)
        let spacing: CGFloat = 4
        let w = (width - pad - x0 - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)
        y -= 2
        if let title { label(title, x: pad, y: y - rowHeight / 2, color: .dim) }
        for (k, o) in options.enumerated() {
            if k > 0 && k % perRow == 0 { y -= rowHeight + 4 }
            let col = k % perRow
            let b = EditorButton(o.title, size: CGSize(width: w, height: rowHeight), tint: o.tint, tip: o.tip, action: o.action)
            b.isSelected = o.selected
            b.isEnabled = o.enabled
            b.position = CGPoint(x: x0 + CGFloat(col) * (w + spacing) + w / 2, y: y - rowHeight / 2)
            node.addChild(b)
        }
        y -= rowHeight + 4
    }

    /// Label, minus button, value, plus button.
    func stepper(_ title: String, value: String, tip: String? = nil, minus: @escaping () -> Void, plus: @escaping () -> Void) {
        y -= 2
        let cy = y - rowHeight / 2
        label(title, x: pad, y: cy, color: .dim)
        let x0 = pad + labelWidth, x1 = width - pad
        let m = EditorButton("-", size: CGSize(width: 28, height: rowHeight), fontSize: 13, tip: tip, action: minus)
        m.position = CGPoint(x: x0 + 14, y: cy)
        node.addChild(m)
        let p = EditorButton("+", size: CGSize(width: 28, height: rowHeight), fontSize: 13, tip: tip, action: plus)
        p.position = CGPoint(x: x1 - 14, y: cy)
        node.addChild(p)
        label(value, x: (x0 + x1) / 2, y: cy, size: 11, align: .center)
        y -= rowHeight + 4
    }

    /// A text field look-alike. Typing is handled by the scene while it's focused.
    func field(_ title: String, text: String, focused: Bool, tip: String?, action: @escaping () -> Void) {
        y -= 2
        let cy = y - rowHeight / 2
        label(title, x: pad, y: cy, color: .dim)
        let w = width - pad * 2 - labelWidth
        let b = EditorButton(text, size: CGSize(width: w, height: rowHeight), alignLeft: true, tip: tip, action: action)
        b.isSelected = focused
        b.position = CGPoint(x: pad + labelWidth + w / 2, y: cy)
        node.addChild(b)
        y -= rowHeight + 4
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + 1 + word.count > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

extension SKColor {
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    convenience init(_ c: RGB, alpha: CGFloat = 1) {
        self.init(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
    }
}

enum EditorColors {
    static let point = SKColor(red: 0.45, green: 0.8, blue: 1, alpha: 1)
    static let bridge = SKColor(TrackRenderer.railLight)
    static let issue = SKColor(red: 1, green: 0.35, blue: 0.3, alpha: 1)
    static let ok = SKColor(red: 0.5, green: 0.9, blue: 0.5, alpha: 1)

    /// Swatch for a surface, in the track theme's colors.
    static func swatch(_ s: Surface, theme: TrackTheme) -> SKColor {
        let pal = TrackRenderer.palette(theme)
        switch s {
        case .asphalt: return SKColor(pal.asphalt)
        case .curb: return SKColor(RGB(206, 44, 40))
        case .grass: return SKColor(pal.ground)
        case .sand: return SKColor(pal.sand)
        case .ice: return SKColor(RGB(186, 222, 244))
        case .wall: return SKColor(RGB(46, 46, 52))
        }
    }

    /// Outline for a patch of a surface: the swatch, lifted so dark surfaces stay visible.
    static func outline(_ s: Surface, theme: TrackTheme) -> SKColor {
        let c = swatch(s, theme: theme)
        return c.blended(withFraction: s == .wall || s == .asphalt ? 0.6 : 0.25, of: .white) ?? c
    }
}
#endif

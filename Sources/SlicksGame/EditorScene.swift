#if os(macOS)
import AppKit
import SlicksCore
import SpriteKit
import UniformTypeIdentifiers

/// Mouse-driven level editor. The map is edited as a `TrackDefinition`; every change rebuilds
/// the real `Track` in the background so the map shows exactly what will be raced, while a
/// vector overlay (centerline, points, patch outlines, crossings) gives instant feedback.
final class EditorScene: GameScene {
    enum Tool: CaseIterable {
        case select, road, patch, bridge, line, object

        var title: String {
            switch self {
            case .select: "Select"
            case .road: "Road"
            case .patch: "Patch"
            case .bridge: "Bridge"
            case .line: "Line"
            case .object: "Object"
            }
        }

        var shortcut: String {
            switch self {
            case .select: "V"
            case .road: "R"
            case .patch: "P"
            case .bridge: "B"
            case .line: "L"
            case .object: "O"
            }
        }

        var hint: String {
            switch self {
            case .select: "Drag road points, patches, lines and objects to move them, drag empty space to pan. Right-click deletes. Scroll or pinch to zoom."
            case .road: "Click to add a road point where the road should bend, drag points to reshape. Right-click a point to delete it."
            case .patch: "Drag on the map to draw a patch (a click gives a default size). Drag a patch to move it, its handles to resize."
            case .bridge: "Click a crossing to build a bridge, click it again to swap which road goes over. Click one next to a bridge to stretch it over. Right-click removes."
            case .line: "Click to start a paint line and click to add points. Click the last point, Enter or right-click to finish."
            case .object: "Click to place a tree or building, drag to move it. Drag its handles to resize or turn it. Right-click deletes."
            }
        }
    }

    enum Selection: Equatable {
        case none
        case point(Int)
        case patch(Int)
        case line(Int)
        case object(Int)
    }

    enum PatchHandle: Equatable {
        case radius
        case corner(Int)
        case end(Int)
    }

    enum ObjectHandle: Equatable {
        /// Tree canopy size.
        case radius
        /// Back right corner of a building: sets its length and depth.
        case corner
        /// In front of a building: turns it.
        case rotate
    }

    private enum Hover: Equatable {
        case none
        case point(Int)
        case patch(Int)
        case handle(PatchHandle)
        case crossing(Int)
        case insert(index: Int, position: Vec2)
        case widthHandle(side: Int)
        case deckHandle(BridgeEnd)
        case line(Int)
        case lineVertex(Int)
        case object(Int)
        case objectHandle(ObjectHandle)
    }

    private enum Drag {
        case pan(start: CGPoint, offset: CGPoint)
        case point(index: Int, grab: Vec2)
        case patch(index: Int, start: Vec2, original: PatchShape)
        case handle(index: Int, handle: PatchHandle, original: PatchShape)
        case create(start: Vec2)
        /// Dragging a road edge handle of the selected point, along the road's normal there.
        case width(index: Int, normal: Vec2)
        /// Dragging one end of a bridge deck along its road.
        case deckEnd(bridge: Int, end: BridgeEnd)
        case line(index: Int, start: Vec2, original: PaintLine)
        case lineVertex(index: Int, vertex: Int)
        case object(index: Int, grab: Vec2)
        case objectHandle(index: Int, handle: ObjectHandle, original: TrackObject)
    }

    private enum Layout {
        static let mapTop: CGFloat = 600
        static let toolbarY: CGFloat = 620
        static let panelWidth: CGFloat = 236
        static let statusHeight: CGFloat = 18
    }

    private enum Z {
        static let world: CGFloat = 0
        static let overlay: CGFloat = 10
        static let status: CGFloat = 40
        static let panel: CGFloat = 50
        static let toolbar: CGFloat = 60
        static let modal: CGFloat = 100
    }

    static let maxNameLength = 24
    private static let gridStep = 10.0

    private unowned let coordinator: GameCoordinator

    // MARK: Document

    private(set) var def: TrackDefinition
    /// The definition as last saved or opened; the document is dirty when `def` differs.
    private var baseline: TrackDefinition
    private var undoStack: [TrackDefinition] = []
    private var redoStack: [TrackDefinition] = []
    /// True while a drag or typing session is folding its edits into one undo step.
    private var changeOpen = false

    private var isDirty: Bool { def != baseline }
    private var isOnDisk: Bool { TrackLibrary.shared.index(of: def.id) != nil }

    // MARK: Editing state

    private(set) var tool: Tool = .select
    private(set) var selection: Selection = .none
    private var hover: Hover = .none
    private var drag: Drag?
    private var dragOrigin: CGPoint = .zero
    private var dragMoved = false
    private var pendingPatch: PatchShape?
    private var spaceHeld = false
    private var editingName = false

    /// Settings for newly drawn patches.
    private var patchSurface: Surface = .sand
    private var patchKind: PatchShapeKind = .circle
    private var patchCoversRoad = false
    private var capsuleRadius = 8.0

    /// Line being drawn with the line tool: clicks add points to it until it's finished.
    private var drawingLine: Int?
    /// Settings for new lines and objects.
    private var lineColor: PaintColor = .white
    private var lineWidth = 2.0
    private var objectKind: TrackObjectKind = .tree
    private var treeSize = TrackObjectKind.tree.defaultSize.x
    private var treeSolid = true
    /// Mouse position on the map, for the line rubber band and the object placement ghost.
    private var cursorWorld: Vec2?

    private var snapToGrid = false
    private var panelVisible = true
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero

    // MARK: Background build

    private var track: Track?
    private var issues: [TrackIssue] = []
    private var requestedGeneration = 0
    private var builtGeneration = -1
    private var isBuilding = false
    private var isCurrent: Bool { builtGeneration == requestedGeneration }
    private var crossingCache: (points: [Vec2], list: [RoadCrossing])?

    // MARK: Nodes

    private var didBuildScene = false
    private let world = SKNode()
    private let mapSprite = SKSpriteNode(color: SKColor(white: 0.2, alpha: 1), size: EditorLimits.mapSize)
    private let overlay = SKNode()
    private let toolbar = SKNode()
    private var toolButtons: [Tool: EditorButton] = [:]
    private var undoButton: EditorButton!
    private var redoButton: EditorButton!
    private var gridButton: EditorButton!
    private var panelButton: EditorButton!
    private var titleLabel: SKLabelNode!
    private let panel = SKNode()
    private var panelBounds = CGRect.zero
    private var statusLabel: SKLabelNode!
    private var coordsLabel: SKLabelNode!
    private var modal: SKNode?
    private weak var hoveredButton: EditorButton?
    private var flashText: String?

    init(coordinator: GameCoordinator, editing source: TrackDefinition?) {
        self.coordinator = coordinator
        let d = EditorScene.prepared(source ?? .blank(id: TrackStore.newID()))
        def = d
        baseline = d
        super.init()
    }

    /// Built-in tracks are edited as a copy so saving never overwrites them.
    private static func prepared(_ source: TrackDefinition) -> TrackDefinition {
        var d = source
        if !TrackStore.isCustom(d.id) {
            d.id = TrackStore.newID()
            d.name = String((d.name + " copy").prefix(maxNameLength))
        }
        return d
    }

    override func didMove(to view: SKView) {
        drag = nil
        spaceHeld = false
        if !didBuildScene {
            didBuildScene = true
            buildScene()
            fitView()
            requestRebuild()
            showQuickPreview()
        }
        refreshAll()
    }

    // MARK: Scene setup

    private func buildScene() {
        world.zPosition = Z.world
        addChild(world)
        mapSprite.anchorPoint = .zero
        world.addChild(mapSprite)

        overlay.zPosition = Z.overlay
        addChild(overlay)

        buildToolbar()

        panel.zPosition = Z.panel
        addChild(panel)

        let status = SKSpriteNode(color: SKColor(white: 0, alpha: 0.65), size: CGSize(width: 960, height: Layout.statusHeight))
        status.anchorPoint = .zero
        status.zPosition = Z.status
        addChild(status)
        statusLabel = makeLabel("", size: 10, color: .white)
        statusLabel.position = CGPoint(x: 6, y: Layout.statusHeight / 2)
        statusLabel.zPosition = 1
        status.addChild(statusLabel)
        coordsLabel = makeLabel("", size: 10, color: .dim, align: .right)
        coordsLabel.position = CGPoint(x: 954, y: Layout.statusHeight / 2)
        coordsLabel.zPosition = 1
        status.addChild(coordsLabel)
    }

    private func buildToolbar() {
        toolbar.zPosition = Z.toolbar
        addChild(toolbar)
        let bar = SKSpriteNode(color: SKColor(white: 0.04, alpha: 1), size: CGSize(width: 960, height: 40))
        bar.anchorPoint = .zero
        bar.position = CGPoint(x: 0, y: Layout.mapTop)
        bar.zPosition = -1
        toolbar.addChild(bar)

        var x: CGFloat = 6
        @discardableResult
        func add(_ title: String, _ width: CGFloat, _ tip: String, _ action: @escaping () -> Void) -> EditorButton {
            let b = EditorButton(title, size: CGSize(width: width, height: 26), fontSize: 11, tip: tip, action: action)
            b.position = CGPoint(x: x + width / 2, y: Layout.toolbarY)
            toolbar.addChild(b)
            x += width + 4
            return b
        }
        add("< Menu", 62, "Back to the race menu") { [unowned self] in goToMenu() }
        x += 6
        add("New", 42, "Start a new track (Cmd+N)") { [unowned self] in newTrack() }
        add("Open", 46, "Open a track to edit (Cmd+O)") { [unowned self] in openTrack() }
        add("Save", 46, "Save this track; it appears in the race menu (Cmd+S)") { [unowned self] in save() }
        add("Test >", 54, "Race this track right now, then come back (T)") { [unowned self] in testDrive() }
        x += 6
        for t in Tool.allCases {
            toolButtons[t] = add(t.title, 50, "\(t.title) tool (\(t.shortcut)): \(t.hint)") { [unowned self] in setTool(t) }
        }
        x += 6
        undoButton = add("Undo", 44, "Undo (Cmd+Z)") { [unowned self] in undo() }
        redoButton = add("Redo", 44, "Redo (Shift+Cmd+Z)") { [unowned self] in redo() }
        x += 6
        gridButton = add("Grid", 42, "Snap to a 10 unit grid (G)") { [unowned self] in toggleGrid() }
        panelButton = add("Panel", 48, "Show or hide the inspector (Tab)") { [unowned self] in togglePanel() }
        add("Fit", 36, "Fit the whole map in view (F)") { [unowned self] in fitView() }

        titleLabel = makeLabel("", size: 11, color: .white, align: .right)
        titleLabel.position = CGPoint(x: 954, y: Layout.toolbarY)
        toolbar.addChild(titleLabel)
    }

    // MARK: View transform

    private func toWorld(_ p: CGPoint) -> Vec2 {
        Vec2(Double((p.x - offset.x) / zoom), Double((p.y - offset.y) / zoom))
    }

    func toScene(_ v: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(v.x) * zoom + offset.x, y: CGFloat(v.y) * zoom + offset.y)
    }

    /// Whole map in the area the inspector doesn't cover.
    private func fitView() {
        let areaWidth = 960 - (panelVisible ? Layout.panelWidth + 12 : 0)
        zoom = min(areaWidth / 960, 1)
        offset = CGPoint(x: (areaWidth - 960 * zoom) / 2, y: (Layout.mapTop - 600 * zoom) / 2)
        applyView()
    }

    private func zoom(by factor: CGFloat, around p: CGPoint) {
        let z = clamp(zoom * factor, 0.4, 8)
        guard z != zoom else { return }
        offset = CGPoint(x: p.x - (p.x - offset.x) * z / zoom, y: p.y - (p.y - offset.y) * z / zoom)
        zoom = z
        applyView()
    }

    private func applyView() {
        // Keep some of the map on screen.
        let margin: CGFloat = 80
        offset.x = clamp(offset.x, margin - 960 * zoom, 960 - margin)
        offset.y = clamp(offset.y, margin - 600 * zoom, Layout.mapTop - margin)
        world.position = offset
        world.setScale(zoom)
        refreshOverlay()
        refreshStatus()
    }

    // MARK: Document changes

    /// Applies a discrete edit as one undo step.
    private func perform(_ body: (inout TrackDefinition) -> Void) {
        closeChange()
        var next = def
        body(&next)
        guard next != def else { return }
        pushUndo()
        def = next
        definitionChanged()
    }

    /// Applies an edit that belongs to an ongoing drag or typing session: the first one opens
    /// an undo step, the rest fold into it.
    private func performContinuing(_ body: (inout TrackDefinition) -> Void) {
        var next = def
        body(&next)
        guard next != def else { return }
        if !changeOpen {
            pushUndo()
            changeOpen = true
        }
        def = next
        definitionChanged(live: true)
    }

    private func closeChange() {
        changeOpen = false
    }

    private func pushUndo() {
        undoStack.append(def)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        closeChange()
        guard let prev = undoStack.popLast() else { return flash("Nothing to undo") }
        drawingLine = nil
        redoStack.append(def)
        def = prev
        definitionChanged()
    }

    private func redo() {
        closeChange()
        guard let next = redoStack.popLast() else { return flash("Nothing to redo") }
        drawingLine = nil
        undoStack.append(def)
        def = next
        definitionChanged()
    }

    /// `live` changes come from drags: the inspector is rebuilt when the drag ends instead.
    private func definitionChanged(live: Bool = false) {
        switch selection {
        case let .point(i) where !def.controlPoints.indices.contains(i): selection = .none
        case let .patch(i) where !def.patches.indices.contains(i): selection = .none
        case let .line(i) where !def.lines.indices.contains(i): selection = .none
        case let .object(i) where !def.objects.indices.contains(i): selection = .none
        default: break
        }
        if let k = drawingLine, !def.lines.indices.contains(k) { drawingLine = nil }
        requestRebuild()
        // Drags get the quick preview immediately. Clicks wait a moment, since a fast exact
        // build would otherwise flash the flat preview for a frame or two.
        mapSprite.removeAction(forKey: "preview")
        if live {
            showQuickPreview()
        } else {
            mapSprite.run(.sequence([.wait(forDuration: 0.12), .run { [weak self] in
                guard let self, !self.isCurrent else { return }
                self.showQuickPreview()
            }]), withKey: "preview")
        }
        refreshOverlay()
        refreshToolbar()
        if !live { refreshPanel() }
    }

    /// Flat vector rendering of the current definition, shown until the exact raster arrives.
    private func showQuickPreview() {
        let texture = SKTexture(cgImage: TrackRenderer.makeQuickPreview(for: def))
        texture.filteringMode = .linear
        mapSprite.texture = texture
        mapSprite.size = EditorLimits.mapSize
    }

    private func load(_ source: TrackDefinition) {
        def = EditorScene.prepared(source)
        baseline = def
        undoStack.removeAll()
        redoStack.removeAll()
        changeOpen = false
        selection = .none
        hover = .none
        drag = nil
        pendingPatch = nil
        drawingLine = nil
        editingName = false
        requestRebuild()
        showQuickPreview()
        refreshAll()
    }

    // MARK: Background build

    private func requestRebuild() {
        requestedGeneration += 1
        if !isBuilding { startBuild() }
    }

    private func startBuild() {
        isBuilding = true
        let generation = requestedGeneration
        let d = def
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let track = Track(definition: d)
            let image = TrackRenderer.makeCompositeImage(for: track)
            let issues = track.issues()
            DispatchQueue.main.async { [weak self] in
                self?.finishBuild(track: track, image: image, issues: issues, generation: generation)
            }
        }
    }

    private func finishBuild(track: Track, image: CGImage, issues: [TrackIssue], generation: Int) {
        isBuilding = false
        self.track = track
        builtGeneration = generation
        if isCurrent {
            self.issues = issues
            mapSprite.removeAction(forKey: "preview")
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            mapSprite.texture = texture
            mapSprite.size = EditorLimits.mapSize
        } else {
            // Superseded while building: keep the preview of the newer edit up.
            startBuild()
        }
        refreshOverlay()
        // The inspector shows the checks; don't rebuild it under the mouse mid-drag.
        if drag == nil { refreshPanel() }
    }

    private var crossings: [RoadCrossing] {
        if let c = crossingCache, c.points == def.controlPoints { return c.list }
        let list = def.crossings()
        crossingCache = (def.controlPoints, list)
        return list
    }

    // MARK: Hit testing

    private func isOverUI(_ p: CGPoint) -> Bool {
        modal != nil || p.y >= Layout.mapTop || (panelVisible && panelBounds.contains(p))
    }

    private func button(at p: CGPoint) -> EditorButton? {
        let roots: [SKNode] = modal.map { [$0] } ?? [toolbar, panel]
        for root in roots {
            var found: EditorButton?
            root.enumerateChildNodes(withName: "//*") { node, stop in
                if let b = node as? EditorButton, b.hit(p, in: self) {
                    found = b
                    stop.pointee = true
                }
            }
            if let found { return found }
        }
        return nil
    }

    /// Hit radius in world units for a distance in screen points.
    private func tolerance(_ points: CGFloat) -> Double { Double(points / zoom) }

    private func pointIndex(at w: Vec2) -> Int? {
        let tol = tolerance(9)
        var best: Int?, bestD = Double.infinity
        for (i, p) in def.controlPoints.enumerated() {
            let d = p.distance(to: w)
            if d < tol, d < bestD { best = i; bestD = d }
        }
        return best
    }

    private func patchIndex(at w: Vec2) -> Int? {
        let tol = tolerance(4)
        let onDeck = track?.deck(x: Int(floor(w.x)), y: Int(floor(w.y))) != nil
        let visible = def.patches.indices.reversed().first {
            def.patches[$0].onDeck == onDeck && def.patches[$0].shape.distance(to: w) <= tol
        }
        if visible != nil || tool != .select { return visible }
        return def.patches.indices.reversed().first { def.patches[$0].shape.distance(to: w) <= tol }
    }

    private func handles(of shape: PatchShape) -> [(PatchHandle, Vec2)] {
        switch shape {
        case let .circle(c, r):
            return [(.radius, c + Vec2(r, 0))]
        case let .rect(o, s):
            return [(.corner(0), o), (.corner(1), o + Vec2(s.x, 0)), (.corner(2), o + s), (.corner(3), o + Vec2(0, s.y))]
        case let .capsule(a, b, r):
            return [(.end(0), a), (.end(1), b), (.radius, (a + b) * 0.5 + capsuleNormal(a, b) * r)]
        }
    }

    private func capsuleNormal(_ a: Vec2, _ b: Vec2) -> Vec2 {
        let d = (b - a).normalized
        return d.lengthSquared > 0 ? d.perp : Vec2(0, 1)
    }

    private func handle(at w: Vec2) -> PatchHandle? {
        guard case let .patch(i) = selection, def.patches.indices.contains(i) else { return nil }
        let tol = tolerance(8)
        return handles(of: def.patches[i].shape).first { $0.1.distance(to: w) < tol }?.0
    }

    /// Topmost paint line under `w`.
    private func lineIndex(at w: Vec2) -> Int? {
        let tol = tolerance(4)
        return def.lines.indices.reversed().first { def.lines[$0].distance(to: w) <= def.lines[$0].width / 2 + tol }
    }

    /// Point of the selected line under `w`.
    private func lineVertex(at w: Vec2) -> Int? {
        guard case let .line(i) = selection, def.lines.indices.contains(i) else { return nil }
        let tol = tolerance(7)
        return def.lines[i].points.indices.reversed().first { def.lines[i].points[$0].distance(to: w) < tol }
    }

    /// Topmost object under `w`. Trees are drawn over buildings, so they win.
    private func objectIndex(at w: Vec2) -> Int? {
        let tol = tolerance(2)
        func hit(_ o: TrackObject) -> Bool {
            o.kind.isTree ? o.position.distance(to: w) <= o.radius + tol : o.covers(w)
        }
        let order = def.objects.indices.reversed()
        return order.first { def.objects[$0].kind.isTree && hit(def.objects[$0]) }
            ?? order.first { !def.objects[$0].kind.isTree && hit(def.objects[$0]) }
    }

    /// Distance of a building's turn handle in front of it.
    private static let rotateHandleGap = 14.0

    private func objectHandles(of o: TrackObject) -> [(ObjectHandle, Vec2)] {
        if o.kind.isTree { return [(.radius, o.position + Vec2(o.radius, 0))] }
        let side = turnHandleSide(o)
        return [(.corner, o.world(Vec2(o.size.x / 2, -side * o.size.y / 2))),
                (.rotate, o.world(Vec2(0, side * (o.size.y / 2 + Self.rotateHandleGap))))]
    }

    private func objectHandle(at w: Vec2) -> ObjectHandle? {
        guard case let .object(i) = selection, def.objects.indices.contains(i) else { return nil }
        let tol = tolerance(8)
        return objectHandles(of: def.objects[i]).first { $0.1.distance(to: w) < tol }?.0
    }

    private func crossingIndex(at w: Vec2) -> Int? {
        let tol = max(def.roadWidth / 2, tolerance(14))
        var best: Int?, bestD = Double.infinity
        for (i, x) in crossings.enumerated() {
            let d = x.point.distance(to: w)
            if d < tol, d < bestD { best = i; bestD = d }
        }
        return best
    }

    private func snap(_ v: Vec2) -> Vec2 {
        let g = EditorScene.gridStep
        return snapToGrid ? Vec2((v.x / g).rounded() * g, (v.y / g).rounded() * g) : Vec2(v.x.rounded(), v.y.rounded())
    }

    /// Unit normal of the road at control point `i`.
    private func pointNormal(_ i: Int) -> Vec2 {
        let dense = Track.centerline(through: def.controlPoints)
        let m = dense.count
        guard m > 4 else { return Vec2(0, 1) }
        let di = i * Track.splineSteps
        let t = (dense[(di + 2) % m] - dense[(di - 2 + m) % m]).normalized
        return t.lengthSquared > 0 ? t.perp : Vec2(0, 1)
    }

    /// Road edge handles of the selected point, which set the road width there.
    private func widthHandles() -> [(side: Int, position: Vec2)] {
        guard tool == .select || tool == .road, case let .point(i) = selection,
              def.controlPoints.indices.contains(i) else { return [] }
        let p = def.controlPoints[i], n = pointNormal(i), h = def.roadWidth(atPoint: i) / 2
        return [(1, p + n * h), (-1, p - n * h)]
    }

    private func widthHandle(at w: Vec2) -> Int? {
        let tol = tolerance(8)
        return widthHandles().first { $0.position.distance(to: w) < tol }?.side
    }

    // MARK: Bridge decks

    /// The last built version of bridge `k`, if the build has it.
    private func builtBridge(_ k: Int) -> Bridge? {
        guard def.bridges.indices.contains(k) else { return nil }
        let cp = def.bridges[k].controlPoint
        return track?.bridges.first { $0.controlPoint == cp }
    }

    /// How far bridge `k`'s deck reaches on one end as last built.
    private func builtExtent(bridge k: Int, _ end: BridgeEnd) -> Double? {
        builtBridge(k).map { end == .back ? -$0.deckStart : $0.deckEnd }
    }

    /// How far bridge `k`'s deck reaches on one end: the fixed length, or the automatic one
    /// from the last build.
    private func deckExtent(bridge k: Int, _ end: BridgeEnd) -> Double? {
        def.bridges[k].extent(end) ?? builtExtent(bridge: k, end)
    }

    /// The build of the current definition, made now if the background one is behind. For
    /// clicks that decide what to do from where the decks are.
    private var currentTrack: Track {
        (isCurrent ? track : nil) ?? Track(definition: def)
    }

    /// Bridge (index into `def.bridges`) whose deck covers a crossing, in `built` or else the
    /// last background build.
    private func coveringBridge(_ x: RoadCrossing, in built: Track? = nil) -> Int? {
        guard let t = built ?? track, let bi = t.bridge(covering: x) else { return nil }
        let cp = t.bridges[bi].controlPoint
        return def.bridges.firstIndex { $0.controlPoint == cp }
    }

    /// How many crossings bridge `k`'s deck covers, at least one if it's on a crossing.
    private func coveredCount(bridge k: Int, in built: Track? = nil) -> Int {
        let n = crossings.filter { coveringBridge($0, in: built) == k }.count
        return max(n, def.crossing(forBridge: k, in: crossings) == nil ? 0 : 1)
    }

    /// Position and direction on the road `distance` along it from control point `cp`
    /// (negative goes back against the race direction).
    private func roadPosition(fromPoint cp: Int, distance: Double, dense: [Vec2]) -> (position: Vec2, tangent: Vec2) {
        let m = dense.count
        guard m > 2 else { return (def.controlPoints[cp], Vec2(1, 0)) }
        let dir = distance < 0 ? -1 : 1
        var j = cp * Track.splineSteps % m
        var left = abs(distance)
        for _ in 0..<m {
            let next = ((j + dir) % m + m) % m
            let seg = dense[j].distance(to: dense[next])
            if seg >= left, seg > 0 {
                let t = (dense[next] - dense[j]) * (1 / seg)
                return (dense[j] + t * left, t * Double(dir))
            }
            left -= seg
            j = next
        }
        return (dense[j], Vec2(1, 0))
    }

    /// Signed distance along the road from control point `cp` to the point of the road
    /// nearest `w`, looking no further than `window` either way.
    private func roadDistance(fromPoint cp: Int, to w: Vec2, window: Double, dense: [Vec2]) -> Double {
        let m = dense.count
        guard m > 2 else { return 0 }
        let start = cp * Track.splineSteps % m
        var best = 0.0, bestD = Double.infinity
        for dir in [-1, 1] {
            var j = start, along = 0.0
            while along <= window {
                let d = dense[j].distance(to: w)
                if d < bestD { bestD = d; best = along * Double(dir) }
                let next = ((j + dir) % m + m) % m
                along += dense[j].distance(to: dense[next])
                j = next
                if j == start { break }
            }
        }
        return best
    }

    /// Handles at the ends of the selected bridge's deck: drag them along the road to stretch
    /// or shorten it.
    private func deckEndHandles() -> [(end: BridgeEnd, position: Vec2, normal: Vec2, half: Double)] {
        guard tool == .select || tool == .bridge, case let .point(i) = selection,
              let k = def.bridges.firstIndex(where: { $0.controlPoint == i }) else { return [] }
        let dense = Track.centerline(through: def.controlPoints)
        // Decks keep the width the road has at the bridge point.
        let half = def.roadWidth(atPoint: i) / 2 + def.curbWidth + 6
        return BridgeEnd.allCases.compactMap { end in
            guard let e = deckExtent(bridge: k, end) else { return nil }
            let r = roadPosition(fromPoint: i, distance: Double(end.sign) * e, dense: dense)
            return (end, r.position, r.tangent.perp, half)
        }
    }

    private func deckHandle(at w: Vec2) -> BridgeEnd? {
        let tol = tolerance(8)
        return deckEndHandles().first { $0.position.distance(to: w) < tol }?.end
    }

    /// Stretches bridge `k` over crossing `x` if the crossing is on its road a little past
    /// one of its deck ends. Returns whether it did.
    private func stretchBridge(over x: RoadCrossing, in built: Track) -> Bool {
        let limit = EditorLimits.bridgeEnd.upperBound
        var best: (k: Int, end: BridgeEnd, length: Double, gap: Double)?
        for (bi, b) in built.bridges.enumerated() {
            guard let k = def.bridges.firstIndex(where: { $0.controlPoint == b.controlPoint }),
                  let e = built.extent(toCover: x, bridge: bi, maxEnd: limit) else { continue }
            let current = e.end == .back ? -b.deckStart : b.deckEnd
            let gap = e.length - current
            guard gap <= EditorLimits.bridgeStretchGap, gap < (best?.gap ?? .infinity) else { continue }
            best = (k, e.end, e.length, gap)
        }
        guard let best else { return false }
        let length = min((best.length / 2).rounded(.up) * 2, limit)
        perform { $0.bridges[best.k].setExtent(length, best.end) }
        select(.point(def.bridges[best.k].controlPoint))
        flash("Stretched the bridge at road point \(def.bridges[best.k].controlPoint + 1) over this road too")
        return true
    }

    /// Whether a control point sets its own width.
    private func hasOwnWidth(_ i: Int) -> Bool {
        def.pointWidths.indices.contains(i) && def.pointWidths[i] != nil
    }

    private func computeHover(at p: CGPoint) -> Hover {
        guard !isOverUI(p) else { return .none }
        let w = toWorld(p)
        if let e = deckHandle(at: w) { return .deckHandle(e) }
        switch tool {
        case .select:
            if let s = widthHandle(at: w) { return .widthHandle(side: s) }
            if let h = handle(at: w) { return .handle(h) }
            if let h = objectHandle(at: w) { return .objectHandle(h) }
            if let v = lineVertex(at: w) { return .lineVertex(v) }
            if let i = pointIndex(at: w) { return .point(i) }
            if let i = objectIndex(at: w) { return .object(i) }
            if let i = lineIndex(at: w) { return .line(i) }
            if let i = patchIndex(at: w) { return .patch(i) }
        case .line:
            if drawingLine != nil { return .none }
            if let v = lineVertex(at: w) { return .lineVertex(v) }
            if let i = lineIndex(at: w) { return .line(i) }
        case .object:
            if let h = objectHandle(at: w) { return .objectHandle(h) }
            if let i = objectIndex(at: w) { return .object(i) }
        case .road:
            if let s = widthHandle(at: w) { return .widthHandle(side: s) }
            if let i = pointIndex(at: w) { return .point(i) }
            let pos = EditorLimits.clampToMap(snap(w))
            return .insert(index: def.insertionIndex(for: pos), position: pos)
        case .patch:
            if let h = handle(at: w) { return .handle(h) }
            if let i = patchIndex(at: w) { return .patch(i) }
        case .bridge:
            if let i = crossingIndex(at: w) { return .crossing(i) }
        }
        return .none
    }

    // MARK: Pointer input (also driven directly by the debug harness)

    func pointerDown(at p: CGPoint) {
        let hit = button(at: p)
        if editingName, hit == nil || hit?.tip != Self.nameFieldTip { endNameEditing() }
        if let hit { return hit.action() }
        if isOverUI(p) { return }

        let w = toWorld(p)
        dragOrigin = p
        dragMoved = false
        if spaceHeld { return beginPan(at: p) }
        if let e = deckHandle(at: w), case let .point(i) = selection,
           let k = def.bridges.firstIndex(where: { $0.controlPoint == i }) {
            drag = .deckEnd(bridge: k, end: e)
            return
        }
        if widthHandle(at: w) != nil, case let .point(i) = selection {
            drag = .width(index: i, normal: pointNormal(i))
            return
        }

        switch tool {
        case .select:
            if let h = handle(at: w), case let .patch(i) = selection {
                drag = .handle(index: i, handle: h, original: def.patches[i].shape)
            } else if let h = objectHandle(at: w), case let .object(i) = selection {
                drag = .objectHandle(index: i, handle: h, original: def.objects[i])
            } else if let v = lineVertex(at: w), case let .line(i) = selection {
                drag = .lineVertex(index: i, vertex: v)
            } else if let i = pointIndex(at: w) {
                select(.point(i))
                drag = .point(index: i, grab: def.controlPoints[i] - w)
            } else if let i = objectIndex(at: w) {
                select(.object(i))
                drag = .object(index: i, grab: def.objects[i].position - w)
            } else if let i = lineIndex(at: w) {
                select(.line(i))
                drag = .line(index: i, start: w, original: def.lines[i])
            } else if let i = patchIndex(at: w) {
                select(.patch(i))
                drag = .patch(index: i, start: w, original: def.patches[i].shape)
            } else {
                select(.none)
                beginPan(at: p)
            }
        case .road:
            if let i = pointIndex(at: w) {
                select(.point(i))
                drag = .point(index: i, grab: def.controlPoints[i] - w)
            } else {
                // Adding the point and dragging it into place is one undo step.
                let pos = EditorLimits.clampToMap(snap(w))
                let index = def.insertionIndex(for: pos)
                closeChange()
                performContinuing { $0.insertControlPoint(pos, at: index) }
                select(.point(index))
                drag = .point(index: index, grab: pos - w)
                dragMoved = true
            }
        case .patch:
            if let h = handle(at: w), case let .patch(i) = selection {
                drag = .handle(index: i, handle: h, original: def.patches[i].shape)
            } else if let i = patchIndex(at: w) {
                select(.patch(i))
                drag = .patch(index: i, start: w, original: def.patches[i].shape)
            } else if def.patches.count >= EditorLimits.maxPatches {
                flash("That's a lot of patches. Delete some before adding more.")
            } else {
                select(.none)
                drag = .create(start: snap(w))
                pendingPatch = nil
            }
        case .bridge:
            bridgeClick(at: w)
        case .line:
            lineClick(at: w)
        case .object:
            if let h = objectHandle(at: w), case let .object(i) = selection {
                drag = .objectHandle(index: i, handle: h, original: def.objects[i])
            } else if let i = objectIndex(at: w) {
                select(.object(i))
                drag = .object(index: i, grab: def.objects[i].position - w)
            } else if def.objects.count >= EditorLimits.maxObjects {
                flash("That's a lot of objects. Delete some before adding more.")
            } else {
                // Placing the object and dragging it into place is one undo step.
                let object = newObject(at: EditorLimits.clampToMap(snap(w)))
                closeChange()
                performContinuing { $0.objects.append(object) }
                select(.object(def.objects.count - 1))
                drag = .object(index: def.objects.count - 1, grab: object.position - w)
                dragMoved = true
            }
        }
    }

    private func lineClick(at w: Vec2) {
        let pos = EditorLimits.clampToMap(snap(w))
        if let k = drawingLine {
            let points = def.lines[k].points
            if let last = points.last, last.distance(to: w) < tolerance(7) { return finishLine() }
            guard points.count < EditorLimits.maxLinePoints else {
                finishLine()
                return flash("That line has as many points as it can take")
            }
            // Adding the point and dragging it into place is one undo step.
            closeChange()
            performContinuing { $0.lines[k].points.append(pos) }
            drag = .lineVertex(index: k, vertex: points.count)
            return
        }
        if let v = lineVertex(at: w), case let .line(i) = selection {
            drag = .lineVertex(index: i, vertex: v)
        } else if let i = lineIndex(at: w) {
            select(.line(i))
            drag = .line(index: i, start: w, original: def.lines[i])
        } else if def.lines.count >= EditorLimits.maxLines {
            flash("That's a lot of lines. Delete some before adding more.")
        } else {
            // Start with the second point on the first; dragging pulls it out into a segment.
            closeChange()
            performContinuing { $0.lines.append(PaintLine(points: [pos, pos], width: lineWidth, color: lineColor)) }
            let k = def.lines.count - 1
            drawingLine = k
            select(.line(k))
            drag = .lineVertex(index: k, vertex: 1)
        }
    }

    /// Stops adding points to the line being drawn. A line with a single point is dropped.
    private func finishLine() {
        guard let k = drawingLine else { return }
        drawingLine = nil
        if def.lines.indices.contains(k), def.lines[k].points.count < 2 {
            perform { $0.lines.remove(at: k) }
            select(.none)
        } else {
            flash("Line finished")
        }
        refreshAll()
    }

    /// A new object of the current kind. Buildings turn to face the nearest road; ramps line
    /// up with it, launching cars the way the race goes.
    private func newObject(at p: Vec2) -> TrackObject {
        if objectKind.isTree {
            return TrackObject(objectKind, at: p, size: Vec2(treeSize, treeSize), angle: objectHash(p), solid: treeSolid)
        }
        return TrackObject(objectKind, at: p, angle: objectKind.isRamp ? raceAngle(at: p) : facingAngle(at: p))
    }

    /// Angle that points a ramp's jump the way the race runs on the road nearest `p`.
    private func raceAngle(at p: Vec2) -> Double {
        let dense = Track.centerline(through: def.controlPoints)
        let m = dense.count
        guard m > 2, let i = dense.indices.min(by: { dense[$0].distance(to: p) < dense[$1].distance(to: p) }) else { return 0 }
        let t = (dense[(i + 1) % m] - dense[(i - 1 + m) % m]).normalized
        return snapAngle(atan2(-t.x, t.y), step: 5)
    }

    /// Which side of an object its turn handle is on: in front of buildings, past a ramp's
    /// lip so it points the way cars jump.
    private func turnHandleSide(_ o: TrackObject) -> Double { o.kind.isRamp ? 1 : -1 }

    /// Random-looking but stable canopy turn for a new tree.
    private func objectHash(_ p: Vec2) -> Double {
        hash01(Int(p.x), Int(p.y), 77) * 2 * .pi
    }

    /// Angle that turns a building's front toward the road nearest `p`, in 5 degree steps.
    private func facingAngle(at p: Vec2) -> Double {
        let dense = Track.centerline(through: def.controlPoints)
        guard let q = dense.min(by: { $0.distance(to: p) < $1.distance(to: p) }) else { return 0 }
        let d = q - p
        return snapAngle(atan2(d.x, -d.y), step: 5)
    }

    private func snapAngle(_ a: Double, step degrees: Double) -> Double {
        let s = degrees * .pi / 180
        return wrapAngle((a / s).rounded() * s)
    }

    func pointerDragged(to p: CGPoint) {
        guard let drag else { return }
        if !dragMoved {
            guard hypot(p.x - dragOrigin.x, p.y - dragOrigin.y) > 2 else { return }
            dragMoved = true
        }
        let w = toWorld(p)
        switch drag {
        case let .pan(start, startOffset):
            offset = CGPoint(x: startOffset.x + p.x - start.x, y: startOffset.y + p.y - start.y)
            applyView()
        case let .point(i, grab):
            let pos = EditorLimits.clampToMap(snap(w + grab))
            performContinuing { $0.controlPoints[i] = pos }
        case let .patch(i, start, original):
            let center = snap(original.center + (w - start))
            let moved = original.translated(by: center - original.center)
            performContinuing { $0.patches[i].shape = moved }
        case let .handle(i, h, original):
            let resized = resize(original, handle: h, to: snap(w))
            performContinuing { $0.patches[i].shape = resized }
        case let .create(start):
            pendingPatch = patchShape(from: start, to: snap(w))
            refreshOverlay()
        case let .width(i, normal):
            let r = EditorLimits.roadWidth
            let half = abs((w - def.controlPoints[i]).dot(normal))
            let step = snapToGrid ? EditorScene.gridStep : 2
            let width = clamp((half * 2 / step).rounded() * step, r.lowerBound, r.upperBound)
            performContinuing { $0.setRoadWidth(width, atPoint: i) }
            refreshStatus(cursor: w)
            return flash("Road width here: \(Int(width))")
        case let .deckEnd(k, end):
            guard def.bridges.indices.contains(k) else { break }
            let r = EditorLimits.bridgeEnd
            let cp = def.bridges[k].controlPoint
            let along = roadDistance(fromPoint: cp, to: w, window: r.upperBound + 40,
                                     dense: Track.centerline(through: def.controlPoints))
            let step = snapToGrid ? EditorScene.gridStep : 2
            let length = clamp((along * Double(end.sign) / step).rounded() * step, r.lowerBound, r.upperBound)
            performContinuing { $0.bridges[k].setExtent(length, end) }
            refreshStatus(cursor: w)
            return flash("Deck \(end == .back ? "starts" : "ends") \(Int(length)) \(end == .back ? "before" : "after") the bridge point")
        case let .line(i, start, original):
            guard let first = original.points.first else { break }
            let moved = original.translated(by: snap(first + (w - start)) - first)
            performContinuing { $0.lines[i] = moved }
        case let .lineVertex(i, v):
            let pos = EditorLimits.clampToMap(snap(w))
            performContinuing { $0.lines[i].points[v] = pos }
        case let .object(i, grab):
            let pos = EditorLimits.clampToMap(snap(w + grab))
            performContinuing { $0.objects[i].position = pos }
        case let .objectHandle(i, h, original):
            let changed = adjust(original, handle: h, to: w)
            performContinuing { $0.objects[i] = changed }
            if h == .rotate {
                refreshStatus(cursor: w)
                let deg = Int((changed.angle * 180 / .pi).rounded())
                return flash("Facing \((deg % 360 + 360) % 360)°")
            }
        }
        refreshStatus(cursor: w)
    }

    /// An object with one of its handles dragged to `w`.
    private func adjust(_ o: TrackObject, handle h: ObjectHandle, to w: Vec2) -> TrackObject {
        var o = o
        switch h {
        case .radius:
            let r = EditorLimits.treeSize
            let d = clamp((o.position.distance(to: w) * 2).rounded(), r.lowerBound, r.upperBound)
            o.size = Vec2(d, d)
        case .corner:
            let l = o.local(w), step = snapToGrid ? EditorScene.gridStep : 2
            let lr = EditorLimits.buildingLength, dr = EditorLimits.buildingDepth
            o.size = Vec2(clamp((abs(l.x) * 2 / step).rounded() * step, lr.lowerBound, lr.upperBound),
                          clamp((abs(l.y) * 2 / step).rounded() * step, dr.lowerBound, dr.upperBound))
        case .rotate:
            // Direction the object's front (local -y) should face.
            let d = (w - o.position) * -turnHandleSide(o)
            guard d.lengthSquared > 1 else { return o }
            o.angle = snapAngle(atan2(d.x, -d.y), step: snapToGrid ? 15 : 5)
        }
        return o
    }

    func pointerUp(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        if case let .create(start) = d {
            let shape = dragMoved ? (pendingPatch ?? defaultPatchShape(at: start)) : defaultPatchShape(at: start)
            pendingPatch = nil
            let onDeck = currentTrack.deck(x: Int(floor(start.x)), y: Int(floor(start.y))) != nil
            perform { $0.patches.append(Patch(patchSurface, shape, coversRoad: patchCoversRoad, onDeck: onDeck)) }
            select(.patch(def.patches.count - 1))
        }
        // A click that didn't drag a new line point out leaves it on the previous point: drop it.
        if case let .lineVertex(k, v) = d, drawingLine == k, def.lines.indices.contains(k), v > 0,
           def.lines[k].points.indices.contains(v), def.lines[k].points[v] == def.lines[k].points[v - 1] {
            performContinuing { $0.lines[k].points.remove(at: v) }
        }
        closeChange()
        hover = computeHover(at: p)
        refreshAll()
    }

    /// Right-click (or Control-click): delete what's under the mouse.
    func secondaryClick(at p: CGPoint) {
        guard !isOverUI(p) else { return }
        let w = toWorld(p)
        if drawingLine != nil { return finishLine() }
        if tool == .bridge, let x = crossingIndex(at: w) {
            if let k = def.bridgeIndex(at: crossings[x]) {
                perform { $0.bridges.remove(at: k) }
                return flash("Bridge removed")
            }
            if let k = coveringBridge(crossings[x], in: currentTrack) {
                select(.point(def.bridges[k].controlPoint))
                return flash("This crossing is part of a longer bridge. Drag its deck ends to leave it out, or right-click its own crossing to remove it.")
            }
        }
        // A point of the selected line goes first, then the whole line.
        if let v = lineVertex(at: w), case let .line(i) = selection, tool == .select || tool == .line {
            guard def.lines[i].points.count > 2 else { return deleteLine(i) }
            perform { $0.lines[i].points.remove(at: v) }
            return flash("Line point deleted")
        }
        switch tool {
        case .line:
            if let i = lineIndex(at: w) { return deleteLine(i) }
            return select(.none)
        case .object:
            if let i = objectIndex(at: w) { return deleteObject(i) }
            return select(.none)
        default:
            break
        }
        let pointFirst = tool != .patch
        if pointFirst, let i = pointIndex(at: w) { return deletePoint(i) }
        if tool == .select, let i = objectIndex(at: w) { return deleteObject(i) }
        if tool == .select, let i = lineIndex(at: w) { return deleteLine(i) }
        if let i = patchIndex(at: w) {
            perform { $0.patches.remove(at: i) }
            select(.none)
            return flash("Patch deleted")
        }
        if let i = pointIndex(at: w) { return deletePoint(i) }
        select(.none)
    }

    private func beginPan(at p: CGPoint) {
        drag = .pan(start: p, offset: offset)
    }

    func pointerMoved(to p: CGPoint) {
        let b = button(at: p)
        if b !== hoveredButton {
            hoveredButton?.isHovered = false
            b?.isHovered = true
            hoveredButton = b
        }
        let h = computeHover(at: p)
        cursorWorld = isOverUI(p) ? nil : toWorld(p)
        // The line rubber band and object ghost follow the mouse.
        let followsCursor = drawingLine != nil || (tool == .object && h == .none)
        if h != hover || followsCursor {
            hover = h
            refreshOverlay()
        }
        refreshStatus(cursor: cursorWorld)
    }

    // MARK: Tool actions

    private func bridgeClick(at w: Vec2) {
        guard let xi = crossingIndex(at: w) else {
            if let i = pointIndex(at: w), def.bridges.contains(where: { $0.controlPoint == i }) {
                return select(.point(i))
            }
            return flash("Bridges go where the road crosses itself. Drag road points so it crosses first.")
        }
        let x = crossings[xi]
        // Where the decks end right now decides between swapping, stretching and adding.
        let built = currentTrack
        if let k = def.bridgeIndex(at: x) {
            let covered = coveredCount(bridge: k, in: built)
            guard covered <= 1 else {
                select(.point(def.bridges[k].controlPoint))
                return flash("This bridge goes over \(covered) roads. Only a bridge over one road can swap: shorten it first.")
            }
            perform { $0.flipBridge(k, at: x) }
            select(.point(def.bridges[k].controlPoint))
            flash("Swapped which road goes over")
        } else if let k = coveringBridge(x, in: built) {
            select(.point(def.bridges[k].controlPoint))
            flash("This crossing is under the bridge at road point \(def.bridges[k].controlPoint + 1). Drag its deck ends to change what it covers.")
        } else if stretchBridge(over: x, in: built) {
            return
        } else if def.bridges.count >= EditorLimits.maxBridges {
            flash("That's the most bridges a track can have")
        } else {
            var k = 0
            perform { k = $0.addBridge(at: x, over: x.passA) }
            select(.point(def.bridges[k].controlPoint))
            flash("Bridge added. Click it again to swap which road goes over.")
        }
    }

    private func deletePoint(_ i: Int) {
        guard def.controlPoints.count > TrackDefinition.minControlPoints else {
            return flash("A track needs at least \(TrackDefinition.minControlPoints) road points")
        }
        let hadBridge = def.bridges.contains { $0.controlPoint == i }
        perform { $0.removeControlPoint(at: i) }
        select(.none)
        flash(hadBridge ? "Road point and its bridge deleted" : "Road point deleted")
    }

    private func deleteSelection() {
        switch selection {
        case let .point(i): deletePoint(i)
        case let .patch(i):
            perform { $0.patches.remove(at: i) }
            select(.none)
        case let .line(i): deleteLine(i)
        case let .object(i): deleteObject(i)
        case .none: break
        }
    }

    private func deleteLine(_ i: Int) {
        guard def.lines.indices.contains(i) else { return }
        drawingLine = nil
        perform { $0.lines.remove(at: i) }
        select(.none)
        flash("Line deleted")
    }

    private func deleteObject(_ i: Int) {
        guard def.objects.indices.contains(i) else { return }
        let name = def.objects[i].kind.displayName
        perform { $0.objects.remove(at: i) }
        select(.none)
        flash("\(name) deleted")
    }

    /// Copies the selected patch, line or object a little down and to the right.
    private func duplicateSelection() {
        let offset = Vec2(14, -14)
        switch selection {
        case let .patch(i) where def.patches.count < EditorLimits.maxPatches:
            var copy = def.patches[i]
            copy.shape = copy.shape.translated(by: offset)
            perform { $0.patches.append(copy) }
            select(.patch(def.patches.count - 1))
        case let .line(i) where def.lines.count < EditorLimits.maxLines:
            finishLine()
            guard def.lines.indices.contains(i) else { return }
            let copy = def.lines[i].translated(by: offset)
            perform { $0.lines.append(copy) }
            select(.line(def.lines.count - 1))
        case let .object(i) where def.objects.count < EditorLimits.maxObjects:
            var copy = def.objects[i]
            copy.position = EditorLimits.clampToMap(copy.position + (copy.kind.isTree ? offset : Vec2(0, -copy.size.y - 6)))
            perform { $0.objects.append(copy) }
            select(.object(def.objects.count - 1))
        default:
            break
        }
    }

    private func updateLine(_ i: Int, _ body: @escaping (inout PaintLine) -> Void) {
        guard def.lines.indices.contains(i) else { return }
        perform { body(&$0.lines[i]) }
    }

    private func updateObject(_ i: Int, _ body: @escaping (inout TrackObject) -> Void) {
        guard def.objects.indices.contains(i) else { return }
        perform { body(&$0.objects[i]) }
    }

    private func nudge(_ d: Vec2) {
        switch selection {
        case let .point(i):
            perform { $0.controlPoints[i] = EditorLimits.clampToMap($0.controlPoints[i] + d) }
        case let .patch(i):
            perform { $0.patches[i].shape = $0.patches[i].shape.translated(by: d) }
        case let .line(i):
            perform { $0.lines[i] = $0.lines[i].translated(by: d) }
        case let .object(i):
            perform { $0.objects[i].position = EditorLimits.clampToMap($0.objects[i].position + d) }
        case .none:
            offset = CGPoint(x: offset.x - CGFloat(d.x) * 4, y: offset.y - CGFloat(d.y) * 4)
            applyView()
        }
    }

    private func updatePatch(_ i: Int, _ body: @escaping (inout Patch) -> Void) {
        guard def.patches.indices.contains(i) else { return }
        perform { body(&$0.patches[i]) }
    }

    private func patchShape(from a: Vec2, to b: Vec2) -> PatchShape {
        switch patchKind {
        case .circle:
            return .circle(center: a, radius: max(3, a.distance(to: b).rounded()))
        case .rect:
            return .rect(origin: Vec2(min(a.x, b.x), min(a.y, b.y)), size: Vec2(max(3, abs(b.x - a.x)), max(3, abs(b.y - a.y))))
        case .capsule:
            return .capsule(from: a, to: b, radius: capsuleRadius)
        }
    }

    private func defaultPatchShape(at c: Vec2) -> PatchShape {
        switch patchKind {
        case .circle: return .circle(center: c, radius: 30)
        case .rect: return .rect(origin: c - Vec2(30, 30), size: Vec2(60, 60))
        case .capsule: return .capsule(from: c - Vec2(40, 0), to: c + Vec2(40, 0), radius: capsuleRadius)
        }
    }

    private func resize(_ shape: PatchShape, handle h: PatchHandle, to w: Vec2) -> PatchShape {
        let maxSize = EditorLimits.patchSize.upperBound
        switch (shape, h) {
        case let (.circle(c, _), .radius):
            return .circle(center: c, radius: clamp(w.distance(to: c).rounded(), 3, maxSize / 2))
        case let (.rect(o, s), .corner(k)):
            let corners = [o, o + Vec2(s.x, 0), o + s, o + Vec2(0, s.y)]
            let opposite = corners[(k + 2) % 4]
            return .rect(origin: Vec2(min(w.x, opposite.x), min(w.y, opposite.y)),
                         size: Vec2(max(3, abs(w.x - opposite.x)), max(3, abs(w.y - opposite.y))))
        case let (.capsule(a, b, r), .end(k)):
            return k == 0 ? .capsule(from: w, to: b, radius: r) : .capsule(from: a, to: w, radius: r)
        case let (.capsule(a, b, _), .radius):
            let r = clamp(abs((w - (a + b) * 0.5).dot(capsuleNormal(a, b))).rounded(), 2, 200)
            return .capsule(from: a, to: b, radius: r)
        default:
            return shape
        }
    }

    #if DEBUG
    /// Clicks the first enabled, visible button with this title, going through normal hit testing.
    @discardableResult
    func debugClick(_ title: String) -> Bool {
        let roots: [SKNode] = modal.map { [$0] } ?? [toolbar, panel]
        var target: EditorButton?
        for root in roots where target == nil {
            root.enumerateChildNodes(withName: "//*") { node, stop in
                if let b = node as? EditorButton, b.title == title, b.isEnabled {
                    target = b
                    stop.pointee = true
                }
            }
        }
        guard let b = target, let parent = b.parent else {
            print("editor test: no button \"\(title)\"")
            return false
        }
        let p = parent.convert(b.position, to: self)
        pointerMoved(to: p)
        pointerDown(at: p)
        pointerUp(at: p)
        return true
    }

    /// Drags on the map between two world positions.
    func debugDrag(from a: Vec2, to b: Vec2, steps: Int = 8) {
        let pa = toScene(a)
        pointerMoved(to: pa)
        pointerDown(at: pa)
        for k in 1...steps {
            let t = Double(k) / Double(steps)
            pointerDragged(to: toScene(a + (b - a) * t))
        }
        pointerUp(at: toScene(b))
    }

    /// World position of the selected point's left road edge handle.
    var debugWidthHandle: Vec2? { widthHandles().first?.position }

    /// World position of one deck end handle of the selected bridge.
    func debugDeckHandle(_ end: BridgeEnd) -> Vec2? { deckEndHandles().first { $0.end == end }?.position }

    /// Opens a definition as if picked in the browser.
    func debugLoad(_ d: TrackDefinition) { load(d) }

    /// Clicks on the map at a world position.
    func debugMapClick(_ w: Vec2) {
        let p = toScene(w)
        pointerMoved(to: p)
        pointerDown(at: p)
        pointerUp(at: p)
    }

    var debugFlash: String { flashText ?? "" }

    /// Crossings under some bridge's deck in the current build.
    var debugCoveredCrossings: Int { crossings.filter { def.bridgeIndex(at: $0) != nil || coveringBridge($0) != nil }.count }

    var debugSummary: String {
        "\(def.name): \(def.controlPoints.count) points, \(def.patches.count) patches, \(def.bridges.count) bridges "
            + "\(def.lines.count) lines \(def.lines.map(\.points.count)) points, "
            + "\(def.objects.count) objects \(def.objects.map { "\($0.kind.rawValue)\($0.isSolid ? "" : "(deco)")" }), "
            + "(over at \(def.bridges.map(\.controlPoint)), ends \(def.bridges.map { [$0.back, $0.ahead].map { $0.map { "\(Int($0))" } ?? "auto" } })), widths \(def.pointWidths.map { $0.map { Int($0) } }), "
            + "theme \(def.theme.rawValue), dirty \(isDirty), "
            + "undo \(undoStack.count), issues \(isCurrent ? "\(issues.map(\.message))" : "pending"), "
            + "tool \(tool.title), selection \(selection)"
    }
    #endif

    func setTool(_ t: Tool) {
        if t != .line { finishLine() }
        tool = t
        // Keep the selection only if the new tool works on it.
        switch (t, selection) {
        case (_, .none), (.select, _), (.road, .point), (.road, .patch), (.bridge, .point),
             (.patch, .patch), (.line, .line), (.object, .object):
            break
        default:
            selection = .none
        }
        hover = .none
        flashText = nil
        refreshAll()
    }

    func select(_ s: Selection) {
        guard s != selection else { return }
        selection = s
        if case let .patch(i) = s, def.patches.indices.contains(i) {
            // New patches pick up the look of the last one touched.
            let p = def.patches[i]
            patchSurface = p.surface
            patchKind = p.shape.kind
            patchCoversRoad = p.coversRoad
            if case let .capsule(_, _, r) = p.shape { capsuleRadius = r }
        }
        if case let .line(i) = s, def.lines.indices.contains(i) {
            lineColor = def.lines[i].color
            lineWidth = def.lines[i].width
        }
        if case let .object(i) = s, def.objects.indices.contains(i) {
            let o = def.objects[i]
            objectKind = o.kind
            if o.kind.isTree {
                treeSize = o.size.x
                treeSolid = o.solid
            }
        }
        refreshOverlay()
        refreshPanel()
    }

    private func toggleGrid() {
        snapToGrid.toggle()
        refreshAll()
    }

    private func togglePanel() {
        panelVisible.toggle()
        refreshAll()
    }

    // MARK: File actions

    private func confirmDiscard(_ then: @escaping () -> Void) {
        endNameEditing()
        guard isDirty else { return then() }
        showConfirm("\"\(def.name)\" has unsaved changes. Discard them?", confirm: "Discard", action: then)
    }

    private func newTrack() {
        confirmDiscard { [unowned self] in
            load(.blank(id: TrackStore.newID()))
            flash("New track. Drag the road points to shape it.")
        }
    }

    private func openTrack() {
        confirmDiscard { [unowned self] in showOpenBrowser(page: 0, confirmDelete: nil) }
    }

    private static let sharedTrackType = UTType(importedAs: "com.slideways.track", conformingTo: .json)

    private func importTrack() {
        let panel = NSOpenPanel()
        panel.title = "Import Track"
        panel.allowedContentTypes = [Self.sharedTrackType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        Input.shared.releaseAll()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTrack(at: url)
    }

    func importTrack(at url: URL) {
        do {
            let track = try TrackStore.readShared(at: url)
            confirmDiscard { [unowned self] in showImportPreview(track) }
        } catch {
            showMessage("Couldn't import the track: \(error.localizedDescription)")
        }
    }

    private func showImportPreview(_ track: TrackDefinition) {
        let box = beginModal(size: CGSize(width: 440, height: 350))
        let title = makeLabel(String(track.name.prefix(40)), size: 16, color: .accent, align: .center)
        if title.frame.width > 384 { title.fontSize *= 384 / title.frame.width }
        title.position = CGPoint(x: 0, y: 140)
        title.zPosition = 2
        box.addChild(title)
        let preview = SKSpriteNode(texture: SKTexture(cgImage: TrackRenderer.makeQuickPreview(for: track)))
        preview.size = CGSize(width: 384, height: 240)
        preview.position = CGPoint(x: 0, y: 0)
        preview.zPosition = 2
        box.addChild(preview)
        dialogButton("Cancel", at: CGPoint(x: -65, y: -145), in: box) { [unowned self] in closeModal() }
        dialogButton("Import", at: CGPoint(x: 65, y: -145), in: box, selected: true) { [unowned self] in
            do {
                try TrackStore.save(track)
                TrackLibrary.shared.reload()
                closeModal()
                load(track)
                flash("Imported \"\(track.name)\"")
            } catch {
                showMessage("Couldn't save the imported track: \(error.localizedDescription)")
            }
        }
    }

    private func exportTrack() {
        endNameEditing()
        do {
            let data = try TrackStore.exportData(def)
            let panel = NSSavePanel()
            panel.title = "Export Track"
            panel.allowedContentTypes = [Self.sharedTrackType]
            panel.nameFieldStringValue = TrackStore.exportFilename(for: def)
            Input.shared.releaseAll()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            closeModal()
            flash("Exported \"\(def.name)\"")
        } catch {
            showMessage("Couldn't export the track: \(error.localizedDescription)")
        }
    }

    private func save() {
        endNameEditing()
        let name = def.name.trimmingCharacters(in: .whitespaces)
        if name != def.name || name.isEmpty { def.name = name.isEmpty ? "Untitled" : name }
        do {
            try TrackStore.save(def)
        } catch {
            return showMessage("Couldn't save the track: \(error.localizedDescription)")
        }
        baseline = def
        TrackLibrary.shared.reload()
        coordinator.forgetTextures(for: def.id)
        flash("Saved \"\(def.name)\". It's in the race menu's track list.")
        refreshAll()
    }

    private func testDrive() {
        endNameEditing()
        coordinator.testDrive(def)
    }

    private func goToMenu() {
        confirmDiscard { [unowned self] in coordinator.closeEditor(selecting: isOnDisk ? def.id : nil) }
    }

    // MARK: Name editing

    private static let nameFieldTip = "Click to rename the track"

    private func beginNameEditing() {
        editingName = true
        closeChange()
        refreshPanel()
    }

    private func endNameEditing() {
        guard editingName else { return }
        editingName = false
        closeChange()
        refreshPanel()
        refreshToolbar()
    }

    private func typeIntoName(_ event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 53, 48:
            endNameEditing()
        case 51:
            guard !def.name.isEmpty else { return }
            performContinuing { $0.name.removeLast() }
        default:
            let allowed = (event.characters ?? "").filter { c in
                c.isLetter || c.isNumber || " -_'!&.,()#".contains(c)
            }
            guard !allowed.isEmpty else { return }
            let name = String((def.name + allowed).prefix(Self.maxNameLength))
            performContinuing { $0.name = name }
        }
        refreshPanel()
        refreshToolbar()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if editingName && !flags.contains(.command) { return typeIntoName(event) }
        if flags.contains(.command) {
            switch chars {
            case "z": flags.contains(.shift) ? redo() : undo()
            case "s": if modal == nil { flags.contains(.shift) ? exportTrack() : save() }
            case "o": if modal == nil { flags.contains(.shift) ? importTrack() : openTrack() }
            case "n": if modal == nil { newTrack() }
            case "d": duplicateSelection()
            default: super.keyDown(with: event)
            }
            return
        }
        if modal != nil {
            if event.keyCode == 53 { closeModal() }
            return
        }
        let step = flags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 36 where drawingLine != nil, 76 where drawingLine != nil:
            finishLine()
        case 53 where drawingLine != nil && drag == nil:
            finishLine()
        case 53:
            if drag != nil {
                drag = nil
                pendingPatch = nil
                closeChange()
                refreshOverlay()
            } else {
                select(.none)
            }
        case 49: spaceHeld = true
        case 51, 117: deleteSelection()
        case 48: togglePanel()
        case 123: nudge(Vec2(-step, 0))
        case 124: nudge(Vec2(step, 0))
        case 125: nudge(Vec2(0, -step))
        case 126: nudge(Vec2(0, step))
        default:
            switch chars {
            case "v", "1": setTool(.select)
            case "r", "2": setTool(.road)
            case "p", "3": setTool(.patch)
            case "b", "4": setTool(.bridge)
            case "l", "5": setTool(.line)
            case "o", "6": setTool(.object)
            case "g": toggleGrid()
            case "f": fitView()
            case "t": testDrive()
            case "=", "+": zoom(by: 1.25, around: CGPoint(x: 480, y: 300))
            case "-": zoom(by: 0.8, around: CGPoint(x: 480, y: 300))
            default: break
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        if event.modifierFlags.contains(.control) { return secondaryClick(at: p) }
        pointerDown(at: p)
    }

    override func mouseDragged(with event: NSEvent) { pointerDragged(to: event.location(in: self)) }
    override func mouseUp(with event: NSEvent) { pointerUp(at: event.location(in: self)) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(to: event.location(in: self)) }
    override func rightMouseDown(with event: NSEvent) { secondaryClick(at: event.location(in: self)) }

    override func otherMouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard !isOverUI(p) else { return }
        dragOrigin = p
        beginPan(at: p)
    }

    override func otherMouseDragged(with event: NSEvent) { pointerDragged(to: event.location(in: self)) }
    override func otherMouseUp(with event: NSEvent) { pointerUp(at: event.location(in: self)) }

    override func scrollWheel(with event: NSEvent) {
        let p = event.location(in: self)
        guard modal == nil, !isOverUI(p) else { return }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
            // Trackpad: two-finger scroll pans. Deltas are in view points.
            let viewScale = view.map { min($0.bounds.width / size.width, $0.bounds.height / size.height) } ?? 1
            offset.x += event.scrollingDeltaX / viewScale
            offset.y -= event.scrollingDeltaY / viewScale
            applyView()
        } else {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
            zoom(by: pow(1.12, dy), around: p)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = event.location(in: self)
        guard modal == nil, !isOverUI(p) else { return }
        zoom(by: 1 + event.magnification, around: p)
    }

    // MARK: Refresh

    private func refreshAll() {
        refreshToolbar()
        refreshPanel()
        refreshOverlay()
        refreshStatus()
    }

    private func refreshToolbar() {
        for (t, b) in toolButtons { b.isSelected = t == tool }
        undoButton.isEnabled = !undoStack.isEmpty
        redoButton.isEnabled = !redoStack.isEmpty
        gridButton.isSelected = snapToGrid
        panelButton.isSelected = panelVisible
        let name = def.name.isEmpty ? "Untitled" : def.name
        titleLabel.text = String(name.prefix(12)) + (isDirty ? " *" : "")
        titleLabel.fontColor = isDirty ? .accent : .white
    }

    private func flash(_ text: String) {
        flashText = text
        refreshStatus()
        statusLabel.removeAction(forKey: "flash")
        statusLabel.run(.sequence([.wait(forDuration: 4), .run { [weak self] in
            self?.flashText = nil
            self?.refreshStatus()
        }]), withKey: "flash")
    }

    private func refreshStatus(cursor: Vec2? = nil) {
        statusLabel.text = flashText ?? hoveredButton?.tip ?? tool.hint
        statusLabel.fontColor = flashText != nil ? .accent : .white
        var right = "zoom \(Int((zoom * 100).rounded()))%"
        if let c = cursor, c.x >= 0, c.y >= 0, c.x <= 960, c.y <= 600 {
            right = String(format: "x %.0f  y %.0f   ", c.x, c.y) + right
        }
        if snapToGrid { right = "grid   " + right }
        coordsLabel.text = right
    }

    // MARK: Overlay

    private func scenePath(_ shape: PatchShape) -> CGPath {
        switch shape {
        case let .circle(c, r):
            let s = toScene(c), rr = CGFloat(r) * zoom
            return CGPath(ellipseIn: CGRect(x: s.x - rr, y: s.y - rr, width: rr * 2, height: rr * 2), transform: nil)
        case let .rect(o, sz):
            let s = toScene(o)
            return CGPath(rect: CGRect(x: s.x, y: s.y, width: CGFloat(sz.x) * zoom, height: CGFloat(sz.y) * zoom), transform: nil)
        case let .capsule(a, b, r):
            let line = CGMutablePath()
            line.move(to: toScene(a))
            line.addLine(to: toScene(b))
            return line.copy(strokingWithWidth: CGFloat(r) * 2 * zoom, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
    }

    private func polyline(_ pts: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: pts)
        if closed { path.closeSubpath() }
        return path
    }

    @discardableResult
    private func addShape(_ path: CGPath, stroke: SKColor = .clear, width: CGFloat = 1, fill: SKColor = .clear,
                          z: CGFloat) -> SKShapeNode {
        let n = SKShapeNode(path: path)
        n.strokeColor = stroke
        n.lineWidth = width
        n.fillColor = fill
        n.zPosition = z
        n.isAntialiased = true
        overlay.addChild(n)
        return n
    }

    private func addDot(_ p: CGPoint, radius r: CGFloat, fill: SKColor, stroke: SKColor = .black, width: CGFloat = 1.5, z: CGFloat) {
        addShape(CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), transform: nil),
                 stroke: stroke, width: width, fill: fill, z: z)
    }

    private func addText(_ text: String, at p: CGPoint, size: CGFloat = 10, color: SKColor = .white, z: CGFloat) {
        let l = makeLabel(text, size: size, color: color, align: .center)
        l.position = p
        l.zPosition = z
        overlay.addChild(l)
    }

    private func refreshOverlay() {
        overlay.removeAllChildren()
        let origin = toScene(.zero)
        addShape(CGPath(rect: CGRect(x: origin.x, y: origin.y, width: 960 * zoom, height: 600 * zoom), transform: nil),
                 stroke: SKColor(white: 1, alpha: 0.3), z: 0)
        if snapToGrid { drawGrid() }

        let dense = Track.centerline(through: def.controlPoints)
        let densePts = dense.map(toScene)
        let theme = def.theme

        // Patches.
        let patchesActive = tool == .select || tool == .patch
        for (i, patch) in def.patches.enumerated() {
            let selected = selection == .patch(i), hovered = hover == .patch(i)
            let n = addShape(scenePath(patch.shape), stroke: selected ? .accent : EditorColors.outline(patch.surface, theme: theme),
                             width: selected ? 2 : hovered ? 1.8 : 1,
                             fill: selected || hovered ? SKColor(white: 1, alpha: 0.08) : .clear, z: 2)
            n.alpha = patchesActive || selected ? 1 : 0.3
        }
        if let pending = pendingPatch {
            addShape(scenePath(pending), stroke: .accent, width: 1.5,
                     fill: EditorColors.swatch(patchSurface, theme: theme).withAlphaComponent(0.5), z: 2)
        }

        drawLineOverlay()
        drawObjectOverlay()

        // Centerline with direction chevrons.
        addShape(polyline(densePts, closed: true), stroke: SKColor(white: 1, alpha: 0.6), width: 1.5, z: 3)
        let chevron = CGMutablePath()
        let n = densePts.count
        let size = clamp(5 * zoom, 3, 9)
        for k in stride(from: Track.splineSteps / 2, to: n, by: 28) {
            let a = densePts[(k - 1 + n) % n], b = densePts[(k + 1) % n], c = densePts[k]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let t = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len), nrm = CGPoint(x: -t.y, y: t.x)
            chevron.move(to: CGPoint(x: c.x - t.x * size + nrm.x * size, y: c.y - t.y * size + nrm.y * size))
            chevron.addLine(to: CGPoint(x: c.x + t.x * size * 0.4, y: c.y + t.y * size * 0.4))
            chevron.addLine(to: CGPoint(x: c.x - t.x * size - nrm.x * size, y: c.y - t.y * size - nrm.y * size))
        }
        addShape(chevron, stroke: SKColor(white: 1, alpha: 0.75), width: 1.5, z: 3)

        // Crossings and which road each bridge carries over.
        let selectedBridge: Int? = {
            guard case let .point(i) = selection else { return nil }
            return def.bridges.firstIndex { $0.controlPoint == i }
        }()
        if tool == .bridge || (tool == .select && selectedBridge != nil) {
            // Each deck as a band along the road it carries, from end to end.
            for k in def.bridges.indices where tool == .bridge || k == selectedBridge {
                let cp = def.bridges[k].controlPoint
                guard def.controlPoints.indices.contains(cp) else { continue }
                let fallback = def.roadWidth(atPoint: cp) / 2 + 20
                let back = deckExtent(bridge: k, .back) ?? fallback, ahead = deckExtent(bridge: k, .ahead) ?? fallback
                let count = max(2, Int((back + ahead) / 6))
                let pts = (0...count).map { s -> CGPoint in
                    let d = -back + (back + ahead) * Double(s) / Double(count)
                    return toScene(roadPosition(fromPoint: cp, distance: d, dense: dense).position)
                }
                let band = addShape(polyline(pts, closed: false),
                                    stroke: EditorColors.bridge.withAlphaComponent(k == selectedBridge ? 0.9 : 0.7),
                                    width: max(6, CGFloat(def.roadWidth(atPoint: cp)) * zoom * 0.35), z: 4)
                band.lineCap = .butt
            }
        }
        if tool == .bridge {
            for (i, x) in crossings.enumerated() {
                let c = toScene(x.point)
                let hovered = hover == .crossing(i)
                let bridged = def.bridgeIndex(at: x) != nil || coveringBridge(x) != nil
                let ring = CGPath(ellipseIn: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32), transform: nil)
                addShape(bridged ? ring : ring.copy(dashingWithPhase: 0, lengths: [4, 3]),
                         stroke: hovered ? .accent : .white, width: hovered ? 2.5 : 1.5, z: 4)
            }
        }

        // Deck end handles of the selected bridge: bars across the road with a square grip.
        for e in deckEndHandles() {
            let a = toScene(e.position + e.normal * e.half), b = toScene(e.position - e.normal * e.half)
            addShape(polyline([a, b], closed: false), stroke: SKColor.accent.withAlphaComponent(0.9), width: 2, z: 6)
            let s = toScene(e.position), r: CGFloat = hover == .deckHandle(e.end) ? 6 : 4.5
            addShape(squarePath(s, r), stroke: .black, width: 1, fill: .accent, z: 6)
        }

        // Handles of the selected patch.
        if case let .patch(i) = selection, def.patches.indices.contains(i) {
            for (h, p) in handles(of: def.patches[i].shape) {
                let s = toScene(p), r: CGFloat = hover == .handle(h) ? 5 : 4
                addShape(CGPath(rect: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2), transform: nil),
                         stroke: .black, width: 1, fill: .accent, z: 6)
            }
        }

        // Road points.
        let pointsActive = tool == .select || tool == .road
        let bridgePoints = Set(def.bridges.map(\.controlPoint))
        for (i, p) in def.controlPoints.enumerated() {
            let s = toScene(p)
            let selected = selection == .point(i), hovered = hover == .point(i)
            var r: CGFloat = pointsActive ? 5 : 3.5
            if selected || hovered { r += 2 }
            let color: SKColor = selected ? .accent : bridgePoints.contains(i) ? EditorColors.bridge : i == 0 ? .white : EditorColors.point
            // Points that set their own road width get a ring.
            if hasOwnWidth(i) {
                addDot(s, radius: r + 3, fill: .clear, stroke: SKColor(white: 1, alpha: pointsActive ? 0.85 : 0.4), width: 1.2, z: 5)
            }
            addDot(s, radius: r, fill: color, stroke: hovered ? .white : .black, width: hovered ? 2 : 1.5, z: 5)
            if !pointsActive && !selected { overlay.children.last?.alpha = 0.5 }
            if i == 0 { addText("START", at: CGPoint(x: s.x, y: s.y + 14), size: 9, z: 5) }
        }

        // Road edge handles of the selected point: drag them to set the width there.
        let edges = widthHandles()
        if edges.count == 2 {
            let a = toScene(edges[0].position), b = toScene(edges[1].position)
            addShape(polyline([a, b], closed: false).copy(dashingWithPhase: 0, lengths: [4, 3]),
                     stroke: SKColor.accent.withAlphaComponent(0.9), width: 1.2, z: 6)
            for e in edges {
                let s = toScene(e.position), r: CGFloat = hover == .widthHandle(side: e.side) ? 6.5 : 5
                let diamond = CGMutablePath()
                diamond.addLines(between: [CGPoint(x: s.x, y: s.y + r), CGPoint(x: s.x + r, y: s.y),
                                           CGPoint(x: s.x, y: s.y - r), CGPoint(x: s.x - r, y: s.y)])
                diamond.closeSubpath()
                addShape(diamond, stroke: .black, width: 1, fill: .accent, z: 6)
            }
        }

        // Where a click in the road tool would add a point.
        if case let .insert(index, pos) = hover {
            let count = def.controlPoints.count
            let a = toScene(def.controlPoints[(index - 1 + count) % count]), b = toScene(def.controlPoints[index % count])
            let s = toScene(pos)
            addShape(polyline([a, s, b], closed: false).copy(dashingWithPhase: 0, lengths: [5, 4]),
                     stroke: SKColor.accent.withAlphaComponent(0.8), width: 1.2, z: 4)
            addDot(s, radius: 5, fill: SKColor.accent.withAlphaComponent(0.4), stroke: .accent, z: 5)
        }

        // Problems found by the last build.
        if isCurrent {
            for issue in issues {
                guard let p = issue.position else { continue }
                let s = toScene(p)
                addDot(s, radius: 9, fill: EditorColors.issue, stroke: .white, width: 1.5, z: 7)
                addText("!", at: s, size: 12, color: .white, z: 8)
            }
        }
    }

    private func circlePath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    private func squarePath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    /// Outline around a paint line, a little wider than the paint.
    private func lineOutline(_ line: PaintLine) -> CGPath {
        let pts = line.points.map(toScene)
        let w = max(CGFloat(line.width) * zoom, 2) + 5
        guard pts.count > 1 else { return circlePath(pts.first ?? .zero, w / 2) }
        return polyline(pts, closed: false).copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    private func drawLineOverlay() {
        for (i, line) in def.lines.enumerated() where !line.points.isEmpty {
            let selected = selection == .line(i), hovered = hover == .line(i)
            guard selected || hovered || tool == .line else { continue }
            addShape(lineOutline(line), stroke: selected ? .accent : hovered ? .white : SKColor(white: 1, alpha: 0.35),
                     width: selected ? 1.5 : 1, fill: hovered && !selected ? SKColor(white: 1, alpha: 0.1) : .clear, z: 2.5)
        }
        // Rubber band from the last point to the mouse while drawing.
        if let k = drawingLine, def.lines.indices.contains(k), let last = def.lines[k].points.last, let c = cursorWorld, drag == nil {
            let band = polyline([toScene(last), toScene(EditorLimits.clampToMap(snap(c)))], closed: false)
            addShape(band.copy(dashingWithPhase: 0, lengths: [5, 4]), stroke: EditorColors.paint(lineColor).withAlphaComponent(0.9),
                     width: max(1.5, CGFloat(lineWidth) * zoom), z: 6)
        }
        // Points of the selected line. While drawing, the last one is ringed: click it to finish.
        guard case let .line(i) = selection, def.lines.indices.contains(i) else { return }
        let points = def.lines[i].points
        for (v, p) in points.enumerated() {
            let s = toScene(p), r: CGFloat = hover == .lineVertex(v) ? 5 : 4
            addShape(squarePath(s, r), stroke: .black, width: 1, fill: .accent, z: 6)
            if drawingLine == i, v == points.count - 1 {
                addShape(circlePath(s, 9), stroke: .accent, width: 1.5, z: 6)
            }
        }
    }

    /// Footprint of an object as drawn, in scene coordinates.
    private func objectPath(_ o: TrackObject) -> CGPath {
        if o.kind.isTree { return circlePath(toScene(o.position), CGFloat(o.radius) * zoom) }
        return polyline(o.corners.map(toScene), closed: true)
    }

    private func drawObjectOverlay() {
        for (i, o) in def.objects.enumerated() {
            let selected = selection == .object(i), hovered = hover == .object(i)
            guard selected || hovered || tool == .object else { continue }
            addShape(objectPath(o), stroke: selected ? .accent : hovered ? .white : SKColor(white: 1, alpha: 0.35),
                     width: selected ? 2 : hovered ? 1.8 : 1, fill: selected || hovered ? SKColor(white: 1, alpha: 0.08) : .clear, z: 2.6)
            // What cars actually hit on a solid tree.
            if o.kind.isTree, o.solid, selected || hovered {
                addShape(circlePath(toScene(o.position), CGFloat(o.trunkRadius) * zoom).copy(dashingWithPhase: 0, lengths: [3, 3]),
                         stroke: EditorColors.issue, width: 1.2, z: 2.7)
            }
        }

        // Placement ghost under the mouse.
        if tool == .object, hover == .none, drag == nil, let c = cursorWorld,
           c.x >= 0, c.y >= 0, c.x <= 960, c.y <= 600, def.objects.count < EditorLimits.maxObjects {
            let ghost = newObject(at: EditorLimits.clampToMap(snap(c)))
            addShape(objectPath(ghost).copy(dashingWithPhase: 0, lengths: [4, 3]), stroke: SKColor.accent.withAlphaComponent(0.7),
                     width: 1.2, z: 2.6)
        }

        guard case let .object(i) = selection, def.objects.indices.contains(i) else { return }
        let o = def.objects[i]
        if !o.kind.isTree {
            // Stem from the edge of the building or ramp to its turn handle.
            let side = turnHandleSide(o)
            let a = toScene(o.world(Vec2(0, side * o.size.y / 2)))
            let b = toScene(o.world(Vec2(0, side * (o.size.y / 2 + Self.rotateHandleGap))))
            addShape(polyline([a, b], closed: false), stroke: .accent, width: 1.2, z: 6)
        }
        for (h, p) in objectHandles(of: o) {
            let s = toScene(p), r: CGFloat = hover == .objectHandle(h) ? 5.5 : 4.5
            addShape(h == .rotate ? circlePath(s, r) : squarePath(s, r - 0.5), stroke: .black, width: 1, fill: .accent, z: 6)
        }
    }

    private func drawGrid() {
        var step = EditorScene.gridStep
        while CGFloat(step) * zoom < 7 { step *= 2 }
        let path = CGMutablePath()
        var x = 0.0
        while x <= 960 {
            path.move(to: toScene(Vec2(x, 0)))
            path.addLine(to: toScene(Vec2(x, 600)))
            x += step
        }
        var y = 0.0
        while y <= 600 {
            path.move(to: toScene(Vec2(0, y)))
            path.addLine(to: toScene(Vec2(960, y)))
            y += step
        }
        addShape(path, stroke: SKColor(white: 1, alpha: 0.09), width: 1, z: 0)
    }

    // MARK: Inspector

    private func refreshPanel() {
        hoveredButton = nil
        panel.removeAllChildren()
        panel.isHidden = !panelVisible
        guard panelVisible else {
            panelBounds = .zero
            return
        }
        let layout = PanelLayout(width: Layout.panelWidth)
        switch selection {
        case let .point(i): pointSection(layout, i)
        case let .patch(i): patchSection(layout, i)
        case let .line(i): lineSection(layout, i)
        case let .object(i): objectSection(layout, i)
        case .none:
            switch tool {
            case .patch: newPatchSection(layout)
            case .line: newLineSection(layout)
            case .object: newObjectSection(layout)
            default: trackSection(layout)
            }
        }
        let h = layout.height
        let bg = SKShapeNode(rect: CGRect(x: 0, y: -h, width: Layout.panelWidth, height: h), cornerRadius: 8)
        bg.fillColor = SKColor(white: 0.05, alpha: 0.92)
        bg.strokeColor = SKColor(white: 1, alpha: 0.2)
        bg.zPosition = -1
        panel.addChild(bg)
        panel.addChild(layout.node)
        let origin = CGPoint(x: 960 - Layout.panelWidth - 6, y: Layout.mapTop - 6)
        panel.position = origin
        panelBounds = CGRect(x: origin.x, y: origin.y - h, width: Layout.panelWidth, height: h)
    }

    private typealias Option = PanelLayout.Option

    private func trackSection(_ L: PanelLayout) {
        L.header("TRACK")
        L.field("Name", text: def.name + (editingName ? "_" : ""), focused: editingName, tip: Self.nameFieldTip) { [unowned self] in
            editingName ? endNameEditing() : beginNameEditing()
        }
        L.choices("Theme", TrackTheme.allCases.map { t in
            Option(title: t.rawValue.capitalized, selected: def.theme == t) { [unowned self] in perform { $0.theme = t } }
        })
        L.choices("Ground", [Surface.grass, .sand, .ice, .asphalt].map { s in
            Option(title: s.displayName, selected: def.background == s, tint: EditorColors.swatch(s, theme: def.theme),
                   tip: "Surface everywhere off the road") { [unowned self] in perform { $0.background = s } }
        }, perRow: 2)
        L.stepper("Road width", value: "\(Int(def.roadWidth))",
                  tip: "Road width everywhere except road points that set their own (select a point to change it)") { [unowned self] in
            perform { $0.roadWidth = clamp($0.roadWidth - 2, EditorLimits.roadWidth.lowerBound, EditorLimits.roadWidth.upperBound) }
        } plus: { [unowned self] in
            perform { $0.roadWidth = clamp($0.roadWidth + 2, EditorLimits.roadWidth.lowerBound, EditorLimits.roadWidth.upperBound) }
        }
        L.stepper("Curb width", value: "\(Int(def.curbWidth))", tip: "Width of curbs outside both road edges") { [unowned self] in
            perform { $0.curbWidth = max(EditorLimits.curbWidth.lowerBound, $0.curbWidth - 1) }
        } plus: { [unowned self] in
            perform { $0.curbWidth = min(EditorLimits.curbWidth.upperBound, $0.curbWidth + 1) }
        }
        L.stepper("Laps", value: "\(def.defaultLaps)", tip: "Suggested number of laps") { [unowned self] in
            perform { $0.defaultLaps = max(1, $0.defaultLaps - 1) }
        } plus: { [unowned self] in
            perform { $0.defaultLaps = min(20, $0.defaultLaps + 1) }
        }
        L.choices("Barrier", [
            Option(title: "Off", selected: def.barrierDistance == nil, tip: "No tire wall beside the road") { [unowned self] in
                perform { $0.barrierDistance = nil }
            },
            Option(title: "On", selected: def.barrierDistance != nil, tip: "Tire walls along both sides of the road") { [unowned self] in
                perform { $0.barrierDistance = $0.barrierDistance ?? 22 }
            },
        ])
        if let gap = def.barrierDistance {
            let r = EditorLimits.barrierDistance, t = EditorLimits.barrierThickness
            L.stepper("Gap", value: "\(Int(gap))", tip: "Distance from the road edge to the barrier") { [unowned self] in
                perform { $0.barrierDistance = clamp(gap - 2, r.lowerBound, r.upperBound) }
            } plus: { [unowned self] in
                perform { $0.barrierDistance = clamp(gap + 2, r.lowerBound, r.upperBound) }
            }
            L.stepper("Thickness", value: "\(Int(def.barrierThickness))", tip: "Barrier thickness") { [unowned self] in
                perform { $0.barrierThickness = clamp($0.barrierThickness - 1, t.lowerBound, t.upperBound) }
            } plus: { [unowned self] in
                perform { $0.barrierThickness = clamp($0.barrierThickness + 1, t.lowerBound, t.upperBound) }
            }
        }
        let hasSand = def.patches.contains { $0.surface == .sand } || def.background == .sand
        L.choices("Sand drift", [
            Option(title: "Off", selected: !def.looseSand, tip: "Sand traps stay put") { [unowned self] in
                perform { $0.looseSand = false }
            },
            Option(title: "On", selected: def.looseSand,
                   tip: "Sliding cars throw sand out of traps and track it onto the road during a race") { [unowned self] in
                perform { $0.looseSand = true }
            },
        ])
        if def.looseSand && !hasSand { L.note("Add a sand patch for this to do anything.") }
        L.choices(nil, [Option(title: "Reverse race direction", tip: "Cars race the other way round") { [unowned self] in
            perform { $0.reverseDirection() }
        }])
        let ownWidths = def.pointWidths.compactMap { $0 }.count
        L.note("\(def.controlPoints.count) road points\(ownWidths > 0 ? " (\(ownWidths) with their own width)" : ""), "
               + "\(def.patches.count) patches, \(def.bridges.count) bridges, \(def.lines.count) lines, \(def.objects.count) objects.")
        checksSection(L)
    }

    private func checksSection(_ L: PanelLayout) {
        L.header("CHECKS")
        if !isCurrent {
            L.note("Checking...")
        } else if issues.isEmpty {
            L.note("No problems found.", color: EditorColors.ok)
        } else {
            for issue in issues.prefix(5) { L.note("! " + issue.message, color: EditorColors.issue) }
            if issues.count > 5 { L.note("...and \(issues.count - 5) more", color: EditorColors.issue) }
        }
    }

    private func pointSection(_ L: PanelLayout, _ i: Int) {
        let n = def.controlPoints.count
        let p = def.controlPoints[i]
        L.header("ROAD POINT \(i + 1) OF \(n)")
        L.note(String(format: "x %.0f  y %.0f", p.x, p.y) + (i == 0 ? "  (start/finish line)" : ""))
        let own = hasOwnWidth(i)
        let width = def.roadWidth(atPoint: i)
        let limits = EditorLimits.roadWidth
        L.stepper("Road width", value: own ? "\(Int(width))" : "\(Int(width)) (track)",
                  tip: "Road width at this point. It eases smoothly to the widths at the next points.") { [unowned self] in
            perform { $0.setRoadWidth(clamp(width - 2, limits.lowerBound, limits.upperBound), atPoint: i) }
        } plus: { [unowned self] in
            perform { $0.setRoadWidth(clamp(width + 2, limits.lowerBound, limits.upperBound), atPoint: i) }
        }
        if own {
            L.choices(nil, [Option(title: "Use track width", tip: "Follow the track's road width again") { [unowned self] in
                perform { $0.setRoadWidth(nil, atPoint: i) }
            }])
        }
        L.choices(nil, [
            Option(title: "Make start", enabled: i != 0, tip: "Put the start/finish line at this point") { [unowned self] in
                perform { $0.makeStart(i) }
                select(.point(0))
            },
            Option(title: "Delete", enabled: n > TrackDefinition.minControlPoints, tip: "Delete this road point") { [unowned self] in
                deletePoint(i)
            },
        ])
        if let k = def.bridges.firstIndex(where: { $0.controlPoint == i }) {
            L.header("BRIDGE")
            let covered = coveredCount(bridge: k)
            L.note(covered > 1 ? "The road through this point goes over \(covered) other roads."
                               : "The road through this point goes over the other one.")
            let r = EditorLimits.bridgeEnd
            for end in BridgeEnd.allCases {
                let fixed = def.bridges[k].extent(end)
                L.choices(end == .back ? "Deck start" : "Deck end", [
                    Option(title: "Auto", selected: fixed == nil,
                           tip: "Reach just past the road below, with the ramp clear of other roads") { [unowned self] in
                        perform { $0.bridges[k].setExtent(nil, end) }
                    },
                    Option(title: "Fixed", selected: fixed != nil,
                           tip: "Choose how far the deck reaches. You can also drag its end on the map.") { [unowned self] in
                        let built = builtExtent(bridge: k, end) ?? 60
                        perform { $0.bridges[k].setExtent(clamp((built / 10).rounded(.up) * 10, r.lowerBound, r.upperBound), end) }
                    },
                ])
                if let fixed {
                    L.stepper(end == .back ? "Before point" : "After point", value: "\(Int(fixed))",
                              tip: "How far the deck reaches \(end == .back ? "back from" : "ahead of") this point") { [unowned self] in
                        perform { $0.bridges[k].setExtent(clamp(fixed - 10, r.lowerBound, r.upperBound), end) }
                    } plus: { [unowned self] in
                        perform { $0.bridges[k].setExtent(clamp(fixed + 10, r.lowerBound, r.upperBound), end) }
                    }
                }
            }
            let crossing = def.crossing(forBridge: k, in: crossings)
            L.choices(nil, [
                Option(title: "Swap over/under", enabled: crossing != nil && covered <= 1,
                       tip: covered > 1 ? "Only a bridge over one road can swap. Shorten this one first."
                                        : "Put the other road on the bridge") { [unowned self] in
                    guard let crossing else { return }
                    guard coveredCount(bridge: k, in: currentTrack) <= 1 else {
                        return flash("Only a bridge over one road can swap. Shorten this one first.")
                    }
                    perform { $0.flipBridge(k, at: crossing) }
                    select(.point(def.bridges[k].controlPoint))
                },
                Option(title: "Remove", tip: "Remove the bridge (the road point stays)") { [unowned self] in
                    perform { $0.bridges.remove(at: k) }
                    refreshPanel()
                },
            ])
            if crossing == nil { L.note("Not on a crossing: move the point to where the road crosses itself.", color: EditorColors.issue) }
            L.note("Drag the square handles at the deck ends to stretch the bridge over more roads.")
        } else if let x = crossings.filter({ $0.point.distance(to: p) < def.bridgeReach(atPoint: i) }).first,
                  let k = def.bridgeIndex(at: x) ?? coveringBridge(x) {
            L.header("BRIDGE")
            let owner = def.bridges[k].controlPoint
            let own = def.bridgeIndex(at: x) == k
            L.note(own ? "The other road goes over this one here." : "The bridge from road point \(owner + 1) goes over this road here.")
            var options: [Option] = []
            if own, coveredCount(bridge: k) <= 1 {
                options.append(Option(title: "Put this road on top", tip: "Swap which road goes over") { [unowned self] in
                    perform { $0.flipBridge(k, at: x) }
                    select(.point(def.bridges[k].controlPoint))
                })
            }
            options.append(Option(title: "Select bridge", tip: "Select the road point the bridge is built around") { [unowned self] in
                select(.point(owner))
            })
            L.choices(nil, options)
        } else if let x = crossings.filter({ $0.point.distance(to: p) < def.bridgeReach(atPoint: i) }).first {
            L.choices(nil, [Option(title: "Build a bridge here", tip: "This road goes over the other") { [unowned self] in
                let pass = def.loopDistance(Double(i), x.passA) < def.loopDistance(Double(i), x.passB) ? x.passA : x.passB
                var k = 0
                perform { k = $0.addBridge(at: x, over: pass) }
                select(.point(def.bridges[k].controlPoint))
                refreshPanel()
            }])
        }
        L.note("Drag to move, arrow keys nudge (Shift for 10). Drag the yellow edge handles to change the width. Right-click or Delete removes.")
        L.choices(nil, [Option(title: "Done", tip: "Back to track settings (Esc)") { [unowned self] in select(.none) }])
        checksSection(L)
    }

    private func surfaceOptions(selected: Surface, apply: @escaping (Surface) -> Void) -> [Option] {
        [Surface.sand, .ice, .water, .mud, .grass, .asphalt, .wall, .curb].map { s in
            Option(title: s.displayName, selected: selected == s, tint: EditorColors.swatch(s, theme: def.theme),
                   tip: s.editorTip) { apply(s) }
        }
    }

    private func newPatchSection(_ L: PanelLayout) {
        L.header("NEW PATCH")
        L.note("Patches paint a surface onto the map: sand traps, ice, water, mud, grass, extra asphalt, walls or curbs.")
        L.choices("Surface", surfaceOptions(selected: patchSurface) { [unowned self] s in
            patchSurface = s
            refreshPanel()
        }, perRow: 3)
        L.choices("Shape", PatchShapeKind.allCases.map { k in
            Option(title: k.displayName, selected: patchKind == k) { [unowned self] in
                patchKind = k
                refreshPanel()
            }
        })
        coversRoadChoice(L, selected: patchCoversRoad) { [unowned self] v in
            patchCoversRoad = v
            refreshPanel()
        }
        if patchKind == .capsule {
            L.stepper("Thickness", value: "\(Int(capsuleRadius * 2))", tip: "Width of new capsules") { [unowned self] in
                capsuleRadius = max(2, capsuleRadius - 1)
                refreshPanel()
            } plus: { [unowned self] in
                capsuleRadius = min(100, capsuleRadius + 1)
                refreshPanel()
            }
        }
        L.note("Drag on the map to draw one; click for a default size. Capsules make good walls.")
    }

    private func coversRoadChoice(_ L: PanelLayout, selected: Bool, apply: @escaping (Bool) -> Void) {
        L.choices("On road", [
            Option(title: "No", selected: !selected, tip: "Only paints beside the road; the road stays clear") { apply(false) },
            Option(title: "Yes", selected: selected, tip: "Paints over the road too (ice on the road, sand drifts)") { apply(true) },
        ])
    }

    private func patchSection(_ L: PanelLayout, _ i: Int) {
        let patch = def.patches[i]
        L.header("PATCH \(i + 1) OF \(def.patches.count)")
        L.choices("Surface", surfaceOptions(selected: patch.surface) { [unowned self] s in
            patchSurface = s
            updatePatch(i) { $0.surface = s }
        }, perRow: 3)
        L.choices("Shape", PatchShapeKind.allCases.map { k in
            Option(title: k.displayName, selected: patch.shape.kind == k) { [unowned self] in
                patchKind = k
                updatePatch(i) { $0.shape = $0.shape.converted(to: k) }
            }
        })
        if !def.bridges.isEmpty {
            L.choices("Level", [
                Option(title: "Ground", selected: !patch.onDeck) { [unowned self] in updatePatch(i) { $0.onDeck = false } },
                Option(title: "Bridge", selected: patch.onDeck) { [unowned self] in updatePatch(i) { $0.onDeck = true } },
            ])
        }
        if !patch.onDeck {
            coversRoadChoice(L, selected: patch.coversRoad) { [unowned self] v in
                patchCoversRoad = v
                updatePatch(i) { $0.coversRoad = v }
            }
        }
        let maxSize = EditorLimits.patchSize.upperBound
        switch patch.shape {
        case let .circle(c, r):
            L.stepper("Radius", value: "\(Int(r))") { [unowned self] in
                updatePatch(i) { $0.shape = .circle(center: c, radius: max(3, r - 5)) }
            } plus: { [unowned self] in
                updatePatch(i) { $0.shape = .circle(center: c, radius: min(maxSize / 2, r + 5)) }
            }
        case let .rect(o, s):
            let center = o + s * 0.5
            func resized(_ size: Vec2) -> PatchShape {
                let sz = Vec2(clamp(size.x, 3, maxSize), clamp(size.y, 3, maxSize))
                return .rect(origin: center - sz * 0.5, size: sz)
            }
            L.stepper("Width", value: "\(Int(s.x))") { [unowned self] in
                updatePatch(i) { $0.shape = resized(s - Vec2(10, 0)) }
            } plus: { [unowned self] in
                updatePatch(i) { $0.shape = resized(s + Vec2(10, 0)) }
            }
            L.stepper("Height", value: "\(Int(s.y))") { [unowned self] in
                updatePatch(i) { $0.shape = resized(s - Vec2(0, 10)) }
            } plus: { [unowned self] in
                updatePatch(i) { $0.shape = resized(s + Vec2(0, 10)) }
            }
        case let .capsule(a, b, r):
            let mid = (a + b) * 0.5, dir = (b - a).normalized.lengthSquared > 0 ? (b - a).normalized : Vec2(1, 0)
            let length = a.distance(to: b)
            func stretched(_ l: Double) -> PatchShape {
                let h = clamp(l, 0, maxSize) / 2
                return .capsule(from: mid - dir * h, to: mid + dir * h, radius: r)
            }
            L.stepper("Thickness", value: "\(Int(r * 2))") { [unowned self] in
                capsuleRadius = max(2, r - 1)
                updatePatch(i) { $0.shape = .capsule(from: a, to: b, radius: max(2, r - 1)) }
            } plus: { [unowned self] in
                capsuleRadius = min(100, r + 1)
                updatePatch(i) { $0.shape = .capsule(from: a, to: b, radius: min(100, r + 1)) }
            }
            L.stepper("Length", value: "\(Int(length.rounded()))") { [unowned self] in
                updatePatch(i) { $0.shape = stretched(length - 10) }
            } plus: { [unowned self] in
                updatePatch(i) { $0.shape = stretched(length + 10) }
            }
        }
        L.choices(nil, [
            Option(title: "To back", enabled: i > 0, tip: "Paint before other patches") { [unowned self] in
                perform { $0.patches.insert($0.patches.remove(at: i), at: 0) }
                select(.patch(0))
                refreshPanel()
            },
            Option(title: "To front", enabled: i < def.patches.count - 1, tip: "Paint over other patches") { [unowned self] in
                perform { $0.patches.append($0.patches.remove(at: i)) }
                select(.patch(def.patches.count - 1))
                refreshPanel()
            },
        ])
        L.choices(nil, [
            Option(title: "Duplicate", tip: "Copy this patch (Cmd+D)") { [unowned self] in duplicateSelection() },
            Option(title: "Delete", tip: "Delete this patch (Delete)") { [unowned self] in deleteSelection() },
        ])
        L.note("Drag to move, drag the yellow handles to resize. Arrow keys nudge.")
        L.choices(nil, [Option(title: "Done", tip: "Deselect (Esc)") { [unowned self] in select(.none) }])
    }

    // MARK: Lines and objects

    private func paintOptions(selected: PaintColor, apply: @escaping (PaintColor) -> Void) -> [Option] {
        PaintColor.allCases.map { c in
            Option(title: c.displayName, selected: selected == c, tint: EditorColors.paint(c)) { apply(c) }
        }
    }

    private func lineWidthStepper(_ L: PanelLayout, width: Double, apply: @escaping (Double) -> Void) {
        let r = EditorLimits.lineWidth
        L.stepper("Width", value: "\(Int(width))", tip: "Paint width") {
            apply(clamp(width - 1, r.lowerBound, r.upperBound))
        } plus: {
            apply(clamp(width + 1, r.lowerBound, r.upperBound))
        }
    }

    private func newLineSection(_ L: PanelLayout) {
        L.header("NEW LINE")
        L.note("Paint lines go on any surface: grid boxes, pit lane edges, arrows, a painted curb. They don't affect driving.")
        L.choices("Color", paintOptions(selected: lineColor) { [unowned self] c in
            lineColor = c
            refreshPanel()
        }, perRow: 3)
        lineWidthStepper(L, width: lineWidth) { [unowned self] w in
            lineWidth = w
            refreshPanel()
        }
        L.note("Click on the map to start a line, then click to add points (hold and drag to place each one exactly). "
               + "Click the last point, press Enter or right-click to finish.")
    }

    private func lineSection(_ L: PanelLayout, _ i: Int) {
        let line = def.lines[i]
        L.header("LINE \(i + 1) OF \(def.lines.count)")
        L.choices("Color", paintOptions(selected: line.color) { [unowned self] c in
            lineColor = c
            updateLine(i) { $0.color = c }
        }, perRow: 3)
        lineWidthStepper(L, width: line.width) { [unowned self] w in
            lineWidth = w
            updateLine(i) { $0.width = w }
        }
        L.note("\(line.points.count) point\(line.points.count == 1 ? "" : "s")")
        if drawingLine == i {
            L.note("Click to add points. Click the last point (ringed), press Enter or right-click to finish.", color: .accent)
            L.choices(nil, [Option(title: "Finish line", tip: "Stop adding points (Enter)") { [unowned self] in finishLine() }])
            return
        }
        L.choices(nil, [
            Option(title: "Add points", enabled: line.points.count < EditorLimits.maxLinePoints,
                   tip: "Keep drawing from the end of this line") { [unowned self] in
                if tool != .line { setTool(.line) }
                select(.line(i))
                drawingLine = i
                refreshAll()
            },
            Option(title: "Duplicate", tip: "Copy this line (Cmd+D)") { [unowned self] in duplicateSelection() },
            Option(title: "Delete", tip: "Delete this line (Delete)") { [unowned self] in deleteSelection() },
        ])
        L.note("Drag the line to move it, drag its yellow points to reshape it. Right-click a point to remove it. Arrow keys nudge.")
        L.choices(nil, [Option(title: "Done", tip: "Deselect (Esc)") { [unowned self] in select(.none) }])
    }

    private func kindOptions(selected: TrackObjectKind, apply: @escaping (TrackObjectKind) -> Void) -> [Option] {
        TrackObjectKind.allCases.map { k in
            Option(title: k.shortName, selected: selected == k, tip: k.editorTip) { apply(k) }
        }
    }

    private func solidChoice(_ L: PanelLayout, selected: Bool, apply: @escaping (Bool) -> Void) {
        L.choices("Solid", [
            Option(title: "No", selected: !selected, tip: "Scenery: cars drive under the leaves") { apply(false) },
            Option(title: "Yes", selected: selected, tip: "Cars crash into the trunk") { apply(true) },
        ])
    }

    private func treeSizeStepper(_ L: PanelLayout, size: Double, apply: @escaping (Double) -> Void) {
        let r = EditorLimits.treeSize
        L.stepper("Size", value: "\(Int(size))", tip: "Canopy diameter") {
            apply(clamp(size - 2, r.lowerBound, r.upperBound))
        } plus: {
            apply(clamp(size + 2, r.lowerBound, r.upperBound))
        }
    }

    private func newObjectSection(_ L: PanelLayout) {
        L.header("NEW OBJECT")
        L.note("Trees, buildings and jump ramps. Buildings are solid; trees can be solid or just scenery cars drive under.")
        L.choices("Kind", kindOptions(selected: objectKind) { [unowned self] k in
            objectKind = k
            refreshAll()
        }, perRow: 3)
        if objectKind.isTree {
            treeSizeStepper(L, size: treeSize) { [unowned self] s in
                treeSize = s
                refreshAll()
            }
            solidChoice(L, selected: treeSolid) { [unowned self] v in
                treeSolid = v
                refreshPanel()
            }
        }
        L.note("Click on the map to place one; hold and drag to put it in place. Buildings turn to face the nearest road; "
               + "ramps line up to jump the way the race goes.")
    }

    private func objectSection(_ L: PanelLayout, _ i: Int) {
        let o = def.objects[i]
        L.header("\(o.kind.displayName.uppercased()) \(i + 1) OF \(def.objects.count)")
        L.choices("Kind", kindOptions(selected: o.kind) { [unowned self] k in
            objectKind = k
            let tree = treeSize
            let aligned = raceAngle(at: o.position)
            updateObject(i) { obj in
                // Trees, buildings and ramps don't share sizes; keep the size within each group.
                func group(_ k: TrackObjectKind) -> Int { k.isTree ? 0 : k.isRamp ? 2 : 1 }
                if group(k) != group(obj.kind) {
                    obj.size = k.isTree ? Vec2(tree, tree) : k.defaultSize
                    if k.isRamp { obj.angle = aligned }
                }
                obj.kind = k
            }
        }, perRow: 3)
        if o.kind.isTree {
            treeSizeStepper(L, size: o.size.x) { [unowned self] s in
                treeSize = s
                updateObject(i) { $0.size = Vec2(s, s) }
            }
            solidChoice(L, selected: o.solid) { [unowned self] v in
                treeSolid = v
                updateObject(i) { $0.solid = v }
            }
        } else {
            let lr = EditorLimits.buildingLength, dr = EditorLimits.buildingDepth
            L.stepper("Length", value: "\(Int(o.size.x))") { [unowned self] in
                updateObject(i) { $0.size.x = clamp($0.size.x - 10, lr.lowerBound, lr.upperBound) }
            } plus: { [unowned self] in
                updateObject(i) { $0.size.x = clamp($0.size.x + 10, lr.lowerBound, lr.upperBound) }
            }
            L.stepper("Depth", value: "\(Int(o.size.y))") { [unowned self] in
                updateObject(i) { $0.size.y = clamp($0.size.y - 2, dr.lowerBound, dr.upperBound) }
            } plus: { [unowned self] in
                updateObject(i) { $0.size.y = clamp($0.size.y + 2, dr.lowerBound, dr.upperBound) }
            }
            let deg = Int((o.angle * 180 / .pi).rounded())
            let ramp = o.kind.isRamp
            L.stepper(ramp ? "Turn" : "Facing", value: "\((deg % 360 + 360) % 360)°",
                      tip: ramp ? "Which way the ramp launches cars" : "Which way the front faces") { [unowned self] in
                updateObject(i) { $0.angle = self.snapAngle($0.angle - .pi / 12, step: 5) }
            } plus: { [unowned self] in
                updateObject(i) { $0.angle = self.snapAngle($0.angle + .pi / 12, step: 5) }
            }
            if ramp {
                L.choices(nil, [
                    Option(title: "Line up", tip: "Point the jump the way the race runs on the nearest road") { [unowned self] in
                        let a = raceAngle(at: o.position)
                        updateObject(i) { $0.angle = a }
                    },
                    Option(title: "Flip", tip: "Swap which end cars jump from") { [unowned self] in
                        updateObject(i) { $0.angle = wrapAngle($0.angle + .pi) }
                    },
                ])
                L.note("Drive up from the chevron end to jump over walls, water and other cars. Hitting the lip "
                       + "end or the sides is just a bump that slows you down.")
            } else {
                L.choices(nil, [Option(title: "Face the road", tip: "Turn the front toward the nearest road") { [unowned self] in
                    let a = facingAngle(at: o.position)
                    updateObject(i) { $0.angle = a }
                }])
                L.note("Buildings are always solid.")
            }
        }
        L.choices(nil, [
            Option(title: "Duplicate", tip: "Copy this object (Cmd+D)") { [unowned self] in duplicateSelection() },
            Option(title: "Delete", tip: "Delete this object (Delete)") { [unowned self] in deleteSelection() },
        ])
        L.note(o.kind.isTree ? "Drag to move, drag the yellow handle to resize. Arrow keys nudge."
               : "Drag to move. Drag the corner handle to resize, the round handle to turn it. Arrow keys nudge.")
        L.choices(nil, [Option(title: "Done", tip: "Deselect (Esc)") { [unowned self] in select(.none) }])
        checksSection(L)
    }

    // MARK: Dialogs

    private func beginModal(size: CGSize) -> SKNode {
        closeModal()
        let root = SKNode()
        root.zPosition = Z.modal
        let dim = SKSpriteNode(color: SKColor(white: 0, alpha: 0.6), size: self.size)
        dim.anchorPoint = .zero
        dim.zPosition = 0
        root.addChild(dim)
        let box = SKNode()
        box.position = CGPoint(x: 480, y: 320)
        box.zPosition = 1
        root.addChild(box)
        let bg = SKShapeNode(rect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), cornerRadius: 10)
        bg.fillColor = SKColor(white: 0.07, alpha: 1)
        bg.strokeColor = SKColor(white: 1, alpha: 0.3)
        bg.zPosition = 0
        box.addChild(bg)
        addChild(root)
        modal = root
        hoveredButton = nil
        return box
    }

    private func closeModal() {
        modal?.removeFromParent()
        modal = nil
        hoveredButton = nil
    }

    private func dialogButton(_ title: String, width: CGFloat = 110, at p: CGPoint, in box: SKNode, selected: Bool = false,
                              action: @escaping () -> Void) {
        let b = EditorButton(title, size: CGSize(width: width, height: 26), fontSize: 11, action: action)
        b.isSelected = selected
        b.position = p
        b.zPosition = 2
        box.addChild(b)
    }

    private func dialogText(_ text: String, width: CGFloat, top: CGFloat, in box: SKNode) {
        for (i, line) in PanelLayout.wrap(text, width: Int(width / 7.4)).enumerated() {
            let l = makeLabel(line, size: 12, color: .white, align: .center)
            l.position = CGPoint(x: 0, y: top - CGFloat(i) * 18)
            l.zPosition = 2
            box.addChild(l)
        }
    }

    private func showConfirm(_ message: String, confirm: String, action: @escaping () -> Void) {
        let box = beginModal(size: CGSize(width: 420, height: 140))
        dialogText(message, width: 380, top: 36, in: box)
        dialogButton("Cancel", at: CGPoint(x: -65, y: -40), in: box) { [unowned self] in closeModal() }
        dialogButton(confirm, at: CGPoint(x: 65, y: -40), in: box, selected: true) { [unowned self] in
            closeModal()
            action()
        }
    }

    private func showMessage(_ message: String) {
        let box = beginModal(size: CGSize(width: 440, height: 140))
        dialogText(message, width: 400, top: 36, in: box)
        dialogButton("OK", at: CGPoint(x: 0, y: -40), in: box, selected: true) { [unowned self] in closeModal() }
    }

    private func showOpenBrowser(page: Int, confirmDelete: String?) {
        let lib = TrackLibrary.shared
        lib.reload()
        let defs = lib.definitions
        let perPage = 11
        let pages = max(1, (defs.count + perPage - 1) / perPage)
        let page = clamp(page, 0, pages - 1)
        let size = CGSize(width: 580, height: 480)
        let box = beginModal(size: size)
        let top = size.height / 2

        let title = makeLabel("OPEN TRACK", size: 20, color: .accent, align: .center)
        title.position = CGPoint(x: 0, y: top - 30)
        title.zPosition = 2
        box.addChild(title)
        let sub = makeLabel("Built-in tracks open as a copy you can save.", size: 11, color: .dim, align: .center)
        sub.position = CGPoint(x: 0, y: top - 54)
        sub.zPosition = 2
        box.addChild(sub)

        for (row, d) in defs.dropFirst(page * perPage).prefix(perPage).enumerated() {
            let y = top - 88 - CGFloat(row) * 31
            let custom = TrackStore.isCustom(d.id)
            let b = EditorButton(d.name, size: CGSize(width: 300, height: 26), fontSize: 12, alignLeft: true) { [unowned self] in
                closeModal()
                load(d)
                flash(custom ? "Opened \"\(d.name)\"" : "Editing a copy of \"\(d.name)\". Save to keep it.")
            }
            b.position = CGPoint(x: -120, y: y)
            b.zPosition = 2
            box.addChild(b)
            var info = [custom ? "custom" : "built-in", d.theme.rawValue]
            if !d.bridges.isEmpty { info.append("\(d.bridges.count) bridge\(d.bridges.count > 1 ? "s" : "")") }
            let l = makeLabel(info.joined(separator: " - "), size: 10, color: custom ? .white : .dim)
            l.position = CGPoint(x: 38, y: y)
            l.zPosition = 2
            box.addChild(l)
            if custom {
                let sure = confirmDelete == d.id
                dialogButton(sure ? "Sure?" : "Delete", width: 64, at: CGPoint(x: 240, y: y), in: box, selected: sure) { [unowned self] in
                    guard sure else { return showOpenBrowser(page: page, confirmDelete: d.id) }
                    do {
                        try TrackStore.delete(id: d.id)
                    } catch {
                        return showMessage("Couldn't delete the track: \(error.localizedDescription)")
                    }
                    coordinator.forgetTextures(for: d.id)
                    showOpenBrowser(page: page, confirmDelete: nil)
                    refreshToolbar()
                }
            }
        }

        let fy = -top + 28
        dialogButton("< Prev", width: 64, at: CGPoint(x: -240, y: fy), in: box) { [unowned self] in
            showOpenBrowser(page: page - 1, confirmDelete: nil)
        }
        let pageLabel = makeLabel("\(page + 1)/\(pages)", size: 11, color: .dim, align: .center)
        pageLabel.position = CGPoint(x: -170, y: fy)
        pageLabel.zPosition = 2
        box.addChild(pageLabel)
        dialogButton("Next >", width: 64, at: CGPoint(x: -100, y: fy), in: box) { [unowned self] in
            showOpenBrowser(page: page + 1, confirmDelete: nil)
        }
        dialogButton("Import", width: 80, at: CGPoint(x: -10, y: fy), in: box) { [unowned self] in importTrack() }
        dialogButton("Export", width: 80, at: CGPoint(x: 85, y: fy), in: box) { [unowned self] in exportTrack() }
        dialogButton("Cancel", width: 90, at: CGPoint(x: 210, y: fy), in: box) { [unowned self] in closeModal() }
    }
}

extension Surface {
    var displayName: String {
        switch self {
        case .asphalt: "Asphalt"
        case .curb: "Curb"
        case .grass: "Grass"
        case .sand: "Sand"
        case .ice: "Ice"
        case .wall: "Wall"
        case .water: "Water"
        case .mud: "Mud"
        }
    }

    var editorTip: String {
        switch self {
        case .asphalt: "Asphalt: full grip. Use it for run-off areas and shortcuts."
        case .curb: "Curb: nearly full grip, a bit more drag."
        case .grass: "Grass: slows cars and loosens grip."
        case .sand: "Sand: heavy drag, low grip. Classic trap on the outside of corners."
        case .ice: "Ice: very little grip or drag. Put it on the road for chaos."
        case .wall: "Wall: solid tire barrier cars bounce off."
        case .water: "Water: shallow, cars splash through it slowly and a bit loose."
        case .mud: "Mud: slippery and slow at once."
        }
    }
}

extension PaintColor {
    var displayName: String { rawValue.capitalized }
}

extension TrackObjectKind {
    var displayName: String {
        switch self {
        case .tree: "Tree"
        case .pine: "Pine"
        case .palm: "Palm"
        case .grandstand: "Grandstand"
        case .pitBuilding: "Pit building"
        case .ramp: "Ramp"
        }
    }

    /// Fits an inspector button.
    var shortName: String {
        switch self {
        case .grandstand: "Stand"
        case .pitBuilding: "Pits"
        default: displayName
        }
    }

    var editorTip: String {
        switch self {
        case .tree: "Round leafy tree"
        case .pine: "Pine tree"
        case .palm: "Palm tree"
        case .grandstand: "Grandstand full of spectators, seats facing the front"
        case .pitBuilding: "Pit garages with the doors along the front"
        case .ramp: "Jump ramp: launches cars driving up from the chevron end, bumps anyone coming the other way"
        }
    }
}

extension PatchShapeKind {
    var displayName: String {
        switch self {
        case .circle: "Circle"
        case .rect: "Rect"
        case .capsule: "Capsule"
        }
    }
}
#endif

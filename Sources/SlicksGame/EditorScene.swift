#if os(macOS)
import AppKit
import SlicksCore
import SpriteKit

/// Mouse-driven level editor. The map is edited as a `TrackDefinition`; every change rebuilds
/// the real `Track` in the background so the map shows exactly what will be raced, while a
/// vector overlay (centerline, points, patch outlines, crossings) gives instant feedback.
final class EditorScene: GameScene {
    enum Tool: CaseIterable {
        case select, road, patch, bridge

        var title: String {
            switch self {
            case .select: "Select"
            case .road: "Road"
            case .patch: "Patch"
            case .bridge: "Bridge"
            }
        }

        var shortcut: String {
            switch self {
            case .select: "V"
            case .road: "R"
            case .patch: "P"
            case .bridge: "B"
            }
        }

        var hint: String {
            switch self {
            case .select: "Drag road points and patches to move them, drag empty space to pan. Right-click deletes. Scroll or pinch to zoom."
            case .road: "Click to add a road point where the road should bend, drag points to reshape. Right-click a point to delete it."
            case .patch: "Drag on the map to draw a patch (a click gives a default size). Drag a patch to move it, its handles to resize."
            case .bridge: "Click where the road crosses itself to build a bridge. Click it again to swap which road goes over. Right-click removes."
            }
        }
    }

    enum Selection: Equatable {
        case none
        case point(Int)
        case patch(Int)
    }

    enum PatchHandle: Equatable {
        case radius
        case corner(Int)
        case end(Int)
    }

    private enum Hover: Equatable {
        case none
        case point(Int)
        case patch(Int)
        case handle(PatchHandle)
        case crossing(Int)
        case insert(index: Int, position: Vec2)
        case widthHandle(side: Int)
    }

    private enum Drag {
        case pan(start: CGPoint, offset: CGPoint)
        case point(index: Int, grab: Vec2)
        case patch(index: Int, start: Vec2, original: PatchShape)
        case handle(index: Int, handle: PatchHandle, original: PatchShape)
        case create(start: Vec2)
        /// Dragging a road edge handle of the selected point, along the road's normal there.
        case width(index: Int, normal: Vec2)
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
            toolButtons[t] = add(t.title, 56, "\(t.title) tool (\(t.shortcut)): \(t.hint)") { [unowned self] in setTool(t) }
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
        redoStack.append(def)
        def = prev
        definitionChanged()
    }

    private func redo() {
        closeChange()
        guard let next = redoStack.popLast() else { return flash("Nothing to redo") }
        undoStack.append(def)
        def = next
        definitionChanged()
    }

    /// `live` changes come from drags: the inspector is rebuilt when the drag ends instead.
    private func definitionChanged(live: Bool = false) {
        switch selection {
        case let .point(i) where !def.controlPoints.indices.contains(i): selection = .none
        case let .patch(i) where !def.patches.indices.contains(i): selection = .none
        default: break
        }
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

    /// Whether a control point sets its own width.
    private func hasOwnWidth(_ i: Int) -> Bool {
        def.pointWidths.indices.contains(i) && def.pointWidths[i] != nil
    }

    private func computeHover(at p: CGPoint) -> Hover {
        guard !isOverUI(p) else { return .none }
        let w = toWorld(p)
        switch tool {
        case .select:
            if let s = widthHandle(at: w) { return .widthHandle(side: s) }
            if let h = handle(at: w) { return .handle(h) }
            if let i = pointIndex(at: w) { return .point(i) }
            if let i = patchIndex(at: w) { return .patch(i) }
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
        if widthHandle(at: w) != nil, case let .point(i) = selection {
            drag = .width(index: i, normal: pointNormal(i))
            return
        }

        switch tool {
        case .select:
            if let h = handle(at: w), case let .patch(i) = selection {
                drag = .handle(index: i, handle: h, original: def.patches[i].shape)
            } else if let i = pointIndex(at: w) {
                select(.point(i))
                drag = .point(index: i, grab: def.controlPoints[i] - w)
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
        }
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
        }
        refreshStatus(cursor: w)
    }

    func pointerUp(at p: CGPoint) {
        guard let d = drag else { return }
        drag = nil
        if case let .create(start) = d {
            let shape = dragMoved ? (pendingPatch ?? defaultPatchShape(at: start)) : defaultPatchShape(at: start)
            pendingPatch = nil
            perform { $0.patches.append(Patch(patchSurface, shape, coversRoad: patchCoversRoad)) }
            select(.patch(def.patches.count - 1))
        }
        closeChange()
        hover = computeHover(at: p)
        refreshAll()
    }

    /// Right-click (or Control-click): delete what's under the mouse.
    func secondaryClick(at p: CGPoint) {
        guard !isOverUI(p) else { return }
        let w = toWorld(p)
        if tool == .bridge, let x = crossingIndex(at: w), let k = def.bridgeIndex(at: crossings[x]) {
            perform { $0.bridges.remove(at: k) }
            return flash("Bridge removed")
        }
        let pointFirst = tool != .patch
        if pointFirst, let i = pointIndex(at: w) { return deletePoint(i) }
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
        if h != hover {
            hover = h
            refreshOverlay()
        }
        refreshStatus(cursor: isOverUI(p) ? nil : toWorld(p))
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
        if let k = def.bridgeIndex(at: x) {
            perform { $0.flipBridge(k, at: x) }
            select(.point(def.bridges[k].controlPoint))
            flash("Swapped which road goes over")
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
        case .none: break
        }
    }

    private func duplicatePatch() {
        guard case let .patch(i) = selection, def.patches.count < EditorLimits.maxPatches else { return }
        var copy = def.patches[i]
        copy.shape = copy.shape.translated(by: Vec2(14, -14))
        perform { $0.patches.append(copy) }
        select(.patch(def.patches.count - 1))
    }

    private func nudge(_ d: Vec2) {
        switch selection {
        case let .point(i):
            perform { $0.controlPoints[i] = EditorLimits.clampToMap($0.controlPoints[i] + d) }
        case let .patch(i):
            perform { $0.patches[i].shape = $0.patches[i].shape.translated(by: d) }
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

    var debugSummary: String {
        "\(def.name): \(def.controlPoints.count) points, \(def.patches.count) patches, \(def.bridges.count) bridges "
            + "(over at \(def.bridges.map(\.controlPoint))), widths \(def.pointWidths.map { $0.map { Int($0) } }), "
            + "theme \(def.theme.rawValue), dirty \(isDirty), "
            + "undo \(undoStack.count), issues \(isCurrent ? "\(issues.map(\.message))" : "pending"), "
            + "tool \(tool.title), selection \(selection)"
    }
    #endif

    func setTool(_ t: Tool) {
        tool = t
        if t == .bridge, case .patch = selection { selection = .none }
        if t == .patch, case .point = selection { selection = .none }
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
            case "s": if modal == nil { save() }
            case "o": if modal == nil { openTrack() }
            case "n": if modal == nil { newTrack() }
            case "d": duplicatePatch()
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
        titleLabel.text = String(name.prefix(16)) + (isDirty ? " *" : "")
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
        if tool == .bridge {
            for (i, x) in crossings.enumerated() {
                let c = toScene(x.point)
                let hovered = hover == .crossing(i)
                if let k = def.bridgeIndex(at: x) {
                    let cp = def.bridges[k].controlPoint
                    let di = cp * Track.splineSteps
                    let t = (dense[(di + 2) % dense.count] - dense[(di - 2 + dense.count) % dense.count]).normalized
                    let half = (def.roadWidth(atPoint: cp) / 2 + 20)
                    let p0 = toScene(def.controlPoints[cp] - t * half), p1 = toScene(def.controlPoints[cp] + t * half)
                    let over = addShape(polyline([p0, p1], closed: false), stroke: EditorColors.bridge.withAlphaComponent(0.85),
                                        width: max(6, CGFloat(def.roadWidth(atPoint: cp)) * zoom * 0.35), z: 4)
                    over.lineCap = .round
                }
                let ring = CGPath(ellipseIn: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32), transform: nil)
                addShape(def.bridgeIndex(at: x) == nil ? ring.copy(dashingWithPhase: 0, lengths: [4, 3]) : ring,
                         stroke: hovered ? .accent : .white, width: hovered ? 2.5 : 1.5, z: 4)
            }
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
        case .none:
            if tool == .patch { newPatchSection(layout) } else { trackSection(layout) }
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
        L.choices(nil, [Option(title: "Reverse race direction", tip: "Cars race the other way round") { [unowned self] in
            perform { $0.reverseDirection() }
        }])
        let ownWidths = def.pointWidths.compactMap { $0 }.count
        L.note("\(def.controlPoints.count) road points\(ownWidths > 0 ? " (\(ownWidths) with their own width)" : ""), "
               + "\(def.patches.count) patches, \(def.bridges.count) bridges.")
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
            L.note("The road through this point goes over the other one.")
            let length = def.bridges[k].length
            L.choices("Length", [
                Option(title: "Auto", selected: length == nil, tip: "Size the deck to span the road below") { [unowned self] in
                    perform { $0.bridges[k].length = nil }
                },
                Option(title: "Fixed", selected: length != nil, tip: "Choose the deck length yourself") { [unowned self] in
                    let built = track?.bridges.first { $0.controlPoint == i }.map { $0.deckEnd - $0.deckStart } ?? 120
                    let r = EditorLimits.bridgeLength
                    perform { $0.bridges[k].length = clamp((built / 10).rounded() * 10, r.lowerBound, r.upperBound) }
                },
            ])
            if let length {
                let r = EditorLimits.bridgeLength
                L.stepper("Deck", value: "\(Int(length))", tip: "Deck length along the road") { [unowned self] in
                    perform { $0.bridges[k].length = clamp(length - 10, r.lowerBound, r.upperBound) }
                } plus: { [unowned self] in
                    perform { $0.bridges[k].length = clamp(length + 10, r.lowerBound, r.upperBound) }
                }
            }
            let crossing = def.crossing(forBridge: k, in: crossings)
            L.choices(nil, [
                Option(title: "Swap over/under", enabled: crossing != nil, tip: "Put the other road on the bridge") { [unowned self] in
                    guard let crossing else { return }
                    perform { $0.flipBridge(k, at: crossing) }
                    select(.point(def.bridges[k].controlPoint))
                },
                Option(title: "Remove", tip: "Remove the bridge (the road point stays)") { [unowned self] in
                    perform { $0.bridges.remove(at: k) }
                    refreshPanel()
                },
            ])
            if crossing == nil { L.note("Not on a crossing: move the point to where the road crosses itself.", color: EditorColors.issue) }
        } else if let x = crossings.filter({ $0.point.distance(to: p) < 24 }).first, let k = def.bridgeIndex(at: x) {
            L.header("BRIDGE")
            L.note("The other road goes over this one here.")
            L.choices(nil, [Option(title: "Put this road on top", tip: "Swap which road goes over") { [unowned self] in
                perform { $0.flipBridge(k, at: x) }
                select(.point(def.bridges[k].controlPoint))
            }])
        } else if let x = crossings.filter({ $0.point.distance(to: p) < 24 }).first {
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
        [Surface.sand, .ice, .grass, .asphalt, .wall, .curb].map { s in
            Option(title: s.displayName, selected: selected == s, tint: EditorColors.swatch(s, theme: def.theme),
                   tip: s.editorTip) { apply(s) }
        }
    }

    private func newPatchSection(_ L: PanelLayout) {
        L.header("NEW PATCH")
        L.note("Patches paint a surface onto the map: sand traps, ice, grass, extra asphalt, walls or curbs.")
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
        coversRoadChoice(L, selected: patch.coversRoad) { [unowned self] v in
            patchCoversRoad = v
            updatePatch(i) { $0.coversRoad = v }
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
            Option(title: "Duplicate", tip: "Copy this patch (Cmd+D)") { [unowned self] in duplicatePatch() },
            Option(title: "Delete", tip: "Delete this patch (Delete)") { [unowned self] in deleteSelection() },
        ])
        L.note("Drag to move, drag the yellow handles to resize. Arrow keys nudge.")
        L.choices(nil, [Option(title: "Done", tip: "Deselect (Esc)") { [unowned self] in select(.none) }])
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
        dialogButton("< Prev", width: 80, at: CGPoint(x: -230, y: fy), in: box) { [unowned self] in
            showOpenBrowser(page: page - 1, confirmDelete: nil)
        }
        let pageLabel = makeLabel("page \(page + 1) of \(pages)", size: 11, color: .dim, align: .center)
        pageLabel.position = CGPoint(x: -120, y: fy)
        pageLabel.zPosition = 2
        box.addChild(pageLabel)
        dialogButton("Next >", width: 80, at: CGPoint(x: -10, y: fy), in: box) { [unowned self] in
            showOpenBrowser(page: page + 1, confirmDelete: nil)
        }
        dialogButton("Cancel", at: CGPoint(x: 205, y: fy), in: box) { [unowned self] in closeModal() }
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

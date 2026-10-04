import CoreGraphics
import Foundation
import SlicksCore

struct RGB {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    func scaled(_ s: Double) -> RGB { RGB(r * s, g * s, b * s) }
    func mixed(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
}

/// Paints a `Track` into a pixel-art image: one image pixel per track cell.
public enum TrackRenderer {
    struct Palette {
        var ground: RGB
        var groundFar: RGB
        var tree: RGB
        var asphalt: RGB
        var sand: RGB
    }

    static func palette(_ theme: TrackTheme) -> Palette {
        switch theme {
        case .summer:
            Palette(ground: RGB(70, 150, 62), groundFar: RGB(48, 112, 46), tree: RGB(26, 78, 34),
                    asphalt: RGB(84, 86, 92), sand: RGB(214, 192, 124))
        case .desert:
            Palette(ground: RGB(196, 150, 92), groundFar: RGB(170, 122, 72), tree: RGB(120, 84, 52),
                    asphalt: RGB(92, 88, 86), sand: RGB(232, 206, 140))
        case .winter:
            Palette(ground: RGB(226, 232, 240), groundFar: RGB(200, 210, 224), tree: RGB(40, 80, 64),
                    asphalt: RGB(96, 100, 110), sand: RGB(180, 170, 150))
        }
    }

    public static func makeImage(for track: Track) -> CGImage {
        let w = track.width, h = track.height
        let def = track.definition
        let pal = palette(def.theme)
        let start = track.path[0], startT = track.tangents[0], startN = track.normals[0]
        let startHalf = track.halfWidths[0]
        let slots = track.gridSlots(count: Track.gridSize)
        let grid = slots.map { (position: $0.position, forward: Vec2(cos($0.heading), sin($0.heading))) }
        let gridStart = gridStartDistance(track, slots)
        let step = track.length / Double(track.sampleCount)
        let hasBridges = !track.bridges.isEmpty
        let paint = paintLayer(for: def)
        let ground = track.groundSurfaces
        /// Whether the ground a few cells from (x, y) isn't `s`, for shorelines.
        func nearEdge(_ x: Int, _ y: Int, of s: Surface, reach: Int) -> Bool {
            for (dx, dy) in [(reach, 0), (-reach, 0), (0, reach), (0, -reach)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, ground[ny * w + nx] != s { return true }
            }
            return false
        }

        func painted(_ c: RGB, _ x: Int, _ y: Int, _ noise: Double) -> RGB {
            guard let paint else { return c }
            let o = ((h - 1 - y) * w + x) * 4
            guard paint[o + 3] > 127 else { return c }
            return RGB(Double(paint[o]), Double(paint[o + 1]), Double(paint[o + 2])).scaled(1 + noise * 0.08)
        }

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                // Trees and buildings are drawn in their own layer, over the ground they stand on.
                let s = ground[i]
                let d = Double(track.distanceField[i])
                // Road half width where this cell is, since width can vary along the track.
                let half = track.halfRoad(atCell: i)
                let barrierOuter = def.barrierDistance.map { half + $0 + def.barrierThickness } ?? .infinity
                let noise = hash01(x, y) - 0.5
                var c: RGB

                // Bridge ramps and the deck footprint are painted as part of the structure, so
                // the deck sprite sits on a matching surface with no seams at its ends.
                if hasBridges, let e = track.elevation(x: x, y: y) {
                    let b = track.bridges[e.bridge]
                    let l = track.bridgeLocal(x: x, y: y)!
                    if let ramp = e.rampDistance {
                        // Patched cells on the ramp's road fall through and draw as their surface.
                        if l.lateral >= b.driveHalfWidth || s == .asphalt || s == .curb {
                            c = rampColor(surface: s, along: l.along, lateral: l.lateral, height: e.height,
                                          capped: ramp > b.rampLength - 14, bridge: b, half: b.roadHalf, pal: pal, noise: noise)
                            if s == .asphalt, isCenterDash(along: Double(b.centerSample) * step + l.along, lateral: l.lateral,
                                                           track: track, gridStart: gridStart) {
                                c = paintColor(.white).scaled(1 + noise * 0.08)
                            }
                            c = painted(c, x, y, noise)
                            c = applyWallShadow(c, track: track, x: x, y: y, surface: s)
                            write(c, x: x, y: y, w: w, h: h, into: &pixels)
                            continue
                        }
                    } else if s == .wall {
                        // Abutment under the deck: hidden by the deck sprite, painted to match it.
                        c = deckColor(along: l.along, lateral: l.lateral, bridge: b, half: b.roadHalf, pal: pal, noise: noise)
                        write(c, x: x, y: y, w: w, h: h, into: &pixels)
                        continue
                    }
                }

                switch s {
                case .asphalt:
                    c = pal.asphalt.scaled(1 + noise * 0.12)
                    // Checkered start/finish line.
                    let p = Vec2(Double(x) + 0.5, Double(y) + 0.5) - start
                    let u = p.dot(startT), v = p.dot(startN)
                    if abs(u) < 4, abs(v) < startHalf {
                        let checker = (Int(floor(u / 4)) + Int(floor(v / 4))) & 1 == 0
                        c = checker ? RGB(240, 240, 240) : RGB(24, 24, 24)
                    } else if d > half - 1.5 {
                        c = c.scaled(1.25)
                    } else if isGridMark(Vec2(Double(x) + 0.5, Double(y) + 0.5), grid) {
                        c = paintColor(.white).scaled(1 + noise * 0.08)
                    } else if def.centerLine, track.nearestSample[i] >= 0 {
                        let s = Int(track.nearestSample[i])
                        let q = Vec2(Double(x) + 0.5, Double(y) + 0.5) - track.path[s]
                        if isCenterDash(along: Double(s) * step + q.dot(track.tangents[s]),
                                        lateral: abs(q.dot(track.normals[s])), track: track, gridStart: gridStart) {
                            c = paintColor(.white).scaled(1 + noise * 0.08)
                        }
                    }
                case .curb:
                    let idx = Int(track.nearestSample[i])
                    c = (idx / 2) & 1 == 0 ? RGB(206, 44, 40) : RGB(236, 236, 236)
                case .grass:
                    let far = d > barrierOuter
                    c = (far ? pal.groundFar : pal.ground).scaled(1 + noise * 0.14)
                    if hash01(x, y, 7) > 0.985 { c = c.scaled(0.8) }
                    if far || (def.barrierDistance == nil && d > half + 70) {
                        c = tree(x: x, y: y, base: c, color: pal.tree) ?? c
                    }
                case .sand:
                    c = pal.sand.scaled(1 + noise * 0.1)
                    if hash01(x / 2, y, 3) > 0.93 { c = c.scaled(0.9) }
                    // Thin sand at the rim of a pile and loose grains are a touch darker, so
                    // the ground shows through the edge.
                    let sandNeighbors = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                        .filter { track.surface(x: x + $0.0, y: y + $0.1) == .sand }.count
                    if sandNeighbors < 4 { c = c.scaled(sandNeighbors == 0 ? 0.84 : 0.93) }
                case .ice:
                    c = RGB(186, 222, 244).scaled(1 + noise * 0.05)
                    if (x + y * 3) % 23 == 0 || hash01(x, y, 11) > 0.97 { c = RGB(236, 246, 255) }
                case .wall:
                    // Stacked tire barrier look.
                    let cell = ((x / 4) + (y / 4)) & 1
                    c = cell == 0 ? RGB(46, 46, 52) : RGB(22, 22, 26)
                    c = c.scaled(1 + noise * 0.2)
                case .water:
                    c = waterColor.scaled(1 + noise * 0.05)
                    // Short ripple streaks, and a pale rim along the shore.
                    let ripple = sin(Double(x) * 0.5 + Double(y) * 0.22 + hash01(x / 7, y / 5, 12) * 6)
                    if ripple > 0.94, hash01(x, y / 2, 13) > 0.35 { c = RGB(140, 192, 230) }
                    if nearEdge(x, y, of: .water, reach: 1) {
                        c = c.mixed(RGB(176, 214, 232), 0.55)
                    } else if nearEdge(x, y, of: .water, reach: 3) {
                        c = c.mixed(RGB(120, 172, 210), 0.35)
                    }
                case .mud:
                    c = mudColor.scaled(1 + noise * 0.12)
                    if hash01(x / 3, y / 3, 14) > 0.72 { c = c.scaled(0.8) }
                    if hash01(x, y, 15) > 0.985 { c = RGB(150, 122, 92) }
                    if nearEdge(x, y, of: .mud, reach: 1) { c = c.scaled(0.85) }
                }

                // Paint goes on top of any surface.
                c = painted(c, x, y, noise)

                c = applyWallShadow(c, track: track, x: x, y: y, surface: s)
                // The deck casts the same short shadow as walls onto the road passing under it.
                if hasBridges, track.deck(x: x, y: y) == nil,
                   (1...deckShadowLength).contains(where: { track.deck(x: x - $0, y: y + $0) != nil }) {
                    c = c.scaled(0.68)
                }
                write(c, x: x, y: y, w: w, h: h, into: &pixels)
            }
        }
        return makeCGImage(pixels: pixels, width: w, height: h)
    }

    /// Grid box mark in front of each slot: a bar across the nose with short legs back
    /// along both sides of the car.
    static func isGridMark(_ p: Vec2, _ grid: [(position: Vec2, forward: Vec2)]) -> Bool {
        let front = 13.5, bar = 2.0, leg = 8.0, halfBox = 8.5, legWidth = 1.6
        for slot in grid {
            let d = p - slot.position
            let u = d.dot(slot.forward)
            guard u > front - leg, u < front + bar else { continue }
            let v = abs(d.dot(slot.forward.perp))
            guard v < halfBox else { continue }
            if u > front || v > halfBox - legWidth { return true }
        }
        return false
    }

    static let centerDashLength = 10.0

    /// Distance along the track where the starting grid begins, measured from the start line.
    static func gridStartDistance(_ track: Track, _ slots: [(position: Vec2, heading: Double, index: Int)]) -> Double {
        let n = track.sampleCount
        let back = slots.map { Double((n - $0.index) % n) }.max() ?? 0
        return track.length - back * track.length / Double(n) - 16
    }

    /// Dashed center line, `along` measured from the start line. Left off the start line and grid.
    static func isCenterDash(along: Double, lateral: Double, track: Track, gridStart: Double) -> Bool {
        guard lateral < 0.8, track.definition.centerLine else { return false }
        let a = (along.truncatingRemainder(dividingBy: track.length) + track.length)
            .truncatingRemainder(dividingBy: track.length)
        guard a > 8, a < gridStart else { return false }
        return Int(floor(a / centerDashLength)) & 1 == 0
    }

    /// How far the deck's shadow reaches onto the road underneath, in cells (down-right).
    static let deckShadowLength = 3

    /// Walls cast a short shadow down-right.
    static func applyWallShadow(_ c: RGB, track: Track, x: Int, y: Int, surface s: Surface) -> RGB {
        guard s != .wall else { return c }
        // Abutments under a deck are hidden by it, so they don't cast shadows of their own.
        // Trees and buildings draw their own shadows.
        func casts(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < track.width, y < track.height else { return true }
            return track.groundSurfaces[y * track.width + x] == .wall && track.deck(x: x, y: y) == nil
        }
        return casts(x - 2, y + 2) || casts(x - 1, y + 1) ? c.scaled(0.68) : c
    }

    static func write(_ c: RGB, x: Int, y: Int, w: Int, h: Int, into pixels: inout [UInt8]) {
        let o = ((h - 1 - y) * w + x) * 4
        pixels[o] = UInt8(clamp(c.r, 0, 255))
        pixels[o + 1] = UInt8(clamp(c.g, 0, 255))
        pixels[o + 2] = UInt8(clamp(c.b, 0, 255))
        pixels[o + 3] = 255
    }

    /// Curb stripes on bridges run by distance along the upper road, so ramp and deck line up.
    static func bridgeCurb(along: Double) -> RGB {
        Int(floor(along / 8)) & 1 == 0 ? RGB(206, 44, 40) : RGB(236, 236, 236)
    }

    /// Ramp surface: walls, curbs and asphalt easing from road color into the deck tone as it climbs.
    static func rampColor(surface s: Surface, along: Double, lateral: Double, height t: Double, capped: Bool,
                          bridge b: Bridge, half: Double, pal: Palette, noise: Double) -> RGB {
        if s == .wall {
            return capped ? railCap : railColor(distanceFromCenter: lateral, driveHalfWidth: b.driveHalfWidth, halfWidth: b.halfWidth)
        }
        if lateral > half { return bridgeCurb(along: along).scaled(1 + 0.1 * t) }
        var c = pal.asphalt.scaled(1 + noise * 0.12).mixed(deckTone(pal).scaled(1 + noise * 0.08), t)
        if lateral > half - 1.5 { c = c.scaled(1.2) }
        return c
    }

    /// Deck surface at a point: railings, curbs and concrete with seams every 12 units.
    static func deckColor(along: Double, lateral: Double, bridge b: Bridge, half: Double, pal: Palette, noise: Double) -> RGB {
        if lateral > b.driveHalfWidth {
            return railColor(distanceFromCenter: lateral, driveHalfWidth: b.driveHalfWidth, halfWidth: b.halfWidth)
        }
        if lateral > half { return bridgeCurb(along: along).scaled(1.1) }
        var c = deckTone(pal).scaled(1 + noise * 0.08)
        let seam = (along - b.deckStart).truncatingRemainder(dividingBy: 12)
        let inside = along > b.deckStart + 4 && along < b.deckEnd - 4
        if inside, seam > 0.7, seam < 1.4 { c = c.scaled(0.88) }
        if lateral > half - 1.5 { c = c.scaled(1.2) }
        return c
    }

    /// Deck surface tone: lighter and cooler than asphalt so raised concrete stands out.
    static func deckTone(_ pal: Palette) -> RGB {
        pal.asphalt.mixed(RGB(150, 154, 166), 0.45)
    }

    /// Bridge side walls: a solid violet rail with a lit top edge and a dark outer face.
    static let railBase = RGB(116, 86, 156)
    static let railLight = RGB(160, 128, 200)
    static let railDark = RGB(64, 46, 92)
    /// End caps where the ramp walls meet the ground.
    static let railCap = RGB(44, 178, 150)

    static func railColor(distanceFromCenter d: Double, driveHalfWidth: Double, halfWidth: Double) -> RGB {
        if d > halfWidth - 1.6 { return railDark }
        if d < driveHalfWidth + 2 { return railLight }
        return railBase
    }

    /// Pixels per track unit for bridge deck images. Decks curve, so they're supersampled and
    /// drawn with linear filtering.
    public static let bridgeScale = 2

    /// How far the deck image overlaps the top of each ramp, hiding any seam at the joint.
    static let deckOverlap = 1.5

    /// World rectangle a bridge's deck image covers.
    public static func deckRect(_ b: Bridge) -> CGRect {
        let r = b.deckBounds
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    /// A curved bridge deck seen from above, world-aligned over `deckRect`, transparent outside
    /// the deck. Size is the rect times `bridgeScale`.
    public static func makeBridgeImage(for track: Track, bridge b: Bridge) -> CGImage {
        let s = Double(bridgeScale)
        let rect = b.deckBounds
        let w = rect.width * bridgeScale, h = rect.height * bridgeScale
        // A deck squeezed off the map by the editor has nothing to draw.
        guard w > 0, h > 0 else { return makeCGImage(pixels: [0, 0, 0, 0], width: 1, height: 1) }
        let pal = palette(track.definition.theme)
        let half = b.roadHalf
        let paint = paintLayer(for: track.definition)
        let step = track.length / Double(track.sampleCount)
        let gridStart = gridStartDistance(track, track.gridSlots(count: Track.gridSize))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for px in 0..<w {
                let p = Vec2(Double(rect.minX) + (Double(px) + 0.5) / s, Double(rect.maxY) - (Double(row) + 0.5) / s)
                let (along, lateral) = track.upperRoadLocal(bridge: b, point: p)
                guard along >= b.deckStart - deckOverlap, along <= b.deckEnd + deckOverlap else { continue }
                // Soft edge along the outside of the railings.
                let alpha = clamp((b.halfWidth - lateral) * s + 0.5, 0, 1)
                guard alpha > 0 else { continue }
                let noise = hash01(Int(floor(p.x)), Int(floor(p.y))) - 0.5
                let surface = lateral <= half ? track.surface(at: p, level: 1) : .asphalt
                var c = surface == .asphalt
                    ? deckColor(along: along, lateral: lateral, bridge: b, half: half, pal: pal, noise: noise)
                    : flatColor(surface, pal).scaled(1 + noise * 0.08)
                if surface == .asphalt, isCenterDash(along: Double(b.centerSample) * step + along, lateral: lateral,
                                                     track: track, gridStart: gridStart) {
                    c = paintColor(.white).scaled(1 + noise * 0.08)
                }
                let x = Int(floor(p.x)), y = Int(floor(p.y))
                if lateral <= half, let paint, x >= 0, y >= 0, x < track.width, y < track.height {
                    let offset = ((track.height - 1 - y) * track.width + x) * 4
                    if paint[offset + 3] > 127 {
                        c = RGB(Double(paint[offset]), Double(paint[offset + 1]), Double(paint[offset + 2]))
                            .scaled(1 + noise * 0.08)
                    }
                }
                let o = (row * w + px) * 4
                pixels[o] = UInt8(clamp(c.r * alpha, 0, 255))
                pixels[o + 1] = UInt8(clamp(c.g * alpha, 0, 255))
                pixels[o + 2] = UInt8(clamp(c.b * alpha, 0, 255))
                pixels[o + 3] = UInt8(clamp(alpha * 255, 0, 255))
            }
        }
        return makeCGImage(pixels: pixels, width: w, height: h)
    }

    /// Ground, bridge decks, trees and buildings in one image, for previews.
    public static func makeCompositeImage(for track: Track) -> CGImage {
        let ground = makeImage(for: track)
        guard !track.bridges.isEmpty || !track.definition.objects.isEmpty else { return ground }
        // Ramps sit on the ground under the decks; trees and buildings go over everything.
        let ctx = CGContext(data: nil, width: track.width, height: track.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(ground, in: CGRect(x: 0, y: 0, width: track.width, height: track.height))
        ctx.interpolationQuality = .high
        drawRamps(track.ramps.filter { !track.rampIsOnDeck($0) }, in: ctx)
        for b in track.bridges {
            ctx.draw(makeBridgeImage(for: track, bridge: b), in: deckRect(b))
        }
        drawRamps(track.ramps.filter { track.rampIsOnDeck($0) }, in: ctx)
        drawObjects(track.definition.objects, theme: track.definition.theme, in: ctx)
        return ctx.makeImage()!
    }

    // MARK: Paint lines

    static func paintColor(_ c: PaintColor) -> RGB {
        switch c {
        case .white: RGB(238, 238, 232)
        case .yellow: RGB(244, 200, 40)
        case .red: RGB(206, 44, 40)
        case .blue: RGB(44, 96, 204)
        case .black: RGB(22, 22, 24)
        }
    }

    static func cgColor(_ c: RGB, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: alpha)
    }

    /// Strokes paint lines in world coordinates.
    static func drawLines(_ lines: [PaintLine], in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for line in lines {
            guard let first = line.points.first else { continue }
            let color = cgColor(paintColor(line.color))
            if line.points.count == 1 {
                let r = line.width / 2
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2))
                continue
            }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(line.width)
            ctx.addLines(between: line.points.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Paint lines rasterized without antialiasing, one pixel per cell, in the same row order
    /// as the ground image. Nil when the track has no lines.
    static func paintLayer(for def: TrackDefinition) -> [UInt8]? {
        guard !def.lines.isEmpty else { return nil }
        let w = def.width, h = def.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setShouldAntialias(false)
            drawLines(def.lines, in: ctx)
        }
        return buffer
    }

    // MARK: Trees and buildings

    /// Pixels per track unit for the object layer.
    public static let objectScale = 2

    /// Trees and buildings with their shadows over a transparent map-sized image, drawn above
    /// the cars. Nil when the track has none.
    public static func makeObjectImage(for def: TrackDefinition) -> CGImage? {
        guard def.objects.contains(where: { !$0.kind.isRamp }) else { return nil }
        return makeLayer(for: def) { drawObjects(def.objects, theme: def.theme, in: $0) }
    }

    /// Ramps over a transparent map-sized image, drawn on the ground under the cars. Nil when
    /// the track has none.
    public static func makeRampImage(for track: Track, onDeck: Bool = false) -> CGImage? {
        let ramps = track.ramps.filter { track.rampIsOnDeck($0) == onDeck }
        guard !ramps.isEmpty else { return nil }
        return makeLayer(for: track.definition) { drawRamps(ramps, in: $0) }
    }

    private static func makeLayer(for def: TrackDefinition, _ draw: (CGContext) -> Void) -> CGImage? {
        let s = objectScale
        let ctx = CGContext(data: nil, width: def.width * s, height: def.height * s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
        draw(ctx)
        return ctx.makeImage()
    }

    /// Draws ramps in world coordinates, each with the shadow its raised lip casts.
    static func drawRamps(_ objects: [TrackObject], in ctx: CGContext) {
        for o in objects where o.kind.isRamp {
            ctx.saveGState()
            ctx.translateBy(x: o.position.x, y: o.position.y)
            ctx.rotate(by: o.angle)
            drawRamp(o, in: ctx)
            ctx.restoreGState()
        }
    }

    /// Plank ramp rising from the front (-y) to a hazard-striped lip (+y), with steel side
    /// rails and chevrons showing the way to jump. Drawn in local coordinates.
    static func drawRamp(_ o: TrackObject, in ctx: CGContext) {
        let hl = o.size.x / 2, hd = o.size.y / 2
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: RGB, alpha: Double = 1) {
            ctx.setFillColor(cgColor(c, alpha: alpha))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        // Shadow under the raised half, falling down-right in world space.
        ctx.saveGState()
        ctx.rotate(by: -o.angle)
        ctx.translateBy(x: 3.5, y: -3.5)
        ctx.rotate(by: o.angle)
        rect(-hl, 0, hl, hd, RGB(0, 0, 0), alpha: 0.3)
        ctx.restoreGState()

        // Planks, lighter as they climb toward the light.
        let low = RGB(132, 96, 62), high = RGB(204, 160, 106)
        let plank = 3.0
        var y = -hd
        var k = 0
        while y < hd {
            let t = (y + hd) / max(o.size.y, 1)
            let c = low.mixed(high, t).scaled(0.96 + 0.08 * hash01(k, Int(o.position.x), 31))
            rect(-hl, y, hl, min(hd, y + plank), c)
            rect(-hl, y, hl, y + 0.4, c.scaled(0.75))
            y += plank
            k += 1
        }
        // Chevrons pointing the way to jump.
        let w = min(hl * 0.55, 14.0), tall = min(w * 0.7, o.size.y * 0.18)
        for cy in [-hd * 0.45, -hd * 0.05] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -w, y: cy - tall))
            path.addLine(to: CGPoint(x: 0, y: cy + tall * 0.4))
            path.addLine(to: CGPoint(x: w, y: cy - tall))
            ctx.addPath(path)
            ctx.setStrokeColor(cgColor(RGB(248, 248, 240), alpha: 0.9))
            ctx.setLineWidth(max(1.5, w * 0.22))
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
            ctx.strokePath()
        }
        // Hazard stripes along the lip.
        let band = min(4.0, o.size.y * 0.15)
        rect(-hl, hd - band, hl, hd, RGB(240, 196, 40))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -hl, y: hd - band, width: o.size.x, height: band))
        ctx.setFillColor(cgColor(RGB(26, 26, 28)))
        var sx = -hl - band
        while sx < hl + band {
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: sx, y: hd - band), CGPoint(x: sx + 2.5, y: hd - band),
                                 CGPoint(x: sx + 2.5 + band, y: hd), CGPoint(x: sx + band, y: hd)])
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()
            sx += 5
        }
        ctx.restoreGState()
        // Steel lip edge, front plate and side rails.
        rect(-hl, hd - 0.8, hl, hd, RGB(236, 236, 240))
        rect(-hl, -hd, hl, -hd + 1.2, RGB(150, 152, 160))
        let rail = min(2.5, o.size.x * 0.06)
        rect(-hl, -hd, -hl + rail, hd, RGB(74, 76, 84))
        rect(hl - rail, -hd, hl, hd, RGB(74, 76, 84))
        rect(-hl + rail - 0.6, -hd, -hl + rail, hd, RGB(150, 152, 162))
        rect(hl - rail, -hd, hl - rail + 0.6, hd, RGB(150, 152, 162))
    }

    /// Draws objects in world coordinates: all shadows first, then buildings, then trees.
    /// Ramps are left out: they sit on the ground (see `drawRamps`).
    static func drawObjects(_ objects: [TrackObject], theme: TrackTheme, in ctx: CGContext) {
        let objects = objects.filter { !$0.kind.isRamp }
        guard !objects.isEmpty else { return }
        // Shadows go through one transparency layer so overlapping ones don't stack up darker.
        ctx.saveGState()
        ctx.setAlpha(0.3)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for o in objects {
            let d = shadowLength(o)
            ctx.saveGState()
            ctx.translateBy(x: d, y: -d)
            silhouette(o, in: ctx)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        for o in objects where !o.kind.isTree && o.kind != .footbridge { drawObject(o, theme: theme, in: ctx) }
        for o in objects where o.kind.isTree { drawObject(o, theme: theme, in: ctx) }
        for o in objects where o.kind == .footbridge { drawObject(o, theme: theme, in: ctx) }
    }

    /// How far down-right an object's shadow falls.
    static func shadowLength(_ o: TrackObject) -> Double {
        switch o.kind {
        case .tree, .pine: 1.5 + o.radius * 0.35
        case .palm: 3 + o.radius * 0.4
        case .grandstand: 7
        case .pitBuilding: 5
        case .ramp: 3.5
        case .boat: 2.5
        case .footbridge: 9
        }
    }

    /// Adds the object's outline to the context's path.
    static func silhouette(_ o: TrackObject, in ctx: CGContext) {
        let c = CGPoint(x: o.position.x, y: o.position.y)
        switch o.kind {
        case .tree:
            ctx.addEllipse(in: CGRect(x: c.x - o.radius, y: c.y - o.radius, width: o.radius * 2, height: o.radius * 2))
        case .pine:
            ctx.addPath(starPath(center: c, outer: o.radius, inner: o.radius * 0.72, points: 9, rotation: o.angle))
        case .palm:
            ctx.addPath(palmFronds(o))
        case .boat:
            var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: o.angle)
            if let hull = boatHull(o).copy(using: &t) { ctx.addPath(hull) }
        case .grandstand, .pitBuilding, .ramp, .footbridge:
            ctx.addLines(between: o.corners.map { CGPoint(x: $0.x, y: $0.y) })
            ctx.closePath()
        }
    }

    /// Stable per-object random number in [0, 1).
    static func objectHash(_ o: TrackObject, _ salt: Int) -> Double {
        hash01(Int(o.position.x * 8), Int(o.position.y * 8), salt)
    }

    static func starPath(center c: CGPoint, outer: Double, inner: Double, points: Int, rotation: Double) -> CGPath {
        let path = CGMutablePath()
        for k in 0..<(points * 2) {
            let a = rotation + Double(k) * .pi / Double(points)
            let r = k % 2 == 0 ? outer : inner
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    /// Palm fronds: pointed leaves radiating from the crown.
    static func palmFronds(_ o: TrackObject, scale: Double = 1) -> CGPath {
        let path = CGMutablePath()
        let count = 8
        let r = o.radius * scale
        for k in 0..<count {
            let a = o.angle + Double(k) * 2 * .pi / Double(count) + (objectHash(o, 40 + k) - 0.5) * 0.4
            let len = r * (0.85 + 0.15 * objectHash(o, 50 + k))
            let dir = Vec2(angle: a), side = dir.perp
            let base = o.position + dir * (r * 0.1)
            let mid = o.position + dir * (len * 0.55)
            let tip = o.position + dir * len
            let wdt = r * 0.34
            func pt(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
            path.move(to: pt(base))
            path.addQuadCurve(to: pt(tip), control: pt(mid + side * wdt))
            path.addQuadCurve(to: pt(base), control: pt(mid - side * wdt))
            path.closeSubpath()
        }
        return path
    }

    static func drawObject(_ o: TrackObject, theme: TrackTheme, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let c = CGPoint(x: o.position.x, y: o.position.y)
        let r = o.radius
        let snowy = theme == .winter
        func fill(_ color: RGB, _ path: CGPath) {
            ctx.addPath(path)
            ctx.setFillColor(cgColor(color))
            ctx.fillPath()
        }
        func disc(_ p: CGPoint, _ radius: Double) -> CGPath {
            CGPath(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        }

        switch o.kind {
        case .tree:
            // Clumps of leaves around a dark core, lit from the top left.
            let dark = RGB(30, 84, 36), mid = RGB(46, 118, 48)
            let light = snowy ? RGB(214, 226, 232) : RGB(86, 156, 68)
            fill(dark, disc(c, r))
            let lumps = 6
            for k in 0..<lumps {
                let a = o.angle + Double(k) * 2 * .pi / Double(lumps) + objectHash(o, k) * 0.6
                let p = CGPoint(x: c.x + cos(a) * r * 0.42, y: c.y + sin(a) * r * 0.42)
                fill(mid, disc(p, r * (0.5 + 0.08 * objectHash(o, 10 + k))))
            }
            fill(mid.scaled(1.05), disc(c, r * 0.55))
            for k in 0..<lumps {
                let a = o.angle + Double(k) * 2 * .pi / Double(lumps) + 0.5
                let p = CGPoint(x: c.x + cos(a) * r * 0.38 - r * 0.12, y: c.y + sin(a) * r * 0.38 + r * 0.12)
                let lit = sin(a) > -0.2 && cos(a) < 0.4
                fill(lit ? light : mid.scaled(1.12), disc(p, r * 0.2))
            }
            fill(light.mixed(RGB(255, 255, 255), snowy ? 0.4 : 0.15), disc(CGPoint(x: c.x - r * 0.22, y: c.y + r * 0.22), r * 0.16))
        case .pine:
            // Layered star of branches from above.
            let layers: [(Double, Double, RGB)] = [
                (1, 0.72, RGB(28, 82, 48)),
                (0.72, 0.5, snowy ? RGB(170, 194, 196) : RGB(44, 108, 62)),
                (0.45, 0.3, snowy ? RGB(226, 236, 240) : RGB(72, 142, 82)),
            ]
            for (k, layer) in layers.enumerated() {
                let path = starPath(center: c, outer: r * layer.0, inner: r * layer.1, points: 9 - k * 2,
                                    rotation: o.angle + Double(k) * 0.35)
                fill(layer.2, path)
            }
            fill(RGB(96, 70, 44), disc(c, max(0.8, r * 0.08)))
        case .palm:
            let outer = palmFronds(o)
            fill(RGB(60, 134, 52), outer)
            ctx.addPath(outer)
            ctx.setStrokeColor(cgColor(RGB(34, 88, 36)))
            ctx.setLineWidth(max(0.4, r * 0.03))
            ctx.strokePath()
            fill(snowy ? RGB(200, 220, 210) : RGB(110, 178, 74), palmFronds(o, scale: 0.62))
            // Midribs.
            ctx.setStrokeColor(cgColor(RGB(40, 96, 40)))
            ctx.setLineWidth(max(0.4, r * 0.035))
            for k in 0..<8 {
                let a = o.angle + Double(k) * 2 * .pi / 8 + (objectHash(o, 40 + k) - 0.5) * 0.4
                let tip = o.position + Vec2(angle: a) * (r * 0.8)
                ctx.move(to: c)
                ctx.addLine(to: CGPoint(x: tip.x, y: tip.y))
            }
            ctx.strokePath()
            fill(RGB(112, 82, 50), disc(c, r * 0.14))
            fill(RGB(150, 116, 70), disc(CGPoint(x: c.x - r * 0.04, y: c.y + r * 0.04), r * 0.07))
        case .grandstand:
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: o.angle)
            drawGrandstand(o, in: ctx)
        case .pitBuilding:
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: o.angle)
            drawPitBuilding(o, snowy: snowy, in: ctx)
        case .ramp:
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: o.angle)
            drawRamp(o, in: ctx)
        case .boat:
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: o.angle)
            drawBoat(o, snowy: snowy, in: ctx)
        case .footbridge:
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: o.angle)
            drawFootbridge(o, in: ctx)
        }
    }

    /// Hull outline in local coordinates: square stern at -x, pointed bow at +x.
    static func boatHull(_ o: TrackObject) -> CGPath {
        let hl = o.size.x / 2, hd = o.size.y / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -hl, y: -hd * 0.85))
        path.addLine(to: CGPoint(x: hl * 0.35, y: -hd))
        path.addQuadCurve(to: CGPoint(x: hl, y: 0), control: CGPoint(x: hl * 0.85, y: -hd * 0.9))
        path.addQuadCurve(to: CGPoint(x: hl * 0.35, y: hd), control: CGPoint(x: hl * 0.85, y: hd * 0.9))
        path.addLine(to: CGPoint(x: -hl, y: hd * 0.85))
        path.closeSubpath()
        return path
    }

    /// Motor yacht from above: white hull, teak deck, cabin with dark windows. Local coordinates.
    static func drawBoat(_ o: TrackObject, snowy: Bool, in ctx: CGContext) {
        let hl = o.size.x / 2, hd = o.size.y / 2
        let hull = boatHull(o)
        ctx.addPath(hull)
        ctx.setFillColor(cgColor(RGB(244, 244, 240)))
        ctx.fillPath()
        ctx.addPath(hull)
        ctx.setStrokeColor(cgColor(RGB(40, 52, 78)))
        ctx.setLineWidth(max(0.6, hd * 0.12))
        ctx.strokePath()
        // Teak deck inset from the hull.
        var inset = CGAffineTransform(translationX: -hl * 0.06, y: 0).scaledBy(x: 0.82, y: 0.7)
        if let deck = hull.copy(using: &inset) {
            ctx.addPath(deck)
            ctx.setFillColor(cgColor(snowy ? RGB(214, 220, 226) : RGB(184, 136, 88)))
            ctx.fillPath()
        }
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: RGB) {
            ctx.setFillColor(cgColor(c))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        let accents = [RGB(30, 60, 130), RGB(176, 36, 40), RGB(24, 24, 30), RGB(30, 120, 140)]
        let accent = accents[Int(objectHash(o, 70) * Double(accents.count)) % accents.count]
        // Cabin with a wraparound band of windows and a radar mast.
        let cx0 = -hl * 0.5, cx1 = hl * 0.25, cy = hd * 0.5
        rect(cx0, -cy, cx1, cy, RGB(236, 238, 242))
        rect(cx0 + 1, -cy + 0.8, cx1 - 1, -cy + 1.8, accent)
        rect(cx0 + 1, cy - 1.8, cx1 - 1, cy - 0.8, accent)
        rect(cx1 - 2.2, -cy + 1, cx1 - 0.8, cy - 1, accent)
        rect(cx0 + hl * 0.25, -cy * 0.4, cx0 + hl * 0.25 + 2, cy * 0.4, RGB(150, 154, 164))
        // Swim platform at the stern.
        rect(-hl - 1.5, -hd * 0.6, -hl, hd * 0.6, RGB(200, 200, 196))
    }

    /// Footbridge over the road along local x: stair towers at both ends, a railed walkway
    /// and sponsor banners down both sides. Local coordinates.
    static func drawFootbridge(_ o: TrackObject, in ctx: CGContext) {
        let hl = o.size.x / 2, hd = o.size.y / 2
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: RGB) {
            ctx.setFillColor(cgColor(c))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        let tower = min(16, o.size.x * 0.14)
        // Walkway: deck, planks, railings and banners.
        rect(-hl + tower, -hd, hl - tower, hd, RGB(192, 194, 200))
        var px = -hl + tower + 3
        while px < hl - tower {
            rect(px - 0.25, -hd + 2, px + 0.25, hd - 2, RGB(168, 170, 178))
            px += 4
        }
        // Steel side girders with a sponsor panel: solid, not striped, so it doesn't read as curb.
        let girder = min(3.5, o.size.y * 0.25)
        for (y0, y1) in [(-hd, -hd + girder), (hd - girder, hd)] {
            rect(-hl + tower, y0, hl - tower, y1, RGB(36, 58, 104))
            rect(-hl + tower, y0 + girder * 0.35, hl - tower, y1 - girder * 0.35, RGB(56, 92, 158))
            var lx = -hl + tower + 8
            while lx < hl - tower - 8 {
                rect(lx, y0 + girder * 0.42, lx + 5, y1 - girder * 0.42, RGB(236, 238, 242))
                lx += 18
            }
        }
        rect(-hl + tower, -hd + girder, hl - tower, -hd + girder + 0.8, RGB(70, 74, 84))
        rect(-hl + tower, hd - girder - 0.8, hl - tower, hd - girder, RGB(70, 74, 84))
        // Stair towers: concrete blocks with steps running up toward the walkway.
        for side in [-1.0, 1.0] {
            let x0 = side < 0 ? -hl : hl - tower, x1 = x0 + tower
            rect(x0, -hd - 2, x1, hd + 2, RGB(118, 120, 128))
            rect(x0 + 1, -hd - 1, x1 - 1, hd + 1, RGB(150, 152, 160))
            var sy = -hd
            while sy < hd {
                rect(x0 + 2, sy, x1 - 2, sy + 0.6, RGB(126, 128, 136))
                sy += 2.2
            }
        }
    }

    /// Seating rows rising from the front (-y) to a covered back, packed with spectators.
    /// Drawn in local coordinates.
    static func drawGrandstand(_ o: TrackObject, in ctx: CGContext) {
        let hl = o.size.x / 2, hd = o.size.y / 2
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: RGB) {
            ctx.setFillColor(cgColor(c))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        rect(-hl, -hd, hl, hd, RGB(128, 128, 134))
        let roofDepth = max(6, o.size.y * 0.3)
        let seatsTop = hd - roofDepth
        let rowDepth = 3.2
        let rows = max(2, Int((seatsTop + hd - 2) / rowDepth))
        let crowd = [RGB(214, 60, 52), RGB(240, 220, 90), RGB(70, 120, 210), RGB(236, 236, 236),
                     RGB(60, 170, 90), RGB(230, 150, 60), RGB(40, 40, 48), RGB(200, 160, 130)]
        for row in 0..<rows {
            let y0 = -hd + 2 + Double(row) * rowDepth
            // Rows further back sit higher, so they catch a little more light.
            let lift = 0.9 + 0.2 * Double(row) / Double(max(rows - 1, 1))
            rect(-hl + 2.5, y0, hl - 2.5, y0 + rowDepth - 0.8, RGB(44, 70, 150).scaled(lift))
            var x = -hl + 3.2
            var k = 0
            while x < hl - 3.2 {
                let hsh = hash01(Int(o.position.x) + k, Int(o.position.y) + row * 97, 21)
                if hsh > 0.28 {
                    let col = crowd[Int(hash01(k, row, Int(o.position.x) & 1023) * Double(crowd.count)) % crowd.count]
                    rect(x, y0 + 0.4, x + 1.5, y0 + 1.9, col.scaled(lift))
                }
                x += 2.2
                k += 1
            }
        }
        // Aisles.
        var ax = -hl + 28
        while ax < hl - 10 {
            rect(ax - 1, -hd + 2, ax + 1, seatsTop, RGB(150, 150, 156))
            ax += 30
        }
        // Front wall and end walls.
        rect(-hl, -hd, hl, -hd + 2, RGB(210, 210, 214))
        rect(-hl, -hd, -hl + 2.5, hd, RGB(96, 96, 104))
        rect(hl - 2.5, -hd, hl, hd, RGB(96, 96, 104))
        // Roof over the back rows, with ribs and a shaded front lip.
        rect(-hl, seatsTop, hl, hd, RGB(206, 210, 218))
        var rx = -hl + 8
        while rx < hl {
            rect(rx - 0.4, seatsTop, rx + 0.4, hd, RGB(176, 180, 190))
            rx += 10
        }
        rect(-hl, seatsTop, hl, seatsTop + 1.2, RGB(120, 124, 134))
        rect(-hl, hd - 1, hl, hd, RGB(236, 238, 242))
    }

    /// Flat-roofed pit garages: doors along the front (-y), team stripe along the back,
    /// rooftop plant and a small control tower at one end. Drawn in local coordinates.
    static func drawPitBuilding(_ o: TrackObject, snowy: Bool, in ctx: CGContext) {
        let hl = o.size.x / 2, hd = o.size.y / 2
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: RGB) {
            ctx.setFillColor(cgColor(c))
            ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
        let roof = snowy ? RGB(232, 236, 242) : RGB(212, 214, 220)
        rect(-hl, -hd, hl, hd, RGB(110, 112, 120))
        rect(-hl + 1.5, -hd + 1.5, hl - 1.5, hd - 1.5, roof)
        // Roof panel seams.
        var sx = -hl + 10
        while sx < hl - 2 {
            rect(sx - 0.3, -hd + 1.5, sx + 0.3, hd - 1.5, roof.scaled(0.92))
            sx += 10
        }
        // Garage doors under the front eave.
        let doorDepth = min(6, o.size.y * 0.2)
        rect(-hl, -hd, hl, -hd + doorDepth, RGB(48, 50, 58))
        let doors = max(1, Int((o.size.x - 4) / 16))
        let doorW = (o.size.x - 4) / Double(doors)
        for k in 0..<doors {
            let x0 = -hl + 2 + Double(k) * doorW
            rect(x0 + 1.5, -hd + 0.8, x0 + doorW - 1.5, -hd + doorDepth - 1, RGB(164, 168, 178))
            rect(x0 + 1.5, -hd + doorDepth - 2, x0 + doorW - 1.5, -hd + doorDepth - 1, RGB(206, 44, 40))
        }
        // Team stripe along the back.
        rect(-hl + 1.5, hd - 4.5, hl - 1.5, hd - 2, RGB(206, 44, 40))
        // Rooftop air handlers.
        let units = max(1, Int(o.size.x / 45))
        for k in 0..<units {
            let ux = -hl + (Double(k) + 0.5) * o.size.x / Double(units) - 6
            let uy = -hd + doorDepth + 3 + objectHash(o, 60 + k) * max(0, o.size.y - doorDepth - 16)
            rect(ux, uy, ux + 9, uy + 6, RGB(120, 124, 132))
            rect(ux + 1, uy + 1, ux + 8, uy + 5, RGB(160, 164, 172))
            rect(ux + 3.5, uy + 2, ux + 5.5, uy + 4, RGB(80, 84, 92))
        }
        // Control tower at the right end: a raised glass box.
        let t = min(o.size.y * 0.7, 26.0)
        let tx = hl - t - 3, ty = -t / 2 + 2
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
        ctx.fill(CGRect(x: tx + 2, y: ty - 2, width: t, height: t))
        rect(tx, ty, tx + t, ty + t, RGB(70, 130, 190))
        rect(tx + 2, ty + 2, tx + t - 2, ty + t - 2, roof.scaled(1.02))
        rect(tx + 2, ty + t - 3.5, tx + t - 2, ty + t - 2, RGB(140, 196, 236))
    }

    /// Flat-colored approximation of a track drawn with vector strokes: fast enough to redraw
    /// on every mouse move while the editor waits for the exact raster. Bridges aren't drawn.
    public static func makeQuickPreview(for def: TrackDefinition) -> CGImage {
        let w = def.width, h = def.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pal = palette(def.theme)
        func color(_ s: Surface) -> CGColor { cgColor(flatColor(s, pal)) }
        ctx.setFillColor(color(def.background))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let dense = Track.centerline(through: def.controlPoints)
        let widths = def.centerlineWidths()
        let road = CGMutablePath()
        road.addLines(between: dense.map { CGPoint(x: $0.x, y: $0.y) })
        road.closeSubpath()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        /// Band along the road, `extra` wider than the road on each side.
        func band(extra: Double, _ c: CGColor) {
            if def.hasPointWidths && widths.count == dense.count {
                // Varying width: a disc at every dense point (they're a few units apart).
                ctx.setFillColor(c)
                for (p, wd) in zip(dense, widths) {
                    let r = wd / 2 + extra
                    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                }
            } else {
                ctx.addPath(road)
                ctx.setLineWidth(def.roadWidth + 2 * extra)
                ctx.setStrokeColor(c)
                ctx.strokePath()
            }
        }
        func fill(_ patch: Patch) {
            switch patch.shape {
            case let .circle(c, r):
                ctx.setFillColor(color(patch.surface))
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            case let .rect(o, s):
                ctx.setFillColor(color(patch.surface))
                ctx.fill(CGRect(x: o.x, y: o.y, width: s.x, height: s.y))
            case let .capsule(a, b, r):
                ctx.move(to: CGPoint(x: a.x, y: a.y))
                ctx.addLine(to: CGPoint(x: b.x, y: b.y))
                ctx.setLineWidth(r * 2)
                ctx.setStrokeColor(color(patch.surface))
                ctx.strokePath()
            }
        }

        // Same layering as `Track.rasterize`: barrier, patches beside the road, road, patches on it.
        if let bd = def.barrierDistance {
            band(extra: bd + def.barrierThickness, color(.wall))
            band(extra: bd, color(def.background))
        }
        def.patches.filter { !$0.onDeck && !$0.coversRoad }.forEach(fill)
        band(extra: def.curbWidth, color(.curb))
        band(extra: 0, color(.asphalt))
        if def.centerLine {
            ctx.saveGState()
            ctx.addPath(road)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: 0, lengths: [centerDashLength, centerDashLength])
            ctx.setStrokeColor(cgColor(paintColor(.white)))
            ctx.strokePath()
            ctx.restoreGState()
        }
        def.patches.filter { !$0.onDeck && $0.coversRoad }.forEach(fill)
        drawLines(def.lines, in: ctx)
        ctx.setStrokeColor(color(.wall))
        ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 0, y: 0, width: w, height: h))
        drawRamps(def.objects, in: ctx)
        drawObjects(def.objects, theme: def.theme, in: ctx)
        return ctx.makeImage()!
    }

    static let waterColor = RGB(56, 118, 178)
    static let mudColor = RGB(104, 76, 50)

    /// Single representative color of a surface, for previews and swatches.
    static func flatColor(_ s: Surface, _ pal: Palette) -> RGB {
        switch s {
        case .asphalt: pal.asphalt
        case .curb: RGB(206, 44, 40)
        case .grass: pal.ground
        case .sand: pal.sand
        case .ice: RGB(186, 222, 244)
        case .wall: RGB(46, 46, 52)
        case .water: waterColor
        case .mud: mudColor
        }
    }

    /// Hash-placed round tree canopies on a 14px grid.
    private static func tree(x: Int, y: Int, base: RGB, color: RGB) -> RGB? {
        let cell = 14
        let cx = x / cell, cy = y / cell
        guard hash01(cx, cy, 5) > 0.55 else { return nil }
        let ox = Double(cx * cell) + 3 + hash01(cx, cy, 6) * Double(cell - 6)
        let oy = Double(cy * cell) + 3 + hash01(cx, cy, 8) * Double(cell - 6)
        let r = 4 + hash01(cx, cy, 9) * 2.5
        let dx = Double(x) - ox, dy = Double(y) - oy
        let d2 = dx * dx + dy * dy
        if d2 > r * r { return nil }
        // Lit from the top-left.
        let shade = 1.15 - (dy < 0 ? 0.25 : 0) - (dx > 0 ? 0.1 : 0)
        return color.scaled(shade)
    }

    static func makeCGImage(pixels: [UInt8], width: Int, height: Int) -> CGImage {
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

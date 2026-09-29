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
        let half = track.halfRoad
        let barrierOuter = def.barrierDistance.map { half + $0 + def.barrierThickness } ?? .infinity
        let start = track.path[0], startT = track.tangents[0], startN = track.normals[0]
        let hasBridges = !track.bridges.isEmpty

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let s = track.surfaces[i]
                let d = Double(track.distanceField[i])
                let noise = hash01(x, y) - 0.5
                var c: RGB

                // Bridge ramps and the deck footprint are painted as part of the structure, so
                // the deck sprite sits on a matching surface with no seams at its ends.
                if hasBridges, let e = track.elevation(x: x, y: y) {
                    let b = track.bridges[e.bridge]
                    let l = track.bridgeLocal(x: x, y: y)!
                    if let ramp = e.rampDistance {
                        c = rampColor(surface: s, along: l.along, lateral: l.lateral, height: e.height,
                                      capped: ramp > b.rampLength - 14, bridge: b, half: half, pal: pal, noise: noise)
                        c = applyWallShadow(c, track: track, x: x, y: y, surface: s)
                        write(c, x: x, y: y, w: w, h: h, into: &pixels)
                        continue
                    } else if s == .wall {
                        // Abutment under the deck: hidden by the deck sprite, painted to match it.
                        c = deckColor(along: l.along, lateral: l.lateral, bridge: b, half: half, pal: pal, noise: noise)
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
                    if abs(u) < 4, abs(v) < half {
                        let checker = (Int(floor(u / 4)) + Int(floor(v / 4))) & 1 == 0
                        c = checker ? RGB(240, 240, 240) : RGB(24, 24, 24)
                    } else if d > half - 1.5 {
                        c = c.scaled(1.25)
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
                case .ice:
                    c = RGB(186, 222, 244).scaled(1 + noise * 0.05)
                    if (x + y * 3) % 23 == 0 || hash01(x, y, 11) > 0.97 { c = RGB(236, 246, 255) }
                case .wall:
                    // Stacked tire barrier look.
                    let cell = ((x / 4) + (y / 4)) & 1
                    c = cell == 0 ? RGB(46, 46, 52) : RGB(22, 22, 26)
                    c = c.scaled(1 + noise * 0.2)
                }

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

    /// How far the deck's shadow reaches onto the road underneath, in cells (down-right).
    static let deckShadowLength = 3

    /// Walls cast a short shadow down-right.
    static func applyWallShadow(_ c: RGB, track: Track, x: Int, y: Int, surface s: Surface) -> RGB {
        guard s != .wall else { return c }
        // Abutments under a deck are hidden by it, so they don't cast shadows of their own.
        func casts(_ x: Int, _ y: Int) -> Bool { track.isWall(x, y) && track.deck(x: x, y: y) == nil }
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
        let pal = palette(track.definition.theme)
        let half = track.halfRoad
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
                let c = deckColor(along: along, lateral: lateral, bridge: b, half: half, pal: pal, noise: noise)
                let o = (row * w + px) * 4
                pixels[o] = UInt8(clamp(c.r * alpha, 0, 255))
                pixels[o + 1] = UInt8(clamp(c.g * alpha, 0, 255))
                pixels[o + 2] = UInt8(clamp(c.b * alpha, 0, 255))
                pixels[o + 3] = UInt8(clamp(alpha * 255, 0, 255))
            }
        }
        return makeCGImage(pixels: pixels, width: w, height: h)
    }

    /// Ground plus bridge decks in one image, for previews.
    public static func makeCompositeImage(for track: Track) -> CGImage {
        let ground = makeImage(for: track)
        guard !track.bridges.isEmpty else { return ground }
        let ctx = CGContext(data: nil, width: track.width, height: track.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(ground, in: CGRect(x: 0, y: 0, width: track.width, height: track.height))
        ctx.interpolationQuality = .high
        for b in track.bridges {
            ctx.draw(makeBridgeImage(for: track, bridge: b), in: deckRect(b))
        }
        return ctx.makeImage()!
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

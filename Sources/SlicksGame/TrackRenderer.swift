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

        // Bridge structure heights and the shadow they cast. Each elevated cell throws its shadow
        // down-right by an amount proportional to its height, so the shadow peels away from the
        // ramp as it climbs and runs alongside the deck at full offset.
        var elevation = [Float](repeating: -1, count: hasBridges ? w * h : 0)
        var rampStep = [Int16](repeating: -1, count: hasBridges ? w * h : 0)
        var elevBridge = [Int8](repeating: 0, count: hasBridges ? w * h : 0)
        var inShadow = [Bool](repeating: false, count: hasBridges ? w * h : 0)
        if hasBridges {
            for y in 0..<h {
                for x in 0..<w {
                    guard let e = track.elevation(x: x, y: y) else { continue }
                    elevation[y * w + x] = Float(e.height)
                    rampStep[y * w + x] = Int16(e.rampStep ?? -1)
                    elevBridge[y * w + x] = Int8(e.bridge)
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    let e = Double(elevation[y * w + x])
                    guard e > 0 else { continue }
                    let tx = Int((Double(x) + bridgeShadowOffset.x * e).rounded())
                    let ty = Int((Double(y) + bridgeShadowOffset.y * e).rounded())
                    for (sx, sy) in [(tx, ty), (tx + 1, ty), (tx, ty - 1), (tx + 1, ty - 1)]
                    where sx >= 0 && sy >= 0 && sx < w && sy < h {
                        inShadow[sy * w + sx] = true
                    }
                }
            }
        }

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let s = track.surfaces[i]
                let d = Double(track.distanceField[i])
                let noise = hash01(x, y) - 0.5
                var c: RGB

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
                    if hasBridges, elevation[i] >= 0 {
                        // Ramp side walls, matching the deck railings, with a cap where they meet the ground.
                        let b = track.bridges[Int(elevBridge[i])]
                        let step = Int(rampStep[i])
                        c = step >= b.rampSamples - 4
                            ? railCap
                            : railColor(distanceFromCenter: d, driveHalfWidth: b.driveHalfWidth, halfWidth: b.halfWidth)
                    } else {
                        // Stacked tire barrier look.
                        let cell = ((x / 4) + (y / 4)) & 1
                        c = cell == 0 ? RGB(46, 46, 52) : RGB(22, 22, 26)
                        c = c.scaled(1 + noise * 0.2)
                    }
                }

                if hasBridges {
                    let e = Double(elevation[i])
                    if e >= 0, rampStep[i] >= 0, s == .asphalt || s == .curb {
                        c = shadeRamp(c, t: e, isCurb: s == .curb, pal: pal)
                    } else if e < 0, inShadow[i] {
                        c = c.scaled(0.5)
                    }
                }

                // Walls cast a short shadow down-right.
                if s != .wall, track.isWall(x - 2, y + 2) || track.isWall(x - 1, y + 1) {
                    c = c.scaled(0.68)
                }

                let row = h - 1 - y
                let o = (row * w + x) * 4
                pixels[o] = UInt8(clamp(c.r, 0, 255))
                pixels[o + 1] = UInt8(clamp(c.g, 0, 255))
                pixels[o + 2] = UInt8(clamp(c.b, 0, 255))
                pixels[o + 3] = 255
            }
        }
        return makeCGImage(pixels: pixels, width: w, height: h)
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

    /// Eases ramp asphalt from road color into the deck tone as it climbs.
    static func shadeRamp(_ c: RGB, t: Double, isCurb: Bool, pal: Palette) -> RGB {
        if isCurb { return c.scaled(1 + 0.1 * t) }
        return c.mixed(deckTone(pal), t).scaled(1 + 0.06 * t)
    }

    /// Pixels per track unit for bridge deck images. Decks are rotated, so they're supersampled
    /// and drawn with linear filtering.
    public static let bridgeScale = 2

    /// A bridge deck seen from above, in deck-local coordinates (u along the image's x axis,
    /// v up the image). Size is the deck footprint times `bridgeScale`.
    public static func makeBridgeImage(for track: Track, bridge b: Bridge) -> CGImage {
        let s = Double(bridgeScale)
        let w = Int((b.halfLength * 2 * s).rounded()), h = Int((b.halfWidth * 2 * s).rounded())
        let pal = palette(track.definition.theme)
        let half = track.halfRoad
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            for px in 0..<w {
                let u = (Double(px) + 0.5) / s - b.halfLength
                let v = b.halfWidth - (Double(row) + 0.5) / s
                let au = abs(u), av = abs(v)
                let noise = hash01(px, row, 21) - 0.5
                var c: RGB
                if av > b.driveHalfWidth {
                    c = railColor(distanceFromCenter: av, driveHalfWidth: b.driveHalfWidth, halfWidth: b.halfWidth)
                } else if av > half {
                    let stripe = Int(floor((u + b.halfLength) / 8)) & 1
                    c = stripe == 0 ? RGB(206, 44, 40) : RGB(236, 236, 236)
                } else {
                    // Concrete deck: lighter and bluer than the asphalt, with seams every 12 units.
                    c = deckTone(pal).scaled(1 + noise * 0.08)
                    if (u + b.halfLength).truncatingRemainder(dividingBy: 12) < 0.7 { c = c.scaled(0.85) }
                    if av > half - 1.5 { c = c.scaled(1.2) }
                    // Expansion joints at each end of the deck.
                    if au > b.halfLength - 1.4 { c = c.scaled(0.72) }
                }
                let o = (row * w + px) * 4
                pixels[o] = UInt8(clamp(c.r, 0, 255))
                pixels[o + 1] = UInt8(clamp(c.g, 0, 255))
                pixels[o + 2] = UInt8(clamp(c.b, 0, 255))
                pixels[o + 3] = 255
            }
        }
        return makeCGImage(pixels: pixels, width: w, height: h)
    }

    /// Offset of a bridge deck's drop shadow, in track units.
    /// Shadow offset cast by the bridge at full deck height, in track units. Ramps scale it down.
    public static let bridgeShadowOffset = CGPoint(x: 17, y: -17)

    /// Ground plus bridge decks and their shadows in one image, for previews.
    public static func makeCompositeImage(for track: Track) -> CGImage {
        let ground = makeImage(for: track)
        guard !track.bridges.isEmpty else { return ground }
        let ctx = CGContext(data: nil, width: track.width, height: track.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(ground, in: CGRect(x: 0, y: 0, width: track.width, height: track.height))
        ctx.interpolationQuality = .high
        for b in track.bridges {
            let rect = CGRect(x: -b.halfLength, y: -b.halfWidth, width: b.halfLength * 2, height: b.halfWidth * 2)
            ctx.saveGState()
            ctx.translateBy(x: b.center.x, y: b.center.y)
            ctx.rotate(by: b.axis.angle)
            ctx.draw(makeBridgeImage(for: track, bridge: b), in: rect)
            ctx.restoreGState()
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

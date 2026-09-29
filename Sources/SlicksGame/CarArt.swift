import CoreGraphics
import SpriteKit

/// Kart liveries and procedurally drawn top-down kart sprites.
///
/// The kart is drawn in a local frame where x runs rear (0) to front (`length`) and y spans the
/// track width. The body image holds everything except the front tires, which are separate
/// sprites so they can visibly steer.
public enum CarArt {
    public struct Livery {
        public var name: String
        public var body: (Double, Double, Double)
    }

    public static let liveries: [Livery] = [
        Livery(name: "Red", body: (0.88, 0.16, 0.14)),
        Livery(name: "Blue", body: (0.18, 0.40, 0.95)),
        Livery(name: "Yellow", body: (0.98, 0.84, 0.12)),
        Livery(name: "Green", body: (0.16, 0.74, 0.26)),
        Livery(name: "Orange", body: (1.0, 0.54, 0.10)),
        Livery(name: "Purple", body: (0.64, 0.30, 0.88)),
        Livery(name: "Cyan", body: (0.12, 0.80, 0.86)),
        Livery(name: "White", body: (0.95, 0.95, 0.95)),
    ]

    public static func color(_ index: Int) -> SKColor {
        let b = liveries[index % liveries.count].body
        return SKColor(red: b.0, green: b.1, blue: b.2, alpha: 1)
    }

    // Kart geometry, in track units. Matches the default CarSpec footprint (22 x 11).
    static let length: CGFloat = 22
    static let width: CGFloat = 11
    static let pad: CGFloat = 1
    static let frontTireSize = CGSize(width: 4.8, height: 2.9)
    static let rearTireSize = CGSize(width: 6.0, height: 3.4)
    /// Front tire centers in the kart's local frame.
    static let frontTireCenters = [CGPoint(x: 17.4, y: 1.45), CGPoint(x: 17.4, y: width - 1.45)]

    /// Supersampling factor for the images. Sprites are displayed at 1x track scale.
    static let scale: CGFloat = 4

    private static var bodyCache: [Int: SKTexture] = [:]
    private static var tireTexture: SKTexture?

    /// Display size of the body sprite including its padding.
    public static func spriteSize() -> CGSize {
        CGSize(width: length + pad * 2, height: width + pad * 2)
    }

    /// Front tire offsets from the sprite center, for positioning the steerable tire sprites.
    static var frontTireOffsets: [CGPoint] {
        frontTireCenters.map { CGPoint(x: $0.x - length / 2, y: $0.y - width / 2) }
    }

    public static func texture(colorIndex: Int) -> SKTexture {
        if let t = bodyCache[colorIndex] { return t }
        let t = SKTexture(cgImage: bodyImage(colorIndex: colorIndex))
        t.filteringMode = .linear
        bodyCache[colorIndex] = t
        return t
    }

    static func frontTireTexture() -> SKTexture {
        if let t = tireTexture { return t }
        let t = SKTexture(cgImage: tireImage(size: frontTireSize))
        t.filteringMode = .linear
        tireTexture = t
        return t
    }

    // MARK: Drawing

    private static func makeContext(size: CGSize) -> CGContext {
        let ctx = CGContext(
            data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: min(1, max(0, r)), green: min(1, max(0, g)), blue: min(1, max(0, b)), alpha: a)
    }

    /// A fat slick seen from above: dark rubber, a lighter sidewall edge and tread grooves
    /// so it reads clearly against dark asphalt.
    static func drawTire(in ctx: CGContext, rect r: CGRect) {
        let path = CGPath(roundedRect: r, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(rgb(0.07, 0.07, 0.08))
        ctx.fillPath()

        // Tread grooves across the rolling direction.
        ctx.setFillColor(rgb(0.32, 0.32, 0.34))
        let grooves = 4
        for i in 1...grooves {
            let x = r.minX + r.width * CGFloat(i) / CGFloat(grooves + 1)
            ctx.fill(CGRect(x: x - 0.22, y: r.minY + 0.45, width: 0.44, height: r.height - 0.9))
        }

        // Light sidewall rim.
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0.55, 0.55, 0.58))
        ctx.setLineWidth(0.45)
        ctx.strokePath()
    }

    static func tireImage(size: CGSize) -> CGImage {
        let ctx = makeContext(size: size)
        drawTire(in: ctx, rect: CGRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25))
        return ctx.makeImage()!
    }

    static func bodyImage(colorIndex: Int) -> CGImage {
        let ctx = makeContext(size: spriteSize())
        ctx.translateBy(x: pad, y: pad)
        drawBody(in: ctx, colorIndex: colorIndex)
        return ctx.makeImage()!
    }

    private static func drawBody(in ctx: CGContext, colorIndex: Int) {
        let b = liveries[colorIndex % liveries.count].body
        let body = rgb(b.0, b.1, b.2)
        let dark = rgb(b.0 * 0.45, b.1 * 0.45, b.2 * 0.45)
        let light = rgb(b.0 * 0.5 + 0.5, b.1 * 0.5 + 0.5, b.2 * 0.5 + 0.5)
        let frame = rgb(0.72, 0.73, 0.76)
        let frameDark = rgb(0.3, 0.3, 0.33)
        let w = width, mid = width / 2

        // Rear axle, spanning the full width.
        ctx.setFillColor(frameDark)
        ctx.fill(CGRect(x: 3.6, y: 0.8, width: 0.9, height: w - 1.6))

        // Rear tires: the widest part of the kart.
        let rt = rearTireSize
        drawTire(in: ctx, rect: CGRect(x: 1.1, y: 0, width: rt.width, height: rt.height))
        drawTire(in: ctx, rect: CGRect(x: 1.1, y: w - rt.height, width: rt.width, height: rt.height))

        // Rear bumper bar.
        ctx.setFillColor(frameDark)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 2.2, width: 1.1, height: w - 4.4), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        ctx.fillPath()

        // Tubular chassis rails.
        ctx.setStrokeColor(frame)
        ctx.setLineWidth(0.7)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 2.2, y: 3.5, width: 16.2, height: w - 7), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
        ctx.strokePath()

        // Front stub axles out to the steerable tires.
        ctx.setFillColor(frameDark)
        for c in frontTireCenters {
            let y0 = min(c.y, mid), y1 = max(c.y, mid)
            ctx.fill(CGRect(x: c.x - 0.35, y: y0, width: 0.7, height: y1 - y0))
        }

        // Side pods (bumpers) between the wheels, in team color.
        for y in [0.9, w - 0.9 - 2.1] {
            let pod = CGPath(roundedRect: CGRect(x: 7.6, y: y, width: 7.0, height: 2.1), cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(pod)
            ctx.setFillColor(body)
            ctx.fillPath()
            ctx.addPath(pod)
            ctx.setStrokeColor(dark)
            ctx.setLineWidth(0.4)
            ctx.strokePath()
        }

        // Engine on the left side, beside the seat.
        ctx.setFillColor(rgb(0.62, 0.63, 0.66))
        ctx.fill(CGRect(x: 4.4, y: w - 3.9, width: 2.6, height: 1.6))
        ctx.setFillColor(frameDark)
        ctx.fill(CGRect(x: 4.9, y: w - 3.7, width: 1.6, height: 1.2))

        // Nose fairing ahead of the front axle.
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: 19.3, y: mid - 2.9))
        nose.addLine(to: CGPoint(x: 21.2, y: mid - 2.4))
        nose.addQuadCurve(to: CGPoint(x: 21.2, y: mid + 2.4), control: CGPoint(x: 22.4, y: mid))
        nose.addLine(to: CGPoint(x: 19.3, y: mid + 2.9))
        nose.closeSubpath()
        ctx.addPath(nose)
        ctx.setFillColor(body)
        ctx.fillPath()
        ctx.addPath(nose)
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(0.4)
        ctx.strokePath()

        // Floor pan with the number panel.
        ctx.setFillColor(rgb(0.2, 0.2, 0.23))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 13.2, y: mid - 1.9, width: 5.2, height: 3.8), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(light)
        ctx.fill(CGRect(x: 15.6, y: mid - 1.2, width: 2.2, height: 2.4))

        // Steering wheel.
        ctx.setStrokeColor(rgb(0.1, 0.1, 0.12))
        ctx.setLineWidth(0.6)
        ctx.strokeEllipse(in: CGRect(x: 13.4, y: mid - 1.5, width: 1.2, height: 3.0))

        // Seat and driver: shoulders in team color, helmet on top.
        ctx.setFillColor(rgb(0.08, 0.08, 0.09))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 5.4, y: mid - 2.1, width: 4.6, height: 4.2), cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(dark)
        ctx.fillEllipse(in: CGRect(x: 7.2, y: mid - 2.6, width: 4.4, height: 5.2))
        // Arms reaching to the wheel.
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: 10.2, y: mid - 1.9)); ctx.addLine(to: CGPoint(x: 13.4, y: mid - 1.2))
        ctx.move(to: CGPoint(x: 10.2, y: mid + 1.9)); ctx.addLine(to: CGPoint(x: 13.4, y: mid + 1.2))
        ctx.strokePath()
        // Helmet with a visor facing forward.
        let helmet = CGRect(x: 8.4, y: mid - 1.9, width: 3.8, height: 3.8)
        ctx.setFillColor(light)
        ctx.fillEllipse(in: helmet)
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(0.35)
        ctx.strokeEllipse(in: helmet)
        ctx.setFillColor(rgb(0.1, 0.12, 0.18))
        ctx.fill(CGRect(x: 11.2, y: mid - 1.1, width: 0.8, height: 2.2))
        ctx.setFillColor(body)
        ctx.fill(CGRect(x: 8.6, y: mid - 0.45, width: 2.6, height: 0.9))
    }

    /// Body plus straight front tires in one image, for previews and debugging.
    public static func previewImage(colorIndex: Int, steer: CGFloat = 0) -> CGImage {
        let size = spriteSize()
        let ctx = makeContext(size: size)
        ctx.interpolationQuality = .high
        let tire = tireImage(size: frontTireSize)
        for c in frontTireCenters {
            ctx.saveGState()
            ctx.translateBy(x: c.x + pad, y: c.y + pad)
            ctx.rotate(by: steer)
            ctx.draw(tire, in: CGRect(x: -frontTireSize.width / 2, y: -frontTireSize.height / 2,
                                      width: frontTireSize.width, height: frontTireSize.height))
            ctx.restoreGState()
        }
        ctx.draw(bodyImage(colorIndex: colorIndex), in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }
}

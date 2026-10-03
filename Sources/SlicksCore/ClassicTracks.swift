import Foundation

/// Tracks adapted from original Slicks 'n' Slide layouts.
///
/// The originals are hand-placed sprites on a 320x184 playfield, so they're traced here as
/// splines: coordinates are in original playfield pixels (x right, y down) and mapped onto our
/// 960x600 map by `o`. Road widths are in our units. The AI route stored in each `.SS` file was
/// used to confirm the driving line and race direction.
///
/// In the originals the red-and-white curbs are the barriers, so these tracks put a thin wall
/// right behind the curb (`barrierDistance` equal to the curb width).
enum ClassicTracks {
    static let all: [TrackDefinition] = [silta3, ovaali2, lasol, freeway, kisainen, eramp]

    /// Barrier right behind the curb, like the originals.
    static let curbBarrier = Track.curbWidth
    static let barrierThickness = 6.0

    /// Point on the original 320x184 playfield (y down) on our map (y up).
    static func o(_ x: Double, _ y: Double) -> Vec2 {
        Vec2(x * 3, 600 - y * 600 / 184)
    }

    /// Rectangle between two corners on the original playfield.
    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> PatchShape {
        let a = o(min(x0, x1), max(y0, y1)), b = o(max(x0, x1), min(y0, y1))
        return .rect(origin: a, size: b - a)
    }

    static func circle(_ x: Double, _ y: Double, r: Double) -> PatchShape {
        .circle(center: o(x, y), radius: r)
    }

    static func capsule(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, r: Double) -> PatchShape {
        .capsule(from: o(x0, y0), to: o(x1, y1), radius: r)
    }

    /// Control points and their road widths from (x, y, width) triples.
    static func road(_ spec: [(Double, Double, Double)]) -> (points: [Vec2], widths: [Double?]) {
        (spec.map { o($0.0, $0.1) }, spec.map { $0.2 })
    }

    /// A building or grandstand given by its corners on the original playfield. `facing` is the
    /// world direction its front (seats, doors) looks toward.
    static func building(_ kind: TrackObjectKind, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                         facing: Facing) -> TrackObject {
        let a = o(x0, y0), b = o(x1, y1)
        let center = (a + b) * 0.5
        let w = abs(b.x - a.x), h = abs(b.y - a.y)
        // The length runs across the facing direction.
        let size = facing.isVertical ? Vec2(w, h) : Vec2(h, w)
        return TrackObject(kind, at: center, size: size, angle: facing.angle)
    }

    static func tree(_ x: Double, _ y: Double, size: Double = 40, solid: Bool = true) -> TrackObject {
        TrackObject(.tree, at: o(x, y), size: Vec2(size, size), solid: solid)
    }

    /// A jump ramp centered on (x, y), launching cars in `heading`. `across` is the ramp's
    /// width across the road, `depth` its length along it.
    static func ramp(_ x: Double, _ y: Double, across: Double, depth: Double, heading: Facing) -> TrackObject {
        TrackObject(.ramp, at: o(x, y), size: Vec2(across, depth), angle: heading.rampAngle)
    }

    enum Facing {
        case north, south, east, west

        var isVertical: Bool { self == .north || self == .south }

        /// Angle that turns a building's front (local -y) this way.
        var angle: Double {
            switch self {
            case .south: 0
            case .north: .pi
            case .east: .pi / 2
            case .west: -.pi / 2
            }
        }

        /// Ramps launch toward local +y, the opposite of the way buildings face.
        var rampAngle: Double { wrapAngle(angle + .pi) }
    }

    // MARK: Silta 3

    /// "Silta" is Finnish for bridge. A long deck carries the westbound road across the middle
    /// of the map; the return leg dives under it after a hairpin at the bottom. Original by
    /// Markku Leini.
    static let silta3: TrackDefinition = {
        let r = road([
            // Start/finish on the top straight, heading east.
            (190, 30, 100), (228, 29, 100), (262, 32, 106), (280, 46, 112), (283, 70, 112), (274, 90, 100),
            (250, 99, 80),
            (118, 99, 80), // over the bridge
            (76, 99, 90), (50, 107, 100), (42, 132, 100), (58, 157, 80),
            // Narrow bottom road into the hairpin around the end of the sand spit.
            (95, 168, 62), (145, 168, 62), (176, 165, 68), (190, 149, 72), (183, 133, 72), (158, 130, 66),
            (132, 129, 76), (120, 117, 96),
            (118, 99, 100), // under the bridge
            (119, 68, 104), (124, 44, 100), (142, 30, 100), (165, 29, 100),
        ])
        return TrackDefinition(
            id: "classic-silta3",
            name: "Silta 3",
            roadWidth: 90,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 5,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            patches: [
                // Sand in the middle island and on the spit inside the hairpin.
                Patch(.sand, rect(147, 55, 250, 76)),
                Patch(.sand, rect(70, 117, 90, 136)),
                Patch(.sand, rect(90, 140, 152, 152)),
                Patch(.water, circle(28, 26, r: 48)),
            ],
            bridges: [BridgeDefinition(controlPoint: 7, back: 300, ahead: 120)],
            objects: [
                building(.grandstand, 70, 18, 86, 51, facing: .east),
                building(.grandstand, 236, 121, 270, 138, facing: .north),
                building(.pitBuilding, 208, 57, 240, 75, facing: .north),
                tree(57, 12), tree(57, 37), tree(10, 76), tree(80, 70, size: 36),
                tree(287, 128), tree(222, 146, size: 34), tree(258, 155, size: 34), tree(280, 146, size: 34),
                tree(232, 171, size: 34), tree(17, 153, size: 34), tree(33, 166, size: 44),
            ],
            looseSand: true
        )
    }()

    // MARK: Ovaali 2

    /// Wide oval around a sandy infield full of grandstands. Original by Antti Pesonen.
    static let ovaali2: TrackDefinition = {
        let r = road([
            // Start/finish on the top straight, heading west.
            (142, 27, 96), (95, 27, 96), (62, 32, 110), (46, 52, 134), (42, 80, 140), (43, 110, 140),
            (50, 138, 124), (72, 155, 100), (110, 158, 92), (160, 158, 92), (210, 158, 92), (248, 154, 104),
            (270, 136, 130), (277, 105, 148), (275, 70, 148), (264, 44, 128), (240, 30, 104), (190, 27, 96),
        ])
        return TrackDefinition(
            id: "classic-ovaali2",
            name: "Ovaali 2",
            roadWidth: 96,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 6,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            patches: [
                Patch(.sand, rect(76, 50, 244, 136)),
            ],
            objects: [
                building(.pitBuilding, 128, 52, 196, 76, facing: .north),
                building(.grandstand, 86, 72, 102, 106, facing: .west),
                building(.grandstand, 218, 72, 234, 106, facing: .east),
                building(.grandstand, 128, 100, 196, 118, facing: .south),
                tree(88, 58, size: 40), tree(232, 58, size: 40), tree(88, 124, size: 40), tree(232, 124, size: 40),
            ],
            looseSand: true
        )
    }()

    // MARK: Lasol

    /// Jumps on the first two straights, a hairpin around a post in the middle and a bulging
    /// esses section on the right. Original by Riku Vallisto.
    static let lasol: TrackDefinition = {
        let r = road([
            // Start/finish on the top straight, heading west over the first jump.
            (183, 22, 95), (144, 21, 95), (94, 21, 95), (58, 24, 100), (35, 38, 105), (27, 62, 110),
            (26, 84, 110), (27, 115, 110), (33, 145, 95), (52, 160, 88), (82, 163, 88), (102, 160, 92),
            // Up the middle, round the post and back down.
            (114, 146, 100), (116, 120, 110), (116, 92, 110), (121, 70, 100), (139, 60, 100), (157, 70, 110),
            (163, 92, 128), (163, 120, 128), (168, 145, 110), (190, 160, 95), (225, 161, 95),
            // The esses up the right side.
            (252, 157, 100), (265, 140, 100), (256, 120, 116), (228, 104, 116), (214, 90, 116), (222, 72, 116),
            (246, 58, 116), (256, 40, 100), (240, 25, 95), (215, 22, 95),
        ])
        return TrackDefinition(
            id: "classic-lasol",
            name: "Lasol",
            roadWidth: 100,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 5,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            patches: [
                // Sand heaps on the way up the middle.
                Patch(.sand, circle(122, 117, r: 20), coversRoad: true),
                Patch(.sand, circle(108, 137, r: 20), coversRoad: true),
            ],
            objects: [
                ramp(133, 22, across: 112, depth: 46, heading: .west),
                ramp(27, 82, across: 116, depth: 50, heading: .south),
                building(.grandstand, 53, 58, 69, 128, facing: .west),
                building(.grandstand, 75, 58, 91, 128, facing: .east),
                tree(11, 9, size: 36),
                tree(300, 13, size: 40), tree(300, 35, size: 40), tree(300, 68, size: 40), tree(292, 85, size: 34),
                tree(302, 101, size: 40), tree(302, 133, size: 40), tree(302, 165, size: 40),
                tree(276, 175, size: 34), tree(144, 177, size: 32),
            ],
            looseSand: true
        )
    }()

    // MARK: Freeway

    /// A broad sweep around a wooded island, widest round its pointed western tip. Original by
    /// Mike Arvela.
    static let freeway: TrackDefinition = {
        let r = road([
            // Start/finish on the kink at the top right, heading north-west.
            (250, 50, 90), (220, 53, 76), (185, 57, 76), (160, 50, 110), (135, 34, 130), (100, 26, 130),
            (62, 26, 136), (35, 36, 140), (29, 58, 140), (46, 83, 130), (75, 105, 110), (107, 132, 100),
            (150, 145, 96), (200, 147, 96), (240, 143, 100), (267, 131, 116), (274, 105, 124), (272, 75, 124),
        ])
        return TrackDefinition(
            id: "classic-freeway",
            name: "Freeway",
            roadWidth: 100,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 5,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            objects: [
                building(.grandstand, 190, 8, 227, 27, facing: .south),
                building(.grandstand, 230, 8, 267, 27, facing: .south),
            ],
            looseSand: false
        )
    }()

    // MARK: Kisainen

    /// Up a long diagonal bridge that carries the road over itself twice, round a loop at the top
    /// right, back under the bridge, then up onto a raised loop that crosses its own exit. The
    /// original's purple railings are bridge decks. Original by Markku Leini.
    static let kisainen: TrackDefinition = {
        let r = road([
            // Start/finish on the bottom straight, heading east.
            (70, 156, 90), (100, 156, 90), (125, 150, 88), (145, 134, 84),
            (164, 120, 80), // over the diagonal bridge
            (194, 99, 80), (221.5, 79, 80), (245, 62, 80),
            // Loop at the top right, back under the far end of the bridge.
            (268, 46, 80), (285, 31, 80), (280, 18, 80), (256, 17, 80), (230, 20, 80), (212, 32, 80),
            (208, 52, 82),
            (221.5, 79, 84), // under the far end
            (238, 100, 86), (262, 114, 88), (270, 134, 88), (257, 147, 86), (234, 151, 86), (205, 148, 86),
            (182, 140, 84),
            (164, 120, 84), // under the near end
            (150, 101, 80), (135, 86, 76), (118, 70, 72),
            (108, 52, 72), // up on the raised loop
            (118, 24, 70), (140, 19, 70), (163, 22, 70), (173, 36, 70), (165, 50, 70), (140, 55, 70),
            (108, 52, 72), // under the raised loop
            (82, 40, 80), (58, 30, 90), (36, 34, 96), (24, 52, 96), (22, 78, 90), (24, 100, 70),
            (27, 122, 80), (42, 145, 90), (58, 154, 90),
        ])
        return TrackDefinition(
            id: "classic-kisainen",
            name: "Kisainen",
            roadWidth: 84,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 4,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            patches: [
                // Dirt infield with a pond, and the lake on the right.
                Patch(.sand, rect(50, 80, 100, 124)),
                Patch(.water, rect(58, 127, 92, 137)),
                Patch(.water, capsule(311, 100, 314, 184, r: 45)),
            ],
            bridges: [
                // The diagonal deck reaches on over the return from the top-right loop.
                BridgeDefinition(controlPoint: 4, back: 70, ahead: 280),
                BridgeDefinition(controlPoint: 27),
            ],
            objects: [
                building(.grandstand, 62, 86, 78, 122, facing: .west),
                building(.pitBuilding, 296, 55, 316, 82, facing: .west),
                tree(282, 70, size: 36), tree(236, 124, size: 34), tree(176, 176, size: 30), tree(9, 106, size: 30),
                tree(205, 7, size: 30),
            ],
            looseSand: true
        )
    }()

    // MARK: Eramp

    /// Four open lobes: round a barrier tongue in each top lobe, circle the posts in the bottom
    /// two (crossing your own line on the way out), and back across a slippery neck at the
    /// top. Original by Jarmo Niinisalo.
    static let eramp: TrackDefinition = {
        let r = road([
            // Start/finish in the top-left lobe, heading west round the end of the tongue.
            (60, 21, 110), (38, 24, 105), (26, 36, 100), (25, 50, 100), (34, 62, 105), (58, 69, 108),
            (88, 72, 110), (106, 86, 110), (117, 101, 110),
            // Clockwise round the bottom-left post.
            (122, 116, 108), (126, 134, 105), (117, 155, 105), (98, 163, 105), (79, 154, 105), (75, 134, 105),
            (84, 118, 105), (100, 112, 105), (122, 116, 105),
            // Across to the bottom-right post and clockwise round it.
            (150, 118, 100), (178, 116, 105), (200, 113, 105), (219, 125, 105), (222, 145, 105), (206, 161, 105),
            (184, 160, 105), (172, 142, 105), (178, 116, 105),
            // Up into the top-right lobe, round its tongue and back west over the ice.
            (184, 96, 108), (200, 74, 108), (232, 69, 108), (260, 62, 105), (272, 45, 100), (262, 28, 105),
            (240, 20, 110), (212, 21, 100), (192, 22, 56), (148, 22, 56), (104, 22, 56), (84, 21, 105),
        ])
        return TrackDefinition(
            id: "classic-eramp",
            name: "Eramp",
            roadWidth: 105,
            controlPoints: r.points,
            pointWidths: r.widths,
            defaultLaps: 4,
            barrierDistance: curbBarrier,
            barrierThickness: barrierThickness,
            patches: [
                // The pale, slippery neck between the top lobes.
                Patch(.ice, rect(105, 15, 200, 29), coversRoad: true),
                // River down the left, ponds on the right.
                Patch(.water, capsule(0, 96, 38, 102, r: 22)),
                Patch(.water, capsule(38, 102, 46, 128, r: 24)),
                Patch(.water, capsule(46, 128, 36, 160, r: 30)),
                Patch(.water, capsule(36, 160, 16, 186, r: 36)),
                Patch(.water, circle(296, 65, r: 24)),
                Patch(.water, circle(250, 182, r: 36)),
            ],
            looseSand: false
        )
    }()
}

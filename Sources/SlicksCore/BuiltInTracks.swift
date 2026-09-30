import Foundation

/// Original tracks shipped with the game. All fit on a single 960x600 screen.
public enum BuiltInTracks {
    public static let all: [TrackDefinition] = [
        provingGrounds, overpass, hairpinValley, twinBridges, cloverleaf, figureEight, desertDunes, frozenLake, canyon,
        riversidePark,
    ]

    /// Parkland circuit dressed up with scenery: pit garages and a painted grid on the start
    /// straight, grandstands, trees (some solid, some to drive under), a river ford and mud.
    static let riversidePark: TrackDefinition = {
        let start = Vec2(420, 90)
        // Grid box marks just ahead of each slot, as laid out by `Track.gridSlots`.
        var grid: [PaintLine] = []
        for k in 0..<8 {
            let row = Double(k / 2)
            let left = k % 2 == 0
            let x = start.x - 24 - row * 32 - (left ? 0 : 8) + 13
            let y = start.y + (left ? 18.5 : -18.5)
            grid.append(PaintLine(points: [Vec2(x, y - 8), Vec2(x, y + 8)], width: 2, color: .white))
        }
        return TrackDefinition(
            id: "riverside-park",
            name: "Riverside Park",
            controlPoints: [
                start, Vec2(640, 90), Vec2(800, 110), Vec2(880, 200), Vec2(870, 320), Vec2(790, 380),
                Vec2(680, 370), Vec2(600, 420), Vec2(620, 500), Vec2(560, 545), Vec2(420, 540),
                Vec2(300, 500), Vec2(250, 420), Vec2(170, 400), Vec2(90, 330), Vec2(90, 200),
                Vec2(160, 110), Vec2(280, 90),
            ],
            defaultLaps: 4,
            patches: [
                // Pit lane between the garages and the start straight.
                Patch(.asphalt, .rect(origin: Vec2(270, 33), size: Vec2(380, 12))),
                // The river, with a ford across the back straight.
                Patch(.water, .capsule(from: Vec2(0, 262), to: Vec2(200, 282), radius: 15), coversRoad: true),
                Patch(.water, .capsule(from: Vec2(200, 282), to: Vec2(330, 300), radius: 15)),
                Patch(.water, .circle(center: Vec2(370, 300), radius: 44)),
                // Churned-up mud on the outside of the last hairpin.
                Patch(.mud, .circle(center: Vec2(660, 560), radius: 50)),
                Patch(.sand, .circle(center: Vec2(935, 90), radius: 60)),
            ],
            lines: grid + [
                // Pit lane edge and the pit entry and exit.
                PaintLine(points: [Vec2(270, 45), Vec2(650, 45)], width: 2, color: .white),
                PaintLine(points: [Vec2(650, 45), Vec2(700, 52)], width: 2, color: .yellow),
                PaintLine(points: [Vec2(270, 45), Vec2(220, 54)], width: 2, color: .yellow),
            ],
            objects: [
                // Jump over the river ford on the way down the left side.
                TrackObject(.ramp, at: Vec2(88, 316), size: Vec2(76, 28), angle: .pi),
                TrackObject(.pitBuilding, at: Vec2(460, 19), size: Vec2(180, 26), angle: .pi),
                TrackObject(.grandstand, at: Vec2(470, 170), size: Vec2(160, 34)),
                TrackObject(.grandstand, at: Vec2(760, 250), size: Vec2(110, 30), angle: -.pi / 2),
                // Solid trees on the outside of corners.
                TrackObject(.tree, at: Vec2(930, 430), size: Vec2(34, 34)),
                TrackObject(.tree, at: Vec2(905, 480), size: Vec2(24, 24)),
                TrackObject(.tree, at: Vec2(40, 440), size: Vec2(30, 30)),
                TrackObject(.pine, at: Vec2(30, 120), size: Vec2(26, 26)),
                TrackObject(.pine, at: Vec2(60, 60), size: Vec2(20, 20)),
                TrackObject(.tree, at: Vec2(200, 570), size: Vec2(36, 36)),
                // Decorative canopies over the infield and the river bank.
                TrackObject(.tree, at: Vec2(300, 360), size: Vec2(44, 44), solid: false),
                TrackObject(.tree, at: Vec2(430, 360), size: Vec2(30, 30), solid: false),
                TrackObject(.palm, at: Vec2(400, 250), size: Vec2(26, 26), solid: false),
                TrackObject(.tree, at: Vec2(520, 300), size: Vec2(40, 40), solid: false),
                TrackObject(.pine, at: Vec2(700, 470), size: Vec2(22, 22), solid: false),
            ]
        )
    }()

    /// Lopsided figure eight: a big right lobe, a tight left lobe, and a bridge where they cross.
    static let overpass = TrackDefinition(
        id: "overpass",
        name: "Overpass",
        controlPoints: [
            Vec2(700, 85), Vec2(820, 95), Vec2(895, 200), Vec2(885, 410), Vec2(790, 520),
            Vec2(650, 510), Vec2(560, 420),
            Vec2(440, 300), // over the bridge
            Vec2(320, 180), Vec2(215, 105), Vec2(105, 170), Vec2(75, 300), Vec2(105, 430),
            Vec2(215, 500), Vec2(320, 420),
            Vec2(440, 300), // under the bridge
            Vec2(560, 180), Vec2(630, 100),
        ],
        defaultLaps: 5,
        barrierDistance: 22,
        patches: [
            Patch(.sand, .circle(center: Vec2(935, 560), radius: 70)),
            Patch(.sand, .circle(center: Vec2(30, 40), radius: 70)),
        ],
        bridges: [BridgeDefinition(controlPoint: 7)]
    )

    /// Three lobes chained left to right, crossing at both necks on bridges.
    static let twinBridges = TrackDefinition(
        id: "twin-bridges",
        name: "Twin Bridges",
        controlPoints: [
            Vec2(480, 450), Vec2(555, 405),
            Vec2(620, 300), // over the right bridge
            Vec2(700, 200), Vec2(790, 112), Vec2(870, 160), Vec2(890, 300), Vec2(870, 440),
            Vec2(790, 488), Vec2(700, 400),
            Vec2(620, 300), // under the right bridge
            Vec2(555, 195), Vec2(480, 150), Vec2(405, 195),
            Vec2(340, 300), // over the left bridge
            Vec2(260, 400), Vec2(170, 488), Vec2(90, 440), Vec2(70, 300), Vec2(90, 160),
            Vec2(170, 112), Vec2(260, 200),
            Vec2(340, 300), // under the left bridge
            Vec2(405, 405),
        ],
        defaultLaps: 4,
        theme: .desert,
        barrierDistance: 20,
        patches: [
            Patch(.sand, .circle(center: Vec2(480, 300), radius: 55)),
            Patch(.wall, .circle(center: Vec2(480, 300), radius: 18)),
        ],
        bridges: [BridgeDefinition(controlPoint: 2), BridgeDefinition(controlPoint: 14)]
    )

    /// Highway-interchange loop: the road dives under a bridge, winds 270 degrees around a
    /// tight loop and climbs the ramp while still turning, crossing back over itself.
    static let cloverleaf = TrackDefinition(
        id: "cloverleaf",
        name: "Cloverleaf",
        controlPoints: [
            // Top straight, heading west.
            Vec2(620, 548), Vec2(420, 552), Vec2(230, 540), Vec2(100, 490),
            // Down the left side and through the bottom-left sweepers.
            Vec2(60, 370), Vec2(80, 230), Vec2(160, 120), Vec2(290, 110), Vec2(390, 190), Vec2(480, 255),
            Vec2(600, 260), // under the bridge
            // The loop: 270 degrees to the left, climbing onto the deck on the way out.
            Vec2(690, 262), Vec2(760, 295), Vec2(782, 355), Vec2(752, 420), Vec2(690, 442),
            Vec2(628, 420), Vec2(603, 350),
            Vec2(600, 260), // over the bridge
            // Down the ramp and round the right side back to the top.
            Vec2(600, 150), Vec2(640, 75), Vec2(760, 55), Vec2(880, 90), Vec2(915, 230),
            Vec2(905, 400), Vec2(860, 510), Vec2(760, 550),
        ],
        defaultLaps: 4,
        barrierDistance: 20,
        patches: [
            Patch(.sand, .circle(center: Vec2(275, 330), radius: 80)),
            Patch(.sand, .circle(center: Vec2(935, 560), radius: 60)),
            // Tire wall between the top of the loop and the top straight, so it can't be cut.
            Patch(.wall, .capsule(from: Vec2(560, 497), to: Vec2(800, 497), radius: 5)),
        ],
        bridges: [BridgeDefinition(controlPoint: 18)]
    )

    /// Handling test course: long straight into a fast right-side curve, a tight hairpin,
    /// two sharp right-handers back to back, then a flowing sweeper home.
    static let provingGrounds = TrackDefinition(
        id: "proving-grounds",
        name: "Proving Grounds",
        roadWidth: 86,
        controlPoints: [
            Vec2(330, 80), Vec2(640, 80), Vec2(820, 100), Vec2(885, 190), Vec2(880, 400),
            // Tight hairpin, top right.
            Vec2(860, 500), Vec2(805, 545), Vec2(745, 505), Vec2(732, 420),
            // Two sharp 90-degree right-handers with a short straight between.
            Vec2(728, 335), Vec2(714, 288), Vec2(672, 266), Vec2(600, 262), Vec2(520, 262),
            Vec2(470, 272), Vec2(442, 308), Vec2(432, 365), Vec2(425, 440),
            // Fast sweeper over the top and down the left side.
            Vec2(385, 515), Vec2(300, 545), Vec2(200, 525), Vec2(140, 450), Vec2(120, 300),
            Vec2(135, 165), Vec2(200, 95),
        ],
        defaultLaps: 5,
        barrierDistance: 22,
        patches: [
            Patch(.sand, .circle(center: Vec2(935, 90), radius: 70)),
            Patch(.sand, .circle(center: Vec2(50, 560), radius: 90)),
            Patch(.sand, .circle(center: Vec2(275, 300), radius: 62)),
            Patch(.wall, .circle(center: Vec2(275, 300), radius: 26)),
        ]
    )

    static let hairpinValley = TrackDefinition(
        id: "hairpin-valley",
        name: "Hairpin Valley",
        roadWidth: 72,
        controlPoints: [
            Vec2(300, 80), Vec2(720, 80), Vec2(870, 140), Vec2(870, 250), Vec2(720, 280),
            Vec2(520, 260), Vec2(470, 330), Vec2(560, 390), Vec2(820, 400), Vec2(880, 480),
            Vec2(800, 540), Vec2(300, 540), Vec2(120, 500), Vec2(90, 300), Vec2(140, 130),
        ],
        defaultLaps: 4,
        barrierDistance: 18,
        patches: [
            Patch(.wall, .capsule(from: Vec2(300, 300), to: Vec2(300, 420), radius: 6)),
            Patch(.sand, .circle(center: Vec2(420, 300), radius: 40)),
        ]
    )

    static let figureEight: TrackDefinition = {
        // Lemniscate of Bernoulli, stretched vertically. Starts on the upper-right diagonal.
        let count = 16
        let t0 = 1.15
        let points = (0..<count).map { k -> Vec2 in
            let t = t0 + Double(k) * 2 * .pi / Double(count)
            let d = 1 + sin(t) * sin(t)
            return Vec2(480 + 400 * cos(t) / d, 300 + 620 * sin(t) * cos(t) / d)
        }
        return TrackDefinition(
            id: "figure-eight",
            name: "Figure Eight",
            roadWidth: 78,
            controlPoints: points,
            defaultLaps: 5,
            barrierDistance: 26
        )
    }()

    static let desertDunes = TrackDefinition(
        id: "desert-dunes",
        name: "Desert Dunes",
        controlPoints: [
            Vec2(480, 70), Vec2(800, 80), Vec2(890, 200), Vec2(780, 300), Vec2(870, 420),
            Vec2(760, 530), Vec2(480, 500), Vec2(200, 540), Vec2(80, 420), Vec2(170, 300),
            Vec2(90, 180), Vec2(200, 80),
        ],
        defaultLaps: 4,
        theme: .desert,
        patches: [
            Patch(.sand, .circle(center: Vec2(480, 300), radius: 150)),
            Patch(.wall, .circle(center: Vec2(480, 300), radius: 28)),
            Patch(.wall, .circle(center: Vec2(620, 380), radius: 14)),
            Patch(.wall, .circle(center: Vec2(340, 220), radius: 14)),
            Patch(.sand, .circle(center: Vec2(930, 300), radius: 60)),
            Patch(.sand, .circle(center: Vec2(30, 300), radius: 60)),
            // Sand blown across the back straight.
            Patch(.sand, .rect(origin: Vec2(600, 50), size: Vec2(70, 90)), coversRoad: true),
        ]
    )

    static let frozenLake = TrackDefinition(
        id: "frozen-lake",
        name: "Frozen Lake",
        controlPoints: [
            Vec2(480, 80), Vec2(790, 85), Vec2(890, 230), Vec2(840, 440), Vec2(660, 520),
            Vec2(560, 420), Vec2(420, 420), Vec2(300, 520), Vec2(120, 440), Vec2(70, 230),
            Vec2(170, 85),
        ],
        defaultLaps: 4,
        theme: .winter,
        barrierDistance: 30,
        patches: [
            Patch(.ice, .circle(center: Vec2(930, 300), radius: 150), coversRoad: true),
            Patch(.ice, .circle(center: Vec2(490, 440), radius: 70), coversRoad: true),
            Patch(.ice, .circle(center: Vec2(480, 260), radius: 110)),
        ]
    )

    static let canyon = TrackDefinition(
        id: "canyon",
        name: "Twisty Canyon",
        roadWidth: 70,
        controlPoints: [
            Vec2(480, 70), Vec2(760, 70), Vec2(880, 150), Vec2(820, 250), Vec2(640, 230),
            Vec2(560, 300), Vec2(640, 380), Vec2(860, 390), Vec2(890, 500), Vec2(760, 545),
            Vec2(520, 520), Vec2(400, 440), Vec2(300, 540), Vec2(120, 520), Vec2(70, 380),
            Vec2(200, 300), Vec2(90, 200), Vec2(160, 80),
        ],
        defaultLaps: 3,
        theme: .desert,
        barrierDistance: 10,
        barrierThickness: 9
    )
}

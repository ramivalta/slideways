import Foundation

/// A way off the road that rejoins it further along and still counts for the lap.
public struct Shortcut: Sendable {
    /// Cell centers from where the cut leaves the road to where it rejoins.
    public var route: [Vec2]
    /// Where the cut crosses over from one stretch of road to the other.
    public var via: Vec2
    /// Road skipped minus the length driven off it (weighted by how slow the ground is).
    public var saving: Double
    /// False when lap tracking only follows some lines through it: drivers will lose laps.
    public var reliable: Bool

    public var issue: TrackIssue {
        let what = "Shortcut saves about \(Int(saving.rounded())) of road"
        return TrackIssue(message: reliable ? what : what + " but can lose the lap", position: via)
    }
}

public extension Track {
    /// Ground connections between stretches of road that lap tracking follows, so taking them
    /// gains distance. Flood-fills the drivable ground out from the road; where fronts from far
    /// apart stretches meet, drives the tracker along the route to see if the lap would count.
    func shortcuts(minSaving: Double = 80) -> [Shortcut] {
        let w = width, h = height, n = sampleCount
        guard n > 0, w > 0, h > 0 else { return [] }
        let open = drivableCells(carRadius: 5)

        var label = [Int32](repeating: -1, count: w * h)
        var parent = [Int32](repeating: -1, count: w * h)
        var hops = [Int32](repeating: 0, count: w * h)
        var queue: [Int] = []
        queue.reserveCapacity(w * h / 2)
        for i in 0..<(w * h) where open[i] {
            let s = Int(nearestSample[i])
            if s >= 0, Double(distanceField[i]) <= halfWidths[s] {
                label[i] = Int32(s)
                queue.append(i)
            }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            let x = i % w, y = i / w
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    guard open[j], label[j] < 0 else { continue }
                    label[j] = label[i]
                    parent[j] = Int32(i)
                    hops[j] = hops[i] + 1
                    queue.append(j)
                }
            }
        }

        // Best meeting per 32-unit bucket, oriented so the race runs from `a` to `b`.
        let bucket = 32
        let bw = (w + bucket - 1) / bucket
        var best: [Int: (score: Double, a: Int, b: Int)] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard label[i] >= 0 else { continue }
                for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < w && ny < h {
                    let j = ny * w + nx
                    guard label[j] >= 0 else { continue }
                    let delta = indexDelta(from: Int(label[i]), to: Int(label[j]))
                    let score = Double(abs(delta)) * spacing - Double(hops[i] + hops[j] + 1)
                    guard score >= minSaving else { continue }
                    let key = (y / bucket) * bw + x / bucket
                    if score > best[key]?.score ?? -1 {
                        best[key] = delta > 0 ? (score, i, j) : (score, j, i)
                    }
                }
            }
        }

        func center(_ i: Int) -> Vec2 { Vec2(Double(i % w) + 0.5, Double(i / w) + 0.5) }
        func chain(_ i: Int) -> [Int] {
            var out = [i], c = i
            while parent[c] >= 0 { c = Int(parent[c]); out.append(c) }
            return out
        }

        var found: [Shortcut] = []
        for m in best.values.sorted(by: { $0.score > $1.score }) {
            let cells = Array(chain(m.a).reversed()) + chain(m.b)
            let route = cells.map(center)
            let via = center(m.a)
            if found.contains(where: { $0.via.distance(to: via) < 60 }) { continue }
            let a = Int(label[cells[0]]), b = Int(label[cells[cells.count - 1]])
            // Drivers won't take the exact route: try lines beside it too.
            let offsets = [Vec2.zero] + [6.0, 12].flatMap { r in (0..<8).map { Vec2(angle: Double($0) * .pi / 4) * r } }
            let counted = offsets.filter { o in tracksProgress(route.map { $0 + o }, from: a, to: b) }.count
            guard counted > 0 else { continue }
            let gained = Double(indexDelta(from: a, to: b)) * spacing
            var cost = 0.0
            for k in 1..<route.count {
                let c = cells[k], s = Int(nearestSample[c])
                let onRoad = s >= 0 && Double(distanceField[c]) <= halfWidths[s]
                cost += route[k].distance(to: route[k - 1]) * (onRoad ? 1 : Track.offRoadCost(surfaces[c]))
            }
            let saving = gained - cost
            guard saving >= minSaving else { continue }
            found.append(Shortcut(route: route, via: via, saving: saving, reliable: counted == offsets.count))
            if found.count >= 12 { break }
        }
        return found.sorted { $0.saving > $1.saving }
    }

    /// Whether lap tracking credits a car driving `route` from sample `a` and on along the road
    /// past `b` with the whole distance.
    private func tracksProgress(_ route: [Vec2], from a: Int, to b: Int) -> Bool {
        let n = sampleCount
        let expected = indexDelta(from: a, to: b)
        guard expected > 0 else { return false }
        // On along the road to the finish line in small steps like a moving car: a tracker
        // left behind can still catch up before the lap is counted.
        let onward = max(20, n - b)
        var points = route
        for k in 1...onward {
            let from = points[points.count - 1], to = path[(b + k) % n]
            let steps = max(1, Int(from.distance(to: to).rounded(.up)))
            points += (1...steps).map { from + (to - from) * (Double($0) / Double(steps)) }
        }
        var index = a, progress = 0
        for p in points {
            let next = nearestSample(to: p, near: index)
            progress += indexDelta(from: index, to: next)
            index = next
        }
        return progress >= expected + onward - 3
    }

    /// Cells a car's center can be in: no wall within `carRadius` (as a square, so a little strict).
    private func drivableCells(carRadius r: Int) -> [Bool] {
        let w = width, h = height
        var across = [Bool](repeating: false, count: w * h)
        var prefix = [Int](repeating: 0, count: max(w, h) + 1)
        for y in 0..<h {
            for x in 0..<w { prefix[x + 1] = prefix[x] + (surfaces[y * w + x] == .wall ? 1 : 0) }
            for x in 0..<w { across[y * w + x] = prefix[min(w, x + r + 1)] > prefix[max(0, x - r)] }
        }
        var open = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            for y in 0..<h { prefix[y + 1] = prefix[y] + (across[y * w + x] ? 1 : 0) }
            for y in 0..<h {
                let edge = x < r || y < r || x >= w - r || y >= h - r
                open[y * w + x] = !edge && prefix[min(h, y + r + 1)] == prefix[max(0, y - r)]
            }
        }
        return open
    }

    /// Roughly how much slower than asphalt driving across a surface is.
    private static func offRoadCost(_ s: Surface) -> Double {
        switch s {
        case .asphalt, .wall: 1
        case .curb: 1.1
        case .ice: 1.3
        case .grass: 1.8
        case .water: 2.2
        case .mud: 2.4
        case .sand: 3
        }
    }
}

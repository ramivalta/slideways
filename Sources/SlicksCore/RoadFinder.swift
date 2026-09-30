import Foundation

/// Finds the way back to the road for computer cars that end up somewhere the racing line
/// can't be driven to directly, like an infield fenced off by tire walls that they were knocked
/// into through a gap. A coarse grid over the ground layer holds each cell's driving distance
/// to the nearest road, going around walls.
///
/// Only the ground layer is mapped: cars up on a bridge deck are kept on the road by its railings.
final class RoadFinder {
    /// Grid cell size in track pixels.
    static let cellSize = 4
    /// Grid cells a waypoint sits ahead of the car along the route.
    static let lookahead = 4

    let track: Track
    let columns: Int
    let rows: Int
    /// Driving distance to the road per grid cell, in cells. Infinity where walls are in the way
    /// or there's no way through.
    let distance: [Float]

    init(track: Track) {
        self.track = track
        let size = RoadFinder.cellSize
        let cols = (track.width + size - 1) / size, rows = (track.height + size - 1) / size
        columns = cols
        self.rows = rows

        // Any wall pixel makes its cell a wall; growing that by a cell keeps the route far
        // enough from walls for a car's body to follow it.
        var wall = [Bool](repeating: false, count: cols * rows)
        for y in 0..<track.height {
            let row = (y / size) * cols
            for x in 0..<track.width where track.surfaces[y * track.width + x] == .wall {
                wall[row + x / size] = true
            }
        }
        var blocked = wall
        for cy in 0..<rows {
            for cx in 0..<cols where wall[cy * cols + cx] {
                for ny in max(0, cy - 1)...min(rows - 1, cy + 1) {
                    for nx in max(0, cx - 1)...min(cols - 1, cx + 1) { blocked[ny * cols + nx] = true }
                }
            }
        }

        // Dijkstra outward from every open cell on the road.
        var dist = [Float](repeating: .infinity, count: cols * rows)
        var heap = MinHeap()
        for cy in 0..<rows {
            for cx in 0..<cols where !blocked[cy * cols + cx] {
                let center = Vec2(Double(cx * size) + Double(size) / 2, Double(cy * size) + Double(size) / 2)
                if track.isOnRoad(center) {
                    dist[cy * cols + cx] = 0
                    heap.push(0, cy * cols + cx)
                }
            }
        }
        let diagonal = Float(2.0.squareRoot())
        while let (d, c) = heap.pop() {
            guard d <= dist[c] else { continue }
            let cx = c % cols, cy = c / cols
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, ny >= 0, nx < cols, ny < rows else { continue }
                    let nc = ny * cols + nx
                    guard !blocked[nc] else { continue }
                    // No squeezing diagonally between two walls.
                    if dx != 0, dy != 0, blocked[cy * cols + nx] || blocked[ny * cols + cx] { continue }
                    let nd = d + (dx != 0 && dy != 0 ? diagonal : 1)
                    if nd < dist[nc] {
                        dist[nc] = nd
                        heap.push(nd, nc)
                    }
                }
            }
        }
        distance = dist
    }

    /// Driving distance from `p` back to the road in grid cells, or nil when there's no route.
    func remaining(from p: Vec2) -> Float? {
        startCell(p).map { distance[$0] }
    }

    /// A point a little way along the route from `p` back to the road, or nil when there's no
    /// route (walled in completely).
    func waypoint(from p: Vec2) -> Vec2? {
        guard var cell = startCell(p) else { return nil }
        for _ in 0..<RoadFinder.lookahead {
            guard let next = downhill(from: cell) else { break }
            cell = next
        }
        let size = Double(RoadFinder.cellSize)
        return Vec2((Double(cell % columns) + 0.5) * size, (Double(cell / columns) + 0.5) * size)
    }

    /// The car's own cell, or the best mapped cell next to it when it's pressed up against a
    /// wall (cells right by walls are left off the map).
    private func startCell(_ p: Vec2) -> Int? {
        let size = Double(RoadFinder.cellSize)
        let cx = Int(floor(p.x / size)), cy = Int(floor(p.y / size))
        var best: Int?
        var bestD = Float.infinity
        for r in 0...2 {
            for ny in (cy - r)...(cy + r) {
                for nx in (cx - r)...(cx + r) where max(abs(nx - cx), abs(ny - cy)) == r {
                    guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                    let d = distance[ny * columns + nx]
                    if d < bestD { bestD = d; best = ny * columns + nx }
                }
            }
            if best != nil { return best }
        }
        return nil
    }

    /// The neighbor closest to the road, if it's closer than this cell.
    private func downhill(from c: Int) -> Int? {
        guard distance[c] > 0 else { return nil }
        let cx = c % columns, cy = c / columns
        var best: Int?
        var bestD = distance[c]
        for ny in max(0, cy - 1)...min(rows - 1, cy + 1) {
            for nx in max(0, cx - 1)...min(columns - 1, cx + 1) {
                let d = distance[ny * columns + nx]
                if d < bestD { bestD = d; best = ny * columns + nx }
            }
        }
        return best
    }
}

extension Track {
    /// On the asphalt or curbs of the road itself, going by the centerline (whatever surface a
    /// patch has painted there).
    func isOnRoad(_ p: Vec2) -> Bool {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        let i = y * width + x
        return Double(distanceField[i]) <= halfRoad(atCell: i) + Track.curbWidth
    }

    /// Whether a wall on the ground layer lies on the straight line from `a` to `b`.
    func wallBetween(_ a: Vec2, _ b: Vec2) -> Bool {
        let d = b - a
        let steps = max(1, Int(d.length / 2))
        for k in 0...steps {
            let p = a + d * (Double(k) / Double(steps))
            if isWall(Int(floor(p.x)), Int(floor(p.y))) { return true }
        }
        return false
    }
}

/// Binary min-heap of (distance, cell) pairs for the route search.
private struct MinHeap {
    private var items: [(Float, Int)] = []

    mutating func push(_ key: Float, _ value: Int) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].0 < items[parent].0 else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (Float, Int)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        guard !items.isEmpty else { return top }
        items[0] = last
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < items.count, items[l].0 < items[m].0 { m = l }
            if r < items.count, items[r].0 < items[m].0 { m = r }
            guard m != i else { break }
            items.swapAt(i, m)
            i = m
        }
        return top
    }
}

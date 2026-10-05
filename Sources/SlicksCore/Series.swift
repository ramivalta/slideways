import Foundation

/// A championship: the same field races a run of tracks and scores points for each finish.
public struct Series: Codable, Sendable, Equatable {
    /// Points for 1st, 2nd, ... Places past the end of the table score nothing.
    public static let pointsTable = [10, 8, 6, 5, 4, 3, 2, 1]

    public static func points(forPlace place: Int) -> Int {
        pointsTable.indices.contains(place) ? pointsTable[place] : 0
    }

    public struct Standing: Equatable, Sendable {
        /// Index into `entrants`.
        public var entrant: Int
        public var points: Int
        public var wins: Int
    }

    /// Rounds in order.
    public let trackIDs: [String]
    /// The field, kept the same every round. Car ids in each race match these indices.
    public let entrants: [Entrant]
    /// Finishing order (entrant indices) of each completed round.
    public private(set) var results: [[Int]] = []

    public init(trackIDs: [String], entrants: [Entrant]) {
        precondition(!trackIDs.isEmpty, "a series needs at least one round")
        self.trackIDs = trackIDs
        self.entrants = entrants
    }

    /// Rounds completed so far.
    public var roundsCompleted: Int { results.count }
    public var isComplete: Bool { results.count >= trackIDs.count }
    public var nextTrackID: String? { isComplete ? nil : trackIDs[results.count] }

    /// Records the next round. `finishingOrder` holds entrant indices, winner first.
    public mutating func record(finishingOrder: [Int]) {
        guard !isComplete else { return }
        results.append(finishingOrder)
    }

    /// Points an entrant scored in a completed round.
    public func points(of entrant: Int, inRound round: Int) -> Int {
        guard let place = results[round].firstIndex(of: entrant) else { return 0 }
        return Series.points(forPlace: place)
    }

    /// Ranked by points, ties split on countback: most wins, then most seconds, and so on.
    public var standings: [Standing] {
        var points = Array(repeating: 0, count: entrants.count)
        var placeCounts = Array(repeating: Array(repeating: 0, count: entrants.count), count: entrants.count)
        for order in results {
            for (place, e) in order.enumerated() where entrants.indices.contains(e) {
                points[e] += Series.points(forPlace: place)
                if place < entrants.count { placeCounts[e][place] += 1 }
            }
        }
        return entrants.indices.sorted { a, b in
            if points[a] != points[b] { return points[a] > points[b] }
            if placeCounts[a] != placeCounts[b] { return placeCounts[a].lexicographicallyPrecedes(placeCounts[b], by: >) }
            return a < b
        }.map { Standing(entrant: $0, points: points[$0], wins: placeCounts[$0].first ?? 0) }
    }

    /// Series winner, once every round is run.
    public var champion: Standing? { isComplete ? standings.first : nil }
}

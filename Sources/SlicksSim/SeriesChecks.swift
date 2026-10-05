import Foundation
import SlicksCore

/// Championship scoring and standings.
func seriesChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    print("== Championship")
    let entrants = (0..<4).map { Entrant(name: "E\($0)", colorIndex: $0, playerIndex: nil) }
    var s = Series(trackIDs: ["a", "b", "c"], entrants: entrants)
    check(s.nextTrackID == "a" && !s.isComplete && s.champion == nil, "fresh series starts at round one")
    s.record(finishingOrder: [0, 1, 2, 3])
    s.record(finishingOrder: [1, 0, 3, 2])
    check(s.nextTrackID == "c", "next round follows the track order")
    // 0 and 1 are level on points and wins; 2 and 3 too, so countback falls to later places.
    check(s.standings.map(\.points) == [18, 18, 11, 11], "points add up: \(s.standings.map(\.points))")
    s.record(finishingOrder: [2, 3, 0, 1])
    check(s.isComplete && s.nextTrackID == nil, "series ends after the last round")
    s.record(finishingOrder: [3, 2, 1, 0])
    check(s.roundsCompleted == 3, "results past the last round are ignored")
    let table = s.standings
    check(table.map(\.points) == [24, 23, 21, 19], "final points: \(table.map(\.points))")
    check(table.map(\.entrant) == [0, 1, 2, 3], "final order: \(table.map(\.entrant))")
    check(s.champion?.entrant == 0 && s.champion?.wins == 1, "champion is the points leader")

    var countback = Series(trackIDs: ["a", "b"], entrants: Array(entrants.prefix(3)))
    countback.record(finishingOrder: [2, 0, 1])
    countback.record(finishingOrder: [1, 0, 2])
    // 0: 8+8 = 16, 1: 6+10 = 16, 2: 10+6 = 16. 1 and 2 each have a win; 0 has none.
    check(countback.standings.map(\.points) == [16, 16, 16], "three-way tie on points")
    check(countback.standings.last?.entrant == 0, "a tie goes to the driver with more wins")
    check(Series.points(forPlace: 8) == 0, "places past the table score nothing")
    return problems
}

import Foundation
import SlicksCore

/// Custom tracks made in the editor, stored as one JSON file each in Application Support.
public enum TrackStore {
    public static let idPrefix = "custom-"

    /// `SLIDEWAYS_TRACKS_DIR` overrides the location (used by tests and the debug harness).
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["SLIDEWAYS_TRACKS_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(GameInfo.title, isDirectory: true)
            .appendingPathComponent("Tracks", isDirectory: true)
    }

    public static func isCustom(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    public static func newID() -> String {
        idPrefix + UUID().uuidString.prefix(8).lowercased()
    }

    /// File for a track id. Ids are restricted to a safe character set so they can't escape
    /// the directory.
    static func url(for id: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard isCustom(id), id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return directory.appendingPathComponent(id + ".json")
    }

    /// All readable custom tracks, sorted by name. Unreadable or broken files are skipped.
    public static func loadAll() -> [TrackDefinition] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let def = try? JSONDecoder().decode(TrackDefinition.self, from: data) else { return nil }
                return sanitized(def, fileID: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func save(_ def: TrackDefinition) throws {
        guard let url = url(for: def.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(def).write(to: url, options: .atomic)
    }

    public static func delete(id: String) throws {
        guard let url = url(for: id) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Rejects files the game can't build and fixes up values the editor wouldn't produce.
    static func sanitized(_ def: TrackDefinition, fileID: String) -> TrackDefinition? {
        guard def.id == fileID, isCustom(def.id), def.controlPoints.count >= TrackDefinition.minControlPoints,
              def.controlPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var d = def
        // The whole track is one screen, so the map size is fixed.
        d.width = Int(EditorLimits.mapSize.width)
        d.height = Int(EditorLimits.mapSize.height)
        d.controlPoints = d.controlPoints.map(EditorLimits.clampToMap)
        let widths = EditorLimits.roadWidth
        d.roadWidth = clamp(d.roadWidth, widths.lowerBound, widths.upperBound)
        d.pointWidths = d.pointWidths.map { w in w.flatMap { $0.isFinite ? clamp($0, widths.lowerBound, widths.upperBound) : nil } }
        d.normalizeWidths()
        d.defaultLaps = clamp(d.defaultLaps, 1, 20)
        d.bridges = Array(d.bridges.filter { d.controlPoints.indices.contains($0.controlPoint) }.prefix(EditorLimits.maxBridges))
        func finite(_ v: Vec2) -> Bool { v.x.isFinite && v.y.isFinite }
        d.lines = Array(d.lines.compactMap { line -> PaintLine? in
            guard !line.points.isEmpty, line.points.allSatisfy(finite), line.width.isFinite else { return nil }
            var l = line
            l.points = Array(l.points.prefix(EditorLimits.maxLinePoints))
            l.width = clamp(l.width, EditorLimits.lineWidth.lowerBound, EditorLimits.lineWidth.upperBound)
            return l
        }.prefix(EditorLimits.maxLines))
        d.objects = Array(d.objects.compactMap { object -> TrackObject? in
            guard finite(object.position), finite(object.size), object.angle.isFinite else { return nil }
            var o = object
            o.position = EditorLimits.clampToMap(o.position)
            if o.kind.isTree {
                let s = clamp(o.size.x, EditorLimits.treeSize.lowerBound, EditorLimits.treeSize.upperBound)
                o.size = Vec2(s, s)
            } else {
                let l = EditorLimits.buildingLength, dp = EditorLimits.buildingDepth
                o.size = Vec2(clamp(o.size.x, l.lowerBound, l.upperBound), clamp(o.size.y, dp.lowerBound, dp.upperBound))
            }
            o.angle = wrapAngle(o.angle)
            return o
        }.prefix(EditorLimits.maxObjects))
        return d
    }
}

/// Ranges the editor keeps values in.
public enum EditorLimits {
    public static let mapSize = CGSize(width: 960, height: 600)
    public static let roadWidth: ClosedRange<Double> = 40...160
    public static let barrierDistance: ClosedRange<Double> = 2...120
    public static let barrierThickness: ClosedRange<Double> = 3...24
    public static let bridgeLength: ClosedRange<Double> = 20...500
    public static let patchSize: ClosedRange<Double> = 3...960
    public static let maxBridges = 16
    public static let maxPatches = 200
    public static let lineWidth: ClosedRange<Double> = 1...12
    public static let maxLines = 150
    public static let maxLinePoints = 64
    public static let treeSize: ClosedRange<Double> = 8...90
    public static let buildingLength: ClosedRange<Double> = 20...320
    public static let buildingDepth: ClosedRange<Double> = 12...120
    public static let maxObjects = 300

    /// Control points stay a little inside the map so bridge decks always have an area.
    public static func clampToMap(_ p: Vec2) -> Vec2 {
        Vec2(clamp(p.x, 4, Double(mapSize.width) - 4), clamp(p.y, 4, Double(mapSize.height) - 4))
    }
}

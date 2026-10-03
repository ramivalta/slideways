import Foundation
import SlicksCore

/// Custom tracks made in the editor, stored as one JSON file each in Application Support.
public enum TrackStore {
    public static let idPrefix = "custom-"
    public static let sharedExtension = "slideways-track"
    public static let maxSharedFileSize = 1_048_576

    private struct SharedTrack: Codable {
        var format: String
        var version: Int
        var track: TrackDefinition
    }

    public enum SharingError: LocalizedError {
        case tooLarge, unsupportedFormat, invalidTrack(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Track files must be no larger than 1 MB."
            case .unsupportedFormat: return "This track file uses an unsupported format or version."
            case let .invalidTrack(reason): return "This track can't be imported: \(reason)."
            }
        }
    }

    public static func exportData(_ track: TrackDefinition) throws -> Data {
        try validateShared(track)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SharedTrack(format: "slideways-track", version: 1, track: track))
        guard data.count <= maxSharedFileSize else { throw SharingError.tooLarge }
        return data
    }

    public static func decodeShared(_ data: Data) throws -> TrackDefinition {
        guard data.count <= maxSharedFileSize else { throw SharingError.tooLarge }
        let file = try JSONDecoder().decode(SharedTrack.self, from: data)
        guard file.format == "slideways-track", file.version == 1 else { throw SharingError.unsupportedFormat }
        try validateShared(file.track)
        var track = file.track
        track.id = idPrefix + UUID().uuidString.lowercased()
        return track
    }

    public static func importData(_ data: Data) throws -> TrackDefinition {
        let track = try decodeShared(data)
        try save(track)
        return track
    }

    public static func readShared(at url: URL) throws -> TrackDefinition {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maxSharedFileSize + 1) ?? Data()
        return try decodeShared(data)
    }

    public static func exportFilename(for track: TrackDefinition) -> String {
        filenameSlug(track.name) + "." + sharedExtension
    }

    private static func filenameSlug(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let slug = name.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "untitled" : String(slug.prefix(80))
    }

    private static func validateShared(_ track: TrackDefinition) throws {
        guard !track.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              track.name.count <= 80 else { throw SharingError.invalidTrack("invalid name") }
        guard track.curbWidth.isFinite, (0...20).contains(track.curbWidth) else {
            throw SharingError.invalidTrack("curb width")
        }
        guard (1...20).contains(track.defaultLaps) else { throw SharingError.invalidTrack("lap count") }
        if let problem = OnlineRules.trackProblem(track) { throw SharingError.invalidTrack(problem) }
        var local = track
        local.id = idPrefix + "validation"
        guard sanitized(local, fileID: local.id) == local else {
            throw SharingError.invalidTrack("values outside the editor's supported limits")
        }
    }

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
        guard url(for: def.id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let name = filenameSlug(def.name)
        let url = directory.appendingPathComponent(def.id + "--" + name + ".json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousFiles = try files(for: def.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(def).write(to: url, options: .atomic)
        for previous in previousFiles where previous != url {
            try FileManager.default.removeItem(at: previous)
        }
    }

    public static func delete(id: String) throws {
        for url in try files(for: id) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func files(for id: String) throws -> [URL] {
        guard url(for: id) != nil,
              FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && matches($0.deletingPathExtension().lastPathComponent, id: id) }
    }

    private static func matches(_ filename: String, id: String) -> Bool {
        filename == id || filename.hasPrefix(id + "--")
    }

    /// Rejects files the game can't build and fixes up values the editor wouldn't produce.
    static func sanitized(_ def: TrackDefinition, fileID: String) -> TrackDefinition? {
        guard url(for: def.id) != nil, matches(fileID, id: def.id), def.controlPoints.count >= TrackDefinition.minControlPoints,
              def.controlPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var d = def
        // The whole track is one screen, so the map size is fixed.
        d.width = Int(EditorLimits.mapSize.width)
        d.height = Int(EditorLimits.mapSize.height)
        d.controlPoints = d.controlPoints.map(EditorLimits.clampToMap)
        let widths = EditorLimits.roadWidth
        d.roadWidth = clamp(d.roadWidth, widths.lowerBound, widths.upperBound)
        d.curbWidth = d.curbWidth.isFinite
            ? clamp(d.curbWidth, EditorLimits.curbWidth.lowerBound, EditorLimits.curbWidth.upperBound) : Track.curbWidth
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
    public static let curbWidth: ClosedRange<Double> = 0...20
    public static let barrierDistance: ClosedRange<Double> = 2...120
    public static let barrierThickness: ClosedRange<Double> = 3...24
    /// How far a fixed deck end reaches from its bridge's control point.
    public static let bridgeEnd: ClosedRange<Double> = 10...400
    /// Farthest from an existing bridge's deck end a clicked crossing gets added to it instead
    /// of getting a bridge of its own.
    public static let bridgeStretchGap = 260.0
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

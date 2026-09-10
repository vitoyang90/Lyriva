import Foundation

struct WidgetSongSnapshot: Codable, Equatable, Sendable {
    static let kind = "SpotifyTransLyrics"
    static let appGroup = "group.order.SpotifyTrans"
    static let freshness: TimeInterval = 15 * 60
    let trackID: String
    let title: String
    let artist: String
    let original: String?
    let romanization: String?
    let nextOriginal: String?
    let nextRomanization: String?
    var updatedAt: Date
    var artwork: Data?

    func isExpired(at date: Date) -> Bool { date.timeIntervalSince(updatedAt) >= Self.freshness }
}

struct WidgetSnapshotStorage {
    private let directory: URL?
    init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSongSnapshot.appGroup)) {
        self.directory = directory
    }
    private var file: URL? { directory?.appendingPathComponent("current-song.json") }
    func read() -> WidgetSongSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSongSnapshot.self, from: data)
    }
    func write(_ snapshot: WidgetSongSnapshot) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clear() throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

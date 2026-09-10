import Foundation
import SwiftUI
import WidgetKit
import Testing
@testable import SpotifyTrans

struct WidgetSnapshotTests {
    @MainActor @Test func snapshotSelectsCurrentAndNextLineByID() throws {
        let track = try JSONDecoder().decode(SpotifyConnection.Track.self, from: Data(#"{"id":"song","duration_ms":10000,"name":"Song","artists":[{"name":"Artist"}],"external_urls":{}}"#.utf8))
        let document = LyricsDocument(lines: [.init(id: 10, words: "世界", startTimeMS: 1000), .init(id: 30, words: "未来", startTimeMS: 3000)], isSynced: true)
        let snapshot = WidgetSnapshotPublisher.snapshot(track: track, document: document, readings: [10: "sekai", 30: "mirai"], position: 2000)
        #expect(snapshot?.original == "世界")
        #expect(snapshot?.romanization == "sekai")
        #expect(snapshot?.nextOriginal == "未来")
        #expect(snapshot?.nextRomanization == "mirai")
        #expect(snapshot?.artist == "Artist")
        #expect(WidgetSnapshotPublisher.snapshot(track: track, document: document, readings: [:], position: 0)?.original == nil)
        #expect(WidgetSnapshotPublisher.snapshot(track: track, document: nil, readings: [10: "old song"], position: 2000)?.romanization == nil)
        let unsynced = LyricsDocument(lines: [.init(id: 9, words: "", startTimeMS: nil), .init(id: 10, words: "世界", startTimeMS: nil)], isSynced: false)
        #expect(WidgetSnapshotPublisher.snapshot(track: track, document: unsynced, readings: [:], position: nil)?.original == "世界")
    }

    @Test func snapshotStorageOverwritesSingleRecordAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory)
        #expect(storage.read() == nil)
        let old = sample(id: "old")
        try storage.write(old)
        #expect(storage.read() == old)
        let current = sample(id: "current")
        try storage.write(current)
        #expect(storage.read()?.trackID == "current")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        try storage.clear()
        #expect(storage.read() == nil)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("current-song.json"))
        #expect(storage.read() == nil)
    }

    @Test func staleSnapshotExpiresAndDoesNotContainCredentials() throws {
        let snapshot = sample(id: "current")
        #expect(!snapshot.isExpired(at: snapshot.updatedAt.addingTimeInterval(899)))
        #expect(snapshot.isExpired(at: snapshot.updatedAt.addingTimeInterval(900)))
        let data = try JSONEncoder().encode(snapshot)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(fields.keys) == ["trackID", "title", "artist", "original", "romanization", "updatedAt"])
        let unavailable = WidgetSnapshotStorage(directory: nil)
        #expect(unavailable.read() == nil)
        #expect(throws: (any Error).self) { try unavailable.write(snapshot) }
    }

    @MainActor @Test func renderWidgetSizesAndEmptyStates() throws {
        let now = Date()
        let song = WidgetSongSnapshot(trackID: "preview", title: "聽見世界，跟著唱", artist: "SpotifyTrans", original: "明日も一緒に歌おう", romanization: "asu mo issho ni utaou", nextOriginal: "世界", nextRomanization: "sekai", updatedAt: now)
        for (family, width, height) in [(WidgetFamily.systemSmall, 170.0, 170.0), (.systemMedium, 360.0, 170.0), (.systemLarge, 360.0, 376.0)] {
            for state in ["lyrics", "empty", "expired"] {
                let entry = LyricsWidgetEntry(date: state == "expired" ? now.addingTimeInterval(900) : now, song: state == "empty" ? nil : song)
                let view = LyricsWidgetView(entry: entry, familyOverride: family)
                    .environment(\.colorScheme, .dark)
                    .frame(width: width - 32, height: height - 32).padding(16)
                    .background(Color(red: 0.035, green: 0.09, blue: 0.07))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.uiImage?.cgImage)
                #expect(image.width == Int(width * 2))
                #expect(image.height == Int(height * 2))
            }
        }
    }

    private func sample(id: String) -> WidgetSongSnapshot {
        WidgetSongSnapshot(trackID: id, title: "Song", artist: "Artist", original: "世界", romanization: "sekai", nextOriginal: nil, nextRomanization: nil, updatedAt: Date(timeIntervalSince1970: 1000))
    }
}

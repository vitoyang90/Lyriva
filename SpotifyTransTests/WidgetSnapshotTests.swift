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
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count == 1)
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

    @Test func timelineSchedulesEachLyricFromPlaybackAnchorAndStopsAtSongEnd() {
        let now = Date(timeIntervalSince1970: 1000)
        var song = sample(id: "playing")
        song.playback = .init(sampledAt: now, positionMS: 2000, durationMS: 10000, lines: [
            .init(startMS: 1000, original: "世界", romanization: "sekai"),
            .init(startMS: 3000, original: "未来", romanization: "mirai"),
            .init(startMS: 7000, original: "夢", romanization: "yume")
        ])
        #expect(song.presentationDates(after: now).map { $0.timeIntervalSince(now) } == [0, 1, 5, 8])
        #expect(song.lyrics(at: now).original == "世界")
        #expect(song.lyrics(at: now.addingTimeInterval(1)).romanization == "mirai")
        #expect(song.lyrics(at: now.addingTimeInterval(5)).original == "夢")
        #expect(song.lyrics(at: now.addingTimeInterval(5)).nextOriginal == nil)
        #expect(song.isExpired(at: now.addingTimeInterval(8)))
        let entry = LyricsWidgetEntry.scheduled(song: song, at: now.addingTimeInterval(1))
        #expect(entry.song?.original == "未来")
        #expect(entry.song?.playback == nil)
        #expect(entry.song?.playbackIsPlaying == true)
        #expect(entry.isPredicted)
        #expect(LyricsWidgetEntry.scheduled(song: song, at: now.addingTimeInterval(8)).isExpired)
        // A delayed WidgetKit reload starts at the right lyric rather than replaying old entries.
        let delayed = now.addingTimeInterval(4)
        #expect(song.lyrics(at: delayed).original == "未来")
        #expect(song.presentationDates(after: delayed).map { $0.timeIntervalSince(now) } == [4, 5, 8])
    }

    @Test func timelineHandlesIntroSeekAndPausedSnapshots() {
        let now = Date(timeIntervalSince1970: 1000)
        var song = sample(id: "song")
        let lines: [WidgetSongSnapshot.PlaybackPlan.Line] = [
            .init(startMS: 1000, original: "世界", romanization: "sekai"),
            .init(startMS: 3000, original: "未来", romanization: "mirai")
        ]
        song.playback = .init(sampledAt: now, positionMS: 0, durationMS: 10000, lines: lines)
        #expect(song.lyrics(at: now).original == nil)
        #expect(song.lyrics(at: now).nextOriginal == "世界")
        song.playback = .init(sampledAt: now, positionMS: 4000, durationMS: 10000, lines: lines)
        #expect(song.lyrics(at: now).original == "未来")
        song.playback = .init(sampledAt: now, positionMS: 0, durationMS: 10000, lines: lines)
        #expect(song.presentationDates(after: now).count == 4)
        // Pausing in the app removes the prediction while retaining the current line.
        song = song.lyrics(at: now.addingTimeInterval(1))
        song.playback = nil
        #expect(song.lyrics(at: now.addingTimeInterval(5)).original == "世界")
        #expect(song.presentationDates(after: now).count == 2)
    }

    @Test func timelineRejectsInvalidTimesAndCollapsesSimultaneousLines() {
        let now = Date(timeIntervalSince1970: 1000)
        var song = sample(id: "song")
        song.playback = .init(sampledAt: now, positionMS: 0, durationMS: 10000, lines: [
            .init(startMS: 1000, original: "first", romanization: nil),
            .init(startMS: 1000, original: "last", romanization: nil)
        ])
        #expect(song.presentationDates(after: now).count == 3)
        #expect(song.lyrics(at: now.addingTimeInterval(1)).original == "last")
        song.playback = .init(sampledAt: now, positionMS: .nan, durationMS: 10000, lines: [.init(startMS: 0, original: "invalid", romanization: nil)])
        #expect(song.presentationDates(after: now).count == 2)
        #expect(song.lyrics(at: now).original == "世界")
    }

    @MainActor @Test func renderWidgetSizesAndEmptyStates() throws {
        let now = Date()
        let song = WidgetSongSnapshot(trackID: "preview", title: "範例歌曲", artist: "Lyriva", original: "明日も一緒に歌おう", romanization: "asu mo issho ni utaou", nextOriginal: "世界", nextRomanization: "sekai", updatedAt: now, authorizationID: UUID(), isPlaying: true)
        for (family, width, height) in [(WidgetFamily.systemSmall, 170.0, 170.0), (.systemMedium, 360.0, 170.0), (.systemLarge, 360.0, 376.0)] {
            for state in ["lyrics", "paused", "long-lyrics", "empty", "expired"] {
                var displayedSong = song
                if state == "long-lyrics" {
                    displayedSong.original = "沿著月光慢慢走，讓今晚的歌聲陪你到遠方，也陪你迎接天亮"
                    displayedSong.romanization = "yan zhe yue guang man man zou, rang jin wan de ge sheng pei ni dao yuan fang"
                }
                if state == "paused" { displayedSong.isPlaying = false }
                let entry = LyricsWidgetEntry(date: state == "expired" ? now.addingTimeInterval(900) : now, song: state == "empty" ? nil : displayedSong)
                let view = LyricsWidgetView(entry: entry, familyOverride: family)
                    .environment(\.colorScheme, .dark)
                    .frame(width: width - 32, height: height - 32).padding(16)
                    .background(Color(red: 0.035, green: 0.09, blue: 0.07))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.uiImage?.cgImage)
                #expect(image.width == Int(width * 2))
                #expect(image.height == Int(height * 2))
                if state == "lyrics" || state == "paused" || state == "long-lyrics" {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-controls-\(family)-\(state).png")
                    try renderer.uiImage?.pngData()?.write(to: url)
                    print("Widget preview: \(url.path)")
                }
            }
        }
    }

    private func sample(id: String) -> WidgetSongSnapshot {
        WidgetSongSnapshot(trackID: id, title: "Song", artist: "Artist", original: "世界", romanization: "sekai", nextOriginal: nil, nextRomanization: nil, updatedAt: Date(timeIntervalSince1970: 1000))
    }
}

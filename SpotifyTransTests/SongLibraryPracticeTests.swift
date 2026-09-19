import Foundation
import Testing
@testable import SpotifyTrans

struct SongLibraryPracticeTests {
    @Test func spotifyListeningModeSurvivesExternalSkipsAndEmptyPlayback() {
        for mode in ListeningMode.allCases {
            var session = ListeningSession.spotify(mode)
            for (previous, current): (String?, String?) in [("first", "next"), ("next", nil), (nil, "another"), ("another", "first")] {
                session.trackChanged(from: previous, to: current)
                #expect(session.mode(for: current) == mode)
            }
        }
    }

    @Test func favoriteSelectionCanSwitchBackToSpotifyFollowing() {
        var session = ListeningSession.favorite(trackID: "chosen", mode: .practice)
        #expect(session.mode(for: "old") == .normal)
        session.trackChanged(from: "old", to: "chosen")
        #expect(session.mode(for: "chosen") == .practice)
        session = .spotify(.practice)
        session.trackChanged(from: "chosen", to: "recommended")
        #expect(session.mode(for: "recommended") == .practice)
        session = .spotify(.normal)
        #expect(session.mode(for: "recommended") == .normal)
        session = .favorite(trackID: "chosen", mode: .practice)
        session.trackChanged(from: "chosen", to: "outside")
        #expect(session == .spotify(.normal))
    }

    private func track(_ id: String) -> SpotifyTrack {
        SpotifyTrack(id: id, duration_ms: 180000, name: "Song \(id)", artists: [.init(name: "Artist")],
                     external_urls: .init(spotify: nil), album: nil)
    }

    @Test @MainActor func favoritesPersistAndRemovalDoesNotAffectOtherSongs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("favorites.json")
        let store = SongLibrary(file: file)
        store.toggle(track("a"))
        store.toggle(track("b"))
        #expect(store.songs.map(\.id) == ["b", "a"])
        let restored = SongLibrary(file: file)
        #expect(restored.songs == store.songs)
        restored.toggle(track("a"))
        #expect(SongLibrary(file: file).songs.map(\.id) == ["b"])
        #expect(restored.error == nil)
    }

    @Test @MainActor func failedReadDoesNotOverwriteExistingCollection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("favorites.json")
        let original = Data("damaged collection".utf8)
        try original.write(to: file)
        let store = SongLibrary(file: file)
        #expect(store.error != nil)
        store.toggle(track("a"))
        #expect(try Data(contentsOf: file) == original)
        #expect(store.songs.isEmpty)
    }

    @Test func tokenizationPreservesMixedLyricsWhitespaceAndCombiningCharacters() {
        for text in ["Hello, 世界！ ありがとう", "きゃっと がっこう", "한글 가사", "cafe\u{301} 👨‍👩‍👧‍👦!", "\n  ♪  ", "sekai e issho ni"] {
            for mode in PracticeHighlight.allCases {
                for japanese in [true, false] {
                    let tokens = PracticeLyricsPlan.tokens(text, highlight: mode, japaneseReading: japanese)
                    #expect(tokens.map(\.text).joined() == text)
                }
            }
        }
        #expect(PracticeLyricsPlan.tokens("きゃ", highlight: .syllables).map(\.text) == ["きゃ"])
        #expect(PracticeLyricsPlan.tokens("sekai", highlight: .syllables, japaneseReading: true).map(\.text) == ["se", "ka", "i"])
        #expect(PracticeLyricsPlan.tokens("hello", highlight: .syllables).map(\.text) == ["hel", "lo"])
    }

    @Test func estimatedHighlightTracksPauseSeekAndLineBoundaries() throws {
        let document = LyricsDocument(lines: [
            .init(id: 1, words: "hello world", startTimeMS: 1000),
            .init(id: 2, words: "next line", startTimeMS: 3000)
        ], isSynced: true)
        let plan = PracticeLyricsPlan(document: document, readings: [:], highlight: .words, durationMS: 5000, language: .automatic)
        let line = try #require(plan.lines[1])
        #expect(line.progress(at: 999) == nil)
        #expect(PracticeLyricsPlan.activeToken(in: line.original, progress: line.progress(at: 1000)) == 0)
        #expect(PracticeLyricsPlan.activeToken(in: line.original, progress: line.progress(at: 2200)) == 2)
        // Seeking backward restores the first word.
        #expect(PracticeLyricsPlan.activeToken(in: line.original, progress: line.progress(at: 1200)) == 0)
        #expect(line.progress(at: 3000) == nil)
        #expect(plan.lines[2]?.progress(at: 5000) == nil)
        #expect(line.progress(at: .nan) == nil)
        #expect(PracticeLyricsPlan.activeToken(in: [.init(text: " ♪ ")], progress: 0.5) == nil)
    }

    @Test @MainActor func pausedPlaybackKeepsPracticeHighlightFrozen() throws {
        let connection = SpotifyConnection(restoreSession: false)
        let data = Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":2200,"item":{"id":"song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8)
        try connection.applyPlaybackResponse(data: data, response: HTTPURLResponse(url: URL(string: "https://api.spotify.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!)
        let line = PracticeLyricsPlan.Line(start: 1000, end: 5000,
            original: PracticeLyricsPlan.tokens("hello world", highlight: .words), reading: [])
        let current = line.progress(at: connection.playbackPosition(at: Date()))
        let later = line.progress(at: connection.playbackPosition(at: Date().addingTimeInterval(30)))
        #expect(current == 0.3)
        #expect(later == current)
        #expect(!connection.canPredictPlayback)
    }

    @Test func unsyncedLyricsAndInvalidLastLineDoNotInventTiming() {
        let unsynced = LyricsDocument(lines: [.init(id: 0, words: "hello", startTimeMS: nil)], isSynced: false)
        #expect(PracticeLyricsPlan(document: unsynced, readings: [:], highlight: .syllables, durationMS: 10000, language: .automatic).lines.isEmpty)
        let invalid = LyricsDocument(lines: [.init(id: 0, words: "hello", startTimeMS: 20000)], isSynced: true)
        #expect(PracticeLyricsPlan(document: invalid, readings: [:], highlight: .words, durationMS: 10000, language: .automatic).lines.isEmpty)
    }
}

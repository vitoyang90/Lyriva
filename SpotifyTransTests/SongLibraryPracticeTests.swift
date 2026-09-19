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
        #expect(PracticeLyricsPlan.activeToken(in: line.original, progress: line.progress(at: 2500)) == 2)
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

    @Test func syllablesUseSpokenBeatsInsteadOfSpellingLength() {
        let japanese = PracticeLyricsPlan.tokens("shi a kyu", highlight: .syllables, japaneseReading: true)
        #expect(japanese.filter { $0.weight > 0 }.map(\.weight) == [1, 1, 1])
        #expect(PracticeLyricsPlan.activeToken(in: japanese, progress: 0.4) == 2)
        for (text, expected) in [("gakkou", ["ga", "k", "ko", "u"]),
                                 ("kanpai", ["ka", "n", "pa", "i"]),
                                 ("issho", ["i", "s", "sho"]),
                                 ("matcha", ["ma", "t", "cha"])] {
            let tokens = PracticeLyricsPlan.tokens(text, highlight: .syllables, japaneseReading: true)
            #expect(tokens.map(\.text) == expected)
            #expect(tokens.allSatisfy { $0.weight == 1 })
        }
        let longVowel = PracticeLyricsPlan.tokens("kyō", highlight: .syllables, japaneseReading: true)
        #expect(longVowel.map(\.text) == ["kyō"])
        #expect(longVowel.first?.weight == 2)
        let english = PracticeLyricsPlan.tokens("beautiful cat", highlight: .words)
        #expect(english.filter { $0.weight > 0 }.map(\.weight) == [3, 1])
    }

    @Test func originalAndReadingShareWordBoundariesInBothModes() throws {
        let original = "世界へ hello"
        let reading = try #require(LyricsRomanizer().romanize(original, language: .japanese, japaneseContext: true))
        let document = LyricsDocument(lines: [.init(id: 7, words: original, startTimeMS: 1000)], isSynced: true)
        for mode in PracticeHighlight.allCases {
            let plan = PracticeLyricsPlan(document: document, readings: [7: reading], highlight: mode,
                                          durationMS: 7000, language: .japanese)
            let line = try #require(plan.lines[7])
            #expect(line.original.map(\.text).joined() == original)
            #expect(line.reading.map(\.text).joined() == reading)
            #expect(abs(line.original.reduce(0) { $0 + $1.weight } - line.reading.reduce(0) { $0 + $1.weight }) < 0.00001)
            let sourceEnglish = try #require(line.original.firstIndex { $0.text.hasPrefix("hel") })
            let readingEnglish = try #require(line.reading.firstIndex { $0.text.hasPrefix("hel") })
            let beforeEnglish = line.original.prefix(sourceEnglish).reduce(0) { $0 + $1.weight }
            #expect(beforeEnglish == line.reading.prefix(readingEnglish).reduce(0) { $0 + $1.weight })
            let total = line.original.reduce(0) { $0 + $1.weight }
            let progress = (beforeEnglish + 0.01) / total
            #expect(PracticeLyricsPlan.activeToken(in: line.original, progress: progress) == sourceEnglish)
            #expect(PracticeLyricsPlan.activeToken(in: line.reading, progress: progress) == readingEnglish)
        }
    }

    @Test func differentReadingsAndPunctuationArePreserved() throws {
        let document = LyricsDocument(lines: [.init(id: 1, words: "明日、きっと！", startTimeMS: 0)], isSynced: true)
        for reading in ["asu、kitto!", "ashita,  kitto!", "", "👨‍👩‍👧‍👦"] {
            let line = try #require(PracticeLyricsPlan(document: document, readings: [1: reading], highlight: .syllables,
                                                       durationMS: 5000, language: .japanese).lines[1])
            #expect(line.original.map(\.text).joined() == "明日、きっと！")
            #expect(line.reading.map(\.text).joined() == reading)
            #expect(line.reading.filter { !$0.text.contains { $0.isLetter || $0.isNumber } }.allSatisfy { $0.weight == 0 })
        }
    }
}

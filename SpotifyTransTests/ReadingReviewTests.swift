import Foundation
import Testing
@testable import SpotifyTrans

struct ReadingReviewTests {
    private func document(_ text: String, id: Int = 42) -> LyricsDocument {
        .init(lines: [.init(id: id, words: text, startTimeMS: 1000)], isSynced: true)
    }

    private func issues(_ text: String, reading: String? = nil, language: LyricsLanguage = .japanese) -> [ReadingIssue] {
        ReadingReview().issues(document: document(text), readings: reading.map { [42: $0] } ?? [:], language: language)[42] ?? []
    }

    @Test func candidatesUseWholeWordsAndKeepOccurrenceRanges() {
        let text = "二人と二人で上手に歌う"
        let found = issues(text)
        let pairs = found.filter { $0.original == "二人" }
        #expect(pairs.count == 2)
        #expect(Set(pairs.map(\.id)).count == 2)
        #expect(pairs.allSatisfy { $0.candidates.map(\.reading) == ["futari", "ninin"] })
        #expect(!found.contains { $0.original == "二" || $0.original == "上" })
        #expect(found.contains { $0.original == "上手" && $0.candidates.count == 3 })
        for issue in found {
            #expect((text as NSString).substring(with: issue.range) == issue.original)
        }
        #expect(!issues("学生と先生と二度").contains { ["生", "二"].contains($0.original) })
    }

    @Test func isolatedPolyphonicKanjiOfferTwoOrThreeCandidates() {
        for text in ["二", "生", "上", "生物", "明日", "今日"] {
            let found = issues(text)
            #expect(found.contains { $0.original == text && (2...3).contains($0.candidates.count) })
        }
    }

    @Test func anomaliesHaveCandidatesButEnglishAndChineseAreNotRelabeled() {
        let sokuon = issues("しまった", reading: "shima~tsu ta")
        #expect(sokuon.first?.reason == .sokuon)
        #expect(sokuon.first?.candidates.first?.reading == "shimatta")
        let particle = issues("君を", reading: "kimi wo")
        #expect(particle.first?.reason == .particle)
        #expect(particle.first?.candidates.first?.reading == "kimi o")
        let strange = issues("歌う", reading: "xqrr")
        #expect(strange.first?.reason == .unusual)
        #expect(strange.first?.candidates.first?.reading == "utau")
        #expect(issues("Hello wo ~tsu", reading: "Hello wo ~tsu").isEmpty)
        #expect(issues("我愛你", language: .automatic).isEmpty)
        #expect(issues("wo 君を", reading: "wo kimi o").allSatisfy { $0.reason != .particle })
        #expect(!ReadingReview.looksUnusual("kyō ashita matcha shin'ya"))
        #expect(ReadingReview.looksUnusual("qzx"))
        let unknown = issues("𠮷")
        #expect(!unknown.isEmpty)
        #expect(unknown.allSatisfy { $0.original == "𠮷" })
    }

    @Test func overridesOnlyReplaceExactSourceSpansAndPreserveEnglish() throws {
        let source = "Hello 二人と二人!"
        let found = issues(source).filter { $0.original == "二人" }
        let first = try #require(found.first)
        let replacement = try #require(first.replacement(for: "reading:ninin"))
        let engine = LyricsRomanizer()
        let output = try #require(engine.romanize(source, language: .japanese, japaneseContext: true, overrides: [replacement]))
        #expect(output.hasPrefix("Hello ninin"))
        #expect(output.hasSuffix("!"))
        let untouchedTail = try #require(engine.romanize("と二人!", language: .japanese, japaneseContext: true))
        #expect(output == "Hello ninin " + untouchedTail)
        let baseline = engine.romanize(source, language: .japanese, japaneseContext: true)
        #expect(engine.romanize(source, language: .japanese, japaneseContext: true,
                               overrides: [.init(range: first.range, original: "別の語", reading: "bad")]) == baseline)
        #expect(first.replacement(for: "reading:made-up") == nil)
    }

    @Test func readingOverridesKeepFollowingTopicParticleAsWa() {
        let engine = LyricsRomanizer()
        let source = "明日は花を"
        let output = engine.romanize(source, language: .japanese, japaneseContext: true,
            overrides: [.init(range: NSRange(location: 0, length: 2), original: "明日", reading: "ashita")])
        #expect(output == "ashita wa hana o")
    }

    @Test func songSpecificReadingsOfferWholeWordChoices() throws {
        let source = "永遠に、もう一度だけ永遠に"
        let found = issues(source)
        let eternal = found.filter { $0.original == "永遠" }
        #expect(eternal.count == 2)
        #expect(eternal.allSatisfy { $0.candidates.map(\.reading) == ["eien", "towa"] })
        let first = try #require(eternal.first)
        let output = LyricsRomanizer().romanize(source, language: .japanese, japaneseContext: true,
            overrides: [try #require(first.replacement(for: "reading:towa"))])
        #expect(output == "towa ni、mou ichido dake eien ni")
        let once = try #require(found.first { $0.original == "一度" })
        #expect(once.current == "ichido")
        #expect(once.candidates.map(\.reading) == ["ichido", "hitotabi"])
        let vow = "永遠の誓い"
        let vowIssue = try #require(issues(vow).first { $0.original == "永遠" })
        #expect(LyricsRomanizer().romanize(vow, language: .japanese, japaneseContext: true,
            overrides: [try #require(vowIssue.replacement(for: "reading:towa"))]) == "towa no chikai")
        #expect(!issues("永遠性と十一度").contains { ["永遠", "一度"].contains($0.original) })
        #expect(!issues("永遠愛你", language: .automatic).contains { $0.original == "永遠" })
    }

    @Test @MainActor func towaChoicePersistsOnlyForTheSelectedSongAndIchidoIsAutomatic() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let source = "永遠に、もう一度"
        let lyrics = document(source)
        let store = PhoneLyricsStore(preferences: ReadingPreferences(file: file), fetch: { _ in lyrics })
        await store.load(trackID: "towa-song", language: .automatic)
        #expect(store.readings[42] == "eien ni、mou ichido")
        let issue = try #require(store.readingIssues[42]?.first { $0.original == "永遠" })
        await store.chooseReading("reading:towa", issueID: issue.id, lineID: 42,
                                  trackID: "towa-song", originalLine: source)
        #expect(store.readings[42] == "towa ni、mou ichido")
        #expect(store.document?.lines.first?.words == source)
        let reloaded = PhoneLyricsStore(preferences: ReadingPreferences(file: file), fetch: { _ in lyrics })
        await reloaded.load(trackID: "towa-song", language: .automatic)
        #expect(reloaded.readings[42] == "towa ni、mou ichido")
        await reloaded.load(trackID: "eien-song", language: .automatic)
        #expect(reloaded.readings[42] == "eien ni、mou ichido")
        await store.chooseReading(nil, issueID: issue.id, lineID: 42,
                                  trackID: "towa-song", originalLine: source)
        #expect(store.readings[42] == "eien ni、mou ichido")
    }

    @Test @MainActor func choicesPersistRestoreAndDoNotLeakToOtherSongs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("choices.json")
        let lyrics = document("二人で歌う")
        let store = PhoneLyricsStore(preferences: ReadingPreferences(file: file), fetch: { _ in lyrics })
        await store.load(trackID: "song-a", language: .japanese)
        let baseline = store.readings[42]
        let issue = try #require(store.readingIssues[42]?.first { $0.original == "二人" })
        await store.chooseReading("reading:futari", issueID: issue.id, lineID: 42, trackID: "song-a", originalLine: "二人で歌う")
        #expect(store.readings[42]?.contains("futari") == true)
        let reloaded = PhoneLyricsStore(preferences: ReadingPreferences(file: file), fetch: { _ in lyrics })
        await reloaded.load(trackID: "song-a", language: .japanese)
        #expect(reloaded.readings[42] == store.readings[42])
        #expect(reloaded.readingChoices[issue.id] == "reading:futari")
        await reloaded.load(trackID: "song-b", language: .japanese)
        #expect(reloaded.readingChoices.isEmpty)
        await reloaded.chooseReading("reading:futari", issueID: issue.id, lineID: 42, trackID: "song-a", originalLine: "二人で歌う")
        #expect(reloaded.readingChoices.isEmpty)
        await store.chooseReading(nil, issueID: issue.id, lineID: 42, trackID: "song-a", originalLine: "二人で歌う")
        #expect(store.readings[42] == baseline)
        #expect(ReadingPreferences(file: file).choices.isEmpty)
        await store.chooseReading("original", issueID: issue.id, lineID: 42, trackID: "song-a", originalLine: "二人で歌う")
        #expect(store.readings[42]?.contains("二人") == true)
    }

    @Test @MainActor func concurrentChoicesOnDifferentLinesBothUpdate() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let lyrics = LyricsDocument(lines: [.init(id: 4, words: "二人で歌う", startTimeMS: 0),
                                            .init(id: 9, words: "明日も歌う", startTimeMS: 3000)], isSynced: true)
        let store = PhoneLyricsStore(preferences: ReadingPreferences(file: file), fetch: { _ in lyrics })
        await store.load(trackID: "song", language: .japanese)
        let first = try #require(store.readingIssues[4]?.first)
        let second = try #require(store.readingIssues[9]?.first)
        async let a: Void = store.chooseReading("reading:futari", issueID: first.id, lineID: 4, trackID: "song", originalLine: "二人で歌う")
        async let b: Void = store.chooseReading("reading:ashita", issueID: second.id, lineID: 9, trackID: "song", originalLine: "明日も歌う")
        _ = await (a, b)
        #expect(store.readings[4]?.contains("futari") == true)
        #expect(store.readings[9]?.contains("ashita") == true)
    }

    @Test @MainActor func corruptPreferencesAreNotOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("invalid saved choices".utf8)
        try original.write(to: file)
        let preferences = ReadingPreferences(file: file)
        #expect(!preferences.set("reading:futari", key: "example"))
        #expect(preferences.error != nil)
        #expect(try Data(contentsOf: file) == original)
    }
}

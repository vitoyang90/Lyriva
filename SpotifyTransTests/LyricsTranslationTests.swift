import Foundation
import Testing
import Translation
import NaturalLanguage
@testable import SpotifyTrans

@MainActor
struct LyricsTranslationTests {
    @Test func downloadedModelsSortBeforeMissingAndUnsupportedModels() {
        let codes = ["fr", "ko", "ja", "en"]
        let statuses: [String: LanguageAvailability.Status] = ["fr": .supported, "ko": .unsupported, "ja": .installed, "en": .installed]
        let ordered = TranslationModels.orderedCodes(codes, statuses: statuses, preferred: ["fr", "en"])
        #expect(ordered == ["en", "ja", "fr", "ko"])
        var downloaded = statuses
        downloaded["fr"] = .installed
        #expect(TranslationModels.orderedCodes(codes, statuses: downloaded, preferred: ["fr", "en"]) == ["fr", "en", "ja", "ko"])
    }

    @Test func modelCatalogIncludesAllSystemLanguagesAndPreservesVariants() {
        let codes = TranslationModels.languageCodes(from: ["ja", "fr", "de", "es", "tr", "pt-BR", "zh-Hant", "zh-Hans", "fr"].map { Locale.Language(identifier: $0) })
        #expect(codes.contains("fr"))
        #expect(codes.contains("de"))
        #expect(codes.contains("tr"))
        #expect(codes.contains(Locale.Language(identifier: "pt-BR").minimalIdentifier))
        #expect(codes.filter { $0 == "fr" }.count == 1)
        #expect(!codes.contains { $0.hasPrefix("zh") })
        #expect(TranslationModels.name("fr") != "未知語言")
    }

    @Test func detectionAcceptsConfidentLanguagesWithoutThreeLanguageRestriction() {
        #expect(LyricsTranslationPlan.confidentLanguage([.french: 0.95, .english: 0.05], letterCount: 30) == "fr")
        #expect(LyricsTranslationPlan.confidentLanguage([.turkish: 0.95, .english: 0.05], letterCount: 30) == "tr")
        #expect(LyricsTranslationPlan.confidentLanguage([.turkish: 0.95, .english: 0.05], letterCount: 4) == nil)
        #expect(LyricsTranslationPlan.confidentLanguage([.french: 0.55, .spanish: 0.45], letterCount: 50) == nil)
    }

    @Test func frenchLyricsCanRequestMissingModel() async {
        var checked: [String] = []
        let store = LyricsTranslationStore(availabilityCheck: { code in
            checked.append(code)
            return .supported
        })
        await store.configure(input(texts: ["Je voudrais voyager avec toi dans le monde entier"], language: .automatic), enabled: true)
        #expect(checked == ["fr"])
        #expect(store.missingLanguages == ["fr"])
        #expect(store.configuration == nil)
    }

    @Test func missingModelsNeverCreateTranslationSession() async {
        var checked: [String] = []
        let store = LyricsTranslationStore(availabilityCheck: { code in
            checked.append(code)
            return .supported
        })
        await store.configure(input(texts: ["君と歌う", "Stay"], language: .japanese), enabled: true)
        #expect(checked == ["ja", "en"])
        #expect(store.missingLanguages == ["ja", "en"])
        #expect(store.configuration == nil)
        #expect(!store.loading)
        #expect(store.message == "需要下載日文、英文翻譯模型")
    }

    @Test func unavailableLanguageDoesNotBlockInstalledLanguage() async {
        let store = LyricsTranslationStore(availabilityCheck: { $0 == "ja" ? .supported : .installed })
        await store.configure(input(texts: ["君と歌う", "Stay"], language: .japanese), enabled: true)
        #expect(store.missingLanguages == ["ja"])
        #expect(store.configuration?.source?.languageCode?.identifier == "en")
    }

    @Test func unsupportedModelsDoNotOfferDownload() async {
        let store = LyricsTranslationStore(availabilityCheck: { _ in .unsupported })
        await store.configure(input(texts: ["君と歌う"], language: .japanese), enabled: true)
        #expect(store.missingLanguages.isEmpty)
        #expect(store.configuration == nil)
        #expect(store.message == "此裝置不支援日文翻譯。")
    }

    @Test func retryRechecksModelsAfterInstallation() async {
        var installed = false
        let store = LyricsTranslationStore(availabilityCheck: { _ in installed ? .installed : .supported })
        let song = input(texts: ["君と歌う"], language: .japanese)
        await store.configure(song, enabled: true)
        #expect(store.configuration == nil)
        installed = true
        await store.configure(song, enabled: true)
        #expect(store.missingLanguages.isEmpty)
        #expect(store.configuration?.source?.languageCode?.identifier == "ja")
    }

    private func input(track: String = "song", texts: [String] = ["Hello world", "Good morning"],
                       language: LyricsLanguage = .other) -> LyricsTranslationInput {
        LyricsTranslationInput(trackID: track,
            document: LyricsDocument(lines: texts.enumerated().map {
                .init(id: $0.offset * 10 + 7, words: $0.element, startTimeMS: Double($0.offset * 1000))
            }, isSynced: true), language: language)
    }

    @Test func mixedJapaneseAndEnglishUseSeparateLanguageBatches() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["君と歌う", "I will always love you", "Stay", "I"], language: .automatic)
        await store.configure(song, enabled: true)
        var languages: [String] = []
        await store.translate(song) { requests in
            let language = requests.first!.sourceLanguage!
            languages.append(language)
            #expect(requests.allSatisfy { $0.sourceLanguage == language })
            return requests.map { .init(id: $0.id, source: $0.text, text: language == "ja" ? "與你歌唱" : "英文譯文") }
        }
        #expect(languages == ["ja", "en"])
        #expect(store.translations.count == 4)
    }

    @Test func mixedLineIsReassembledOnlyAfterBothLanguagesComplete() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["君と I love you いつまでも", "君と I love you いつまでも"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            if requests.first?.sourceLanguage == "en" { #expect(store.translations.isEmpty) }
            return requests.reversed().map {
                .init(id: $0.id, source: $0.text, text: ["君と": "與你", "I love you": "我愛你", "いつまでも": "直到永遠"][$0.text]!)
            }
        }
        #expect(store.translations == [7: "與你 我愛你 直到永遠", 17: "與你 我愛你 直到永遠"])
    }

    @Test func failedLanguageDoesNotBlockOthersAndRetryOnlyRequestsMissingParts() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["君と歌う", "Hello", "Hello ありがとう"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            if requests.first?.sourceLanguage == "ja" { throw URLError(.notConnectedToInternet) }
            return requests.map { .init(id: $0.id, source: $0.text, text: "你好") }
        }
        #expect(store.translations == [17: "你好"])
        #expect(!store.loading)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.allSatisfy { $0.sourceLanguage == "ja" })
            return requests.map { .init(id: $0.id, source: $0.text, text: $0.text == "ありがとう" ? "謝謝" : "與你歌唱") }
        }
        #expect(store.translations[27] == "你好 謝謝")
        #expect(store.translations.count == 3)
    }

    @Test func shortEnglishRefrainsNeverRequestTurkishInJapaneseSongs() {
        let song = input(texts: ["君と歌う", "I", "Stay", "Love", "Oh", "Don’t go", "ハート"], language: .automatic)
        let plan = LyricsTranslationPlan(song)
        #expect(plan.requests.filter { ["I", "Stay", "Love", "Oh", "Don’t go"].contains($0.text) }.allSatisfy { $0.sourceLanguage == "en" })
        #expect(plan.requests.contains { $0.text == "ハート" && $0.sourceLanguage == "ja" })
        #expect(!plan.groups(excluding: []).contains { $0.source?.languageCode?.identifier == "tr" })
    }

    @Test func chinesePartsInMixedSongsAreConvertedWithoutBeingSentToEnglishSession() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["这是我们的世界，我们一起听音乐", "Hello world"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.map(\.text) == ["Hello world"])
            #expect(requests.first?.sourceLanguage == "en")
            return requests.map { .init(id: $0.id, source: $0.text, text: "你好，世界") }
        }
        #expect(store.translations[7] == "這是我們的世界，我們一起聽音樂")
        #expect(store.translations[17] == "你好，世界")
    }

    @Test func outOfOrderResultsAndRepeatedChorusesKeepOriginalLineIDs() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["Hello world", "♪", "Good morning", "Hello world", "   "])
        await store.configure(song, enabled: true)
        await store.translate(song) { lines in
            #expect(lines.map(\.id) == ["7", "27"])
            return [.init(id: "27", source: "Good morning", text: "早安"),
                    .init(id: "7", source: "Hello world", text: "你好，世界")]
        }
        #expect(store.translations == [7: "你好，世界", 27: "早安", 37: "你好，世界"])
        #expect(!store.loading)
        #expect(store.message == nil)
    }

    @Test func disabledTranslationDoesNoWorkAndCompletedSongIsReused() async {
        let store = LyricsTranslationStore()
        let song = input()
        await store.configure(song, enabled: false)
        await store.translate(song) { _ in Issue.record("Disabled translation must not run"); return [] }
        await store.configure(song, enabled: true)
        await store.translate(song) { lines in
            lines.map { .init(id: String($0.id), source: $0.text, text: "中文") }
        }
        await store.configure(song, enabled: false)
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in Issue.record("Completed lyrics must not be translated again"); return [] }
        #expect(store.translations.count == 2)
    }

    @Test func changingSongDiscardsLateResults() async {
        let store = LyricsTranslationStore()
        let first = input(track: "first")
        let second = input(track: "second", texts: ["A new song"])
        await store.configure(first, enabled: true)
        var resume: CheckedContinuation<[LyricsTranslationStore.Result], Never>?
        let old = Task {
            await store.translate(first) { _ in
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        await store.configure(second, enabled: true)
        await store.translate(second) { lines in
            [.init(id: String(lines[0].id), source: lines[0].text, text: "新歌")]
        }
        resume?.resume(returning: [.init(id: "7", source: "Hello world", text: "舊歌")])
        await old.value
        #expect(store.translations == [7: "新歌"])
        #expect(store.message == nil)
    }

    @Test func disablingWhileTranslationIsInFlightIgnoresItsResult() async {
        let store = LyricsTranslationStore()
        let song = input()
        await store.configure(song, enabled: true)
        var resume: CheckedContinuation<[LyricsTranslationStore.Result], Never>?
        let pending = Task {
            await store.translate(song) { _ in await withCheckedContinuation { resume = $0 } }
        }
        while resume == nil { await Task.yield() }
        await store.configure(song, enabled: false)
        resume?.resume(returning: [.init(id: "7", source: "Hello world", text: "你好")])
        await pending.value
        #expect(store.translations.isEmpty)
        #expect(!store.loading)
    }

    @Test func missingOrMismatchedLinesCanBeRetriedWithoutInventingSubtitles() async {
        let store = LyricsTranslationStore()
        let song = input()
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in
            [.init(id: "7", source: "Hello world", text: "你好"),
             .init(id: "17", source: "Wrong source", text: "不該顯示"),
             .init(id: "999", source: "Good morning", text: "不該顯示")]
        }
        #expect(store.translations == [7: "你好"])
        #expect(store.message?.contains("部分") == true)
        await store.configure(song, enabled: true)
        await store.translate(song) { lines in
            lines.map { .init(id: String($0.id), source: $0.text, text: "譯文") }
        }
        #expect(store.translations.count == 2)
        #expect(store.message == nil)
    }

    @Test func translationFailureDoesNotLeaveLoadingAndCanRetry() async {
        let store = LyricsTranslationStore()
        let song = input()
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in throw URLError(.cancelled) }
        #expect(!store.loading)
        #expect(store.message?.contains("重試") == true)
        await store.configure(song, enabled: true)
        await store.translate(song) { lines in
            lines.map { .init(id: String($0.id), source: $0.text, text: "中文") }
        }
        #expect(store.translations.count == 2)
    }

    @Test func chineseLyricsUseTraditionalCharactersWithoutTranslatingTheSameLanguage() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["这是我们的世界，我们一起听音乐"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in Issue.record("Chinese does not need a translation session"); return [] }
        #expect(store.translations[7] == "這是我們的世界，我們一起聽音樂")
        #expect(store.configuration == nil)
    }

    @Test func changedWordsWithSameTrackIDInvalidateCachedTranslation() async {
        let store = LyricsTranslationStore()
        let old = input(texts: ["Hello world"])
        await store.configure(old, enabled: true)
        await store.translate(old) { _ in [.init(id: "7", source: "Hello world", text: "你好")] }
        let refreshed = input(texts: ["Good morning"])
        await store.configure(refreshed, enabled: true)
        #expect(store.translations.isEmpty)
        await store.translate(refreshed) { _ in [.init(id: "7", source: "Good morning", text: "早安")] }
        #expect(store.translations == [7: "早安"])
    }

    @Test func cancelledTaskStopsLoadingAndDoesNotPublishSubtitles() async {
        let store = LyricsTranslationStore()
        let song = input()
        await store.configure(song, enabled: true)
        var resume: CheckedContinuation<[LyricsTranslationStore.Result], Never>?
        let pending = Task {
            await store.translate(song) { _ in
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        pending.cancel()
        resume?.resume(returning: [.init(id: "7", source: "Hello world", text: "你好")])
        await pending.value
        #expect(!store.loading)
        #expect(store.translations.isEmpty)
        #expect(store.message == "翻譯已取消。")
        await store.configure(song, enabled: true)
        await store.translate(song) { lines in
            lines.map { .init(id: String($0.id), source: $0.text, text: "中文") }
        }
        #expect(store.translations.count == 2)
    }
}

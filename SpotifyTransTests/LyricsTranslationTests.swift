import Foundation
import Testing
import Translation
import NaturalLanguage
@testable import SpotifyTrans

@MainActor
struct LyricsTranslationTests {
    @Test func qualityStrategyIsConsistentAcrossAvailabilityAndDownloadConfiguration() {
        let source = Locale.Language(identifier: "ja")
        let configuration = TranslationModels.configuration(source: source)
        #expect(configuration.source == source)
        #expect(configuration.target == TranslationModels.target)
        if #available(iOS 26.4, *) {
            #expect(TranslationModels.availability().preferredStrategy == .highFidelity)
            #expect(configuration.preferredStrategy == .highFidelity)
        }
    }

    @Test func qualityStrategySurvivesLanguageChangesAndRetryWithoutLosingCompletedLyrics() async {
        let store = LyricsTranslationStore(availabilityCheck: { _ in .installed })
        let song = input(texts: ["君と歌う", "Hello world"], language: .automatic)
        await store.configure(song, enabled: true)
        #expect(store.configuration?.source?.languageCode?.identifier == "ja")
        if #available(iOS 26.4, *) {
            #expect(store.configuration?.preferredStrategy == .highFidelity)
        }
        var configurations: [TranslationSession.Configuration] = []
        await store.translate(song) { requests in
            if let configuration = store.configuration { configurations.append(configuration) }
            if requests.first?.sourceLanguage == "en" { throw URLError(.timedOut) }
            return requests.map { .init(id: $0.id, source: $0.text, text: "與你歌唱") }
        }
        #expect(configurations.compactMap { $0.source?.languageCode?.identifier } == ["ja", "en"])
        #expect(store.translations == [7: "與你歌唱"])
        await store.configure(song, enabled: true)
        #expect(store.configuration?.source?.languageCode?.identifier == "en")
        if let configuration = store.configuration { configurations.append(configuration) }
        if #available(iOS 26.4, *) {
            #expect(configurations.allSatisfy { $0.preferredStrategy == .highFidelity })
        }
        await store.translate(song) { requests in
            #expect(requests.map(\.text) == ["Hello world"])
            return requests.map { .init(id: $0.id, source: $0.text, text: "你好，世界") }
        }
        #expect(store.translations == [7: "與你歌唱", 17: "你好，世界"])
        #expect(store.message == nil)
    }

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
        #expect(checked == ["fr", "fr"])
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
        #expect(checked == ["ja", "ja", "en", "en"])
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

    @Test func transientModelStatusRecoversBeforeOfferingDownload() async {
        var checks = 0
        let store = LyricsTranslationStore(availabilityCheck: { _ in
            checks += 1
            return checks == 1 ? .supported : .installed
        }, availabilityRetryDelay: .zero)
        await store.configure(input(texts: ["君と歌う"], language: .japanese), enabled: true)
        #expect(checks == 2)
        #expect(store.missingLanguages.isEmpty)
        #expect(store.message == nil)
        #expect(store.configuration?.source?.languageCode?.identifier == "ja")
    }

    @Test func missingModelRefreshResumesWithoutNavigationAndKeepsCompletedLyrics() async {
        var japaneseInstalled = false
        let store = LyricsTranslationStore(availabilityCheck: { code in
            code == "en" || japaneseInstalled ? .installed : .supported
        }, availabilityRetryDelay: .zero)
        let song = input(texts: ["君と歌う", "Hello"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.allSatisfy { $0.sourceLanguage == "en" })
            return requests.map { .init(id: $0.id, source: $0.text, text: "你好") }
        }
        #expect(store.translations == [17: "你好"])
        #expect(store.missingLanguages == ["ja"])
        japaneseInstalled = true
        await store.refreshMissingModels(song)
        #expect(store.translations == [17: "你好"])
        #expect(store.missingLanguages.isEmpty)
        #expect(store.message == nil)
        #expect(store.configuration?.source?.languageCode?.identifier == "ja")
        await store.translate(song) { requests in
            #expect(requests.allSatisfy { $0.sourceLanguage == "ja" })
            return requests.map { .init(id: $0.id, source: $0.text, text: "與你歌唱") }
        }
        #expect(store.translations == [7: "與你歌唱", 17: "你好"])
        #expect(!store.loading)
        #expect(store.message == nil)
    }

    @Test func genuinelyMissingModelStaysUnavailableAfterRefresh() async {
        let store = LyricsTranslationStore(availabilityCheck: { _ in .supported }, availabilityRetryDelay: .zero)
        let song = input(texts: ["君と歌う"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.refreshMissingModels(song)
        #expect(store.missingLanguages == ["ja"])
        #expect(store.configuration == nil)
        #expect(!store.loading)
        #expect(store.message == "需要下載日文翻譯模型")
    }

    @Test func laterMissingLanguageAlsoRecoversAfterEarlierLanguageCompletes() async {
        var installed = false
        let store = LyricsTranslationStore(availabilityCheck: { code in
            code == "ja" || installed ? .installed : .supported
        }, availabilityRetryDelay: .zero)
        let song = input(texts: ["君と歌う", "Hello"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.allSatisfy { $0.sourceLanguage == "ja" })
            return requests.map { .init(id: $0.id, source: $0.text, text: "與你歌唱") }
        }
        #expect(store.missingLanguages == ["en"])
        installed = true
        await store.refreshMissingModels(song)
        #expect(store.configuration?.source?.languageCode?.identifier == "en")
        #expect(store.translations == [7: "與你歌唱"])
    }

    @Test func changingSongsIgnoresLateModelRefresh() async {
        var resume: CheckedContinuation<LanguageAvailability.Status, Never>?
        var refreshing = false
        let store = LyricsTranslationStore(availabilityCheck: { code in
            if code == "en" { return .installed }
            if refreshing { return await withCheckedContinuation { resume = $0 } }
            return .supported
        }, availabilityRetryDelay: .zero)
        let oldSong = input(texts: ["君と歌う"], language: .japanese)
        await store.configure(oldSong, enabled: true)
        refreshing = true
        let pending = Task { await store.refreshMissingModels(oldSong) }
        while resume == nil { await Task.yield() }
        await store.configure(input(track: "new", texts: ["Hello"]), enabled: true)
        let configuration = store.configuration
        resume?.resume(returning: .installed)
        await pending.value
        #expect(store.configuration == configuration)
        #expect(store.configuration?.source?.languageCode?.identifier == "en")
        #expect(store.missingLanguages.isEmpty)
    }

    @Test func disablingTranslationIgnoresLateModelRefresh() async {
        var resume: CheckedContinuation<LanguageAvailability.Status, Never>?
        var refreshing = false
        let store = LyricsTranslationStore(availabilityCheck: { _ in
            if refreshing { return await withCheckedContinuation { resume = $0 } }
            return .supported
        }, availabilityRetryDelay: .zero)
        let song = input(texts: ["君と歌う"], language: .japanese)
        await store.configure(song, enabled: true)
        refreshing = true
        let pending = Task { await store.refreshMissingModels(song) }
        while resume == nil { await Task.yield() }
        store.cancel()
        resume?.resume(returning: .installed)
        await pending.value
        #expect(store.configuration == nil)
        #expect(!store.loading)
    }

    @Test func removedModelsAreNotAssumedInstalledForTheNextSong() async {
        var installed = true
        let store = LyricsTranslationStore(availabilityCheck: { _ in installed ? .installed : .supported },
                                          availabilityRetryDelay: .zero)
        await store.configure(input(track: "first", texts: ["君と歌う"], language: .japanese), enabled: true)
        #expect(store.configuration != nil)
        installed = false
        await store.configure(input(track: "second", texts: ["君と歌う"], language: .japanese), enabled: true)
        #expect(store.configuration == nil)
        #expect(store.missingLanguages == ["ja"])
    }

    private func input(track: String = "song", texts: [String] = ["Hello world", "Good morning"],
                       language: LyricsLanguage = .other, sourceLanguage: String? = nil) -> LyricsTranslationInput {
        LyricsTranslationInput(trackID: track,
            document: LyricsDocument(lines: texts.enumerated().map {
                .init(id: $0.offset * 10 + 7, words: $0.element, startTimeMS: Double($0.offset * 1000))
            }, isSynced: true), language: language, sourceLanguage: sourceLanguage)
    }

    @Test func singleLanguagePreservesOtherFragmentsAndSkipsTheirModels() async {
        var checked: [String] = []
        let store = LyricsTranslationStore(availabilityCheck: { code in
            checked.append(code)
            return code == "ja" ? .installed : .supported
        })
        let song = input(texts: ["Hello ありがとう", "Stay", "Hello ありがとう"],
                         language: .japanese, sourceLanguage: "ja")
        await store.configure(song, enabled: true)
        #expect(checked == ["ja"])
        #expect(store.missingLanguages.isEmpty)
        await store.translate(song) { requests in
            #expect(requests.count == 1)
            #expect(requests.first?.sourceLanguage == "ja")
            return requests.map { .init(id: $0.id, source: $0.text, text: "謝謝") }
        }
        #expect(store.translations == [7: "Hello 謝謝", 27: "Hello 謝謝"])
        #expect(store.message == nil)
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in Issue.record("Completed selection must be reused"); return [] }
        #expect(checked == ["ja"])
    }

    @Test func absentSelectedLanguageCompletesWithoutModelsOrRetry() async {
        let store = LyricsTranslationStore(availabilityCheck: { _ in
            Issue.record("Unselected languages must not be checked")
            return .supported
        })
        let song = input(texts: ["Hello world", "这是我们的世界，我们一起听音乐"], sourceLanguage: "ja")
        await store.configure(song, enabled: true)
        await store.translate(song) { _ in Issue.record("No matching language must not translate"); return [] }
        #expect(store.translations.isEmpty)
        #expect(store.configuration == nil)
        #expect(store.message == nil)
        #expect(!store.loading)
    }

    @Test func singleLanguageOnlyReportsSelectedMissingModel() async {
        let store = LyricsTranslationStore(availabilityCheck: { _ in .supported })
        await store.configure(input(texts: ["Hello ありがとう"], language: .japanese, sourceLanguage: "ja"), enabled: true)
        #expect(store.missingLanguages == ["ja"])
        #expect(store.message == "需要下載日文翻譯模型")
    }

    @Test func changingTranslationScopeDiscardsLateResults() async {
        let store = LyricsTranslationStore()
        let japanese = input(texts: ["Hello ありがとう"], language: .japanese, sourceLanguage: "ja")
        let english = input(texts: ["Hello ありがとう"], language: .japanese, sourceLanguage: "en")
        await store.configure(japanese, enabled: true)
        var resume: CheckedContinuation<[LyricsTranslationStore.Result], Never>?
        let old = Task {
            await store.translate(japanese) { _ in await withCheckedContinuation { resume = $0 } }
        }
        while resume == nil { await Task.yield() }
        await store.configure(english, enabled: true)
        await store.translate(english) { requests in
            #expect(requests.allSatisfy { $0.sourceLanguage == "en" })
            return requests.map { .init(id: $0.id, source: $0.text, text: "你好") }
        }
        resume?.resume(returning: [.init(id: "7:1", source: "ありがとう", text: "謝謝")])
        await old.value
        #expect(store.translations == [7: "你好 ありがとう"])
        #expect(store.message == nil)
        let all = input(texts: ["Hello ありがとう"], language: .japanese, sourceLanguage: "")
        #expect(all.sourceLanguage == nil)
        await store.configure(all, enabled: true)
        #expect(store.translations.isEmpty)
        await store.translate(all) { requests in
            requests.map { .init(id: $0.id, source: $0.text, text: $0.sourceLanguage == "ja" ? "謝謝" : "你好") }
        }
        #expect(store.translations == [7: "你好 謝謝"])
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

    @Test func pitbullCountingRefrainUsesSpanishDespiteHavingFewerThanTwentyLetters() {
        // Minimal excerpt from the reported song; the remaining fixtures are synthetic.
        // https://www.shazam.com/song/326894019/i-know-you-want-me-calle-ocho?tab=lyrics
        let english = "One, two, three, four"
        let spanish = "Uno, dos, tres, cuatro"
        let plan = LyricsTranslationPlan(input(texts: [english, spanish, "\(english) \(spanish)"], language: .automatic))
        #expect(plan.requests.map(\.text) == [english, spanish])
        #expect(plan.requests.map(\.sourceLanguage) == ["en", "es"])
        let translations = Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.key, $0.sourceLanguage == "en" ? "英文數字" : "西文數字") })
        #expect(plan.assembled(using: translations) == [7: "英文數字", 17: "西文數字", 27: "英文數字 西文數字"])
    }

    @Test func englishSpanishSwitchesSplitAtPhrasesWithoutRequiringPunctuation() {
        let cases: [(String, [String], [String])] = [
            ("I love you te quiero", ["I love you", "te quiero"], ["en", "es"]),
            ("Take my hand, mi amor", ["Take my hand,", "mi amor"], ["en", "es"]),
            ("Come with me baila conmigo tonight", ["Come with me", "baila conmigo", "tonight"], ["en", "es", "en"]),
            ("Te quiero, stay with me", ["Te quiero,", "stay with me"], ["es", "en"]),
            ("Let's sing together, te quiero mucho, stay with me", ["Let's sing together,", "te quiero mucho,", "stay with me"], ["en", "es", "en"])
        ]
        for (text, phrases, languages) in cases {
            let plan = LyricsTranslationPlan(input(texts: [text], language: .automatic))
            #expect(plan.requests.map(\.text) == phrases)
            #expect(plan.requests.map(\.sourceLanguage) == languages.map(Optional.some))
            // Detection must not alter source punctuation, accents or spacing.
            let unchanged = Dictionary(uniqueKeysWithValues: plan.requests.map { ($0.key, $0.text) })
            #expect(plan.assembled(using: unchanged) == [7: text])
        }
    }

    @Test func spanishPhraseDetectionDoesNotSplitOrdinaryEnglishOrOtherLatinLanguages() {
        let texts = ["I want you no matter what", "Love me like you do", "I will always be right here beside you",
                     "Je voudrais voyager avec toi dans le monde entier", "Eu gostaria de viajar com você pelo mundo inteiro"]
        let plan = LyricsTranslationPlan(input(texts: texts, language: .automatic))
        #expect(plan.requests.map(\.text) == texts)
        #expect(plan.requests.map(\.sourceLanguage) == ["en", "en", "en", "fr", "pt"])
    }

    @Test func spanishShortPhrasesAreNotForcedToEnglishInJapaneseSongs() {
        let plan = LyricsTranslationPlan(input(texts: ["君と歌う", "Te quiero", "Stay"], language: .automatic))
        #expect(plan.requests.map(\.sourceLanguage) == ["ja", "es", "en"])
    }

    @Test func englishSpanishSelectionOnlyRequestsMatchingPhrases() async {
        for selected in ["en", "es"] {
            let store = LyricsTranslationStore(availabilityCheck: { code in
                #expect(code == selected)
                return .installed
            })
            let song = input(texts: ["I love you te quiero"], language: .automatic, sourceLanguage: selected)
            await store.configure(song, enabled: true)
            await store.translate(song) { requests in
                #expect(requests.count == 1)
                #expect(requests.first?.sourceLanguage == selected)
                return requests.map { .init(id: $0.id, source: $0.text, text: "我愛你") }
            }
            #expect(store.translations == [7: selected == "en" ? "我愛你 te quiero" : "I love you 我愛你"])
            #expect(store.message == nil)
        }
    }

    @Test func missingSpanishModelKeepsEnglishAndResumesOnlySpanish() async {
        var spanishInstalled = false
        let store = LyricsTranslationStore(availabilityCheck: { code in
            #expect(["en", "es"].contains(code))
            return code == "es" && !spanishInstalled ? .supported : .installed
        }, availabilityRetryDelay: .zero)
        let song = input(texts: ["I love you te quiero", "I love you te quiero"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.count == 1)
            #expect(requests.first?.sourceLanguage == "en")
            return requests.map { .init(id: $0.id, source: $0.text, text: "我愛你") }
        }
        #expect(store.translations == [7: "我愛你 te quiero", 17: "我愛你 te quiero"])
        #expect(store.missingLanguages == ["es"])
        spanishInstalled = true
        await store.refreshMissingModels(song)
        await store.translate(song) { requests in
            #expect(requests.count == 1)
            #expect(requests.first?.sourceLanguage == "es")
            return requests.map { .init(id: $0.id, source: $0.text, text: "我愛你") }
        }
        #expect(store.translations == [7: "我愛你 我愛你", 17: "我愛你 我愛你"])
        #expect(store.message == nil)
        #expect(store.missingLanguages.isEmpty)
    }

    @Test func mixedLineShowsCompletedPartsWhileOtherLanguagesArePending() async {
        let store = LyricsTranslationStore()
        let song = input(texts: ["君と I love you いつまでも", "君と I love you いつまでも"], language: .japanese)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            if requests.first?.sourceLanguage == "en" {
                #expect(store.translations == [7: "與你 I love you 直到永遠", 17: "與你 I love you 直到永遠"])
            }
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
        #expect(store.translations == [17: "你好", 27: "你好 ありがとう"])
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

    @Test func automaticKoreanContextKeepsShortEnglishFragmentsInEnglishBatch() {
        let english = ["I", "Stay", "Love", "Oh", "Don’t go", "Ｈｅｌｌｏ", "Na na na na na na na na na na na na"]
        let plan = LyricsTranslationPlan(input(texts: ["너와 함께 노래해"] + english + ["너와 Stay 함께"],
                                               language: .automatic))
        #expect(plan.requests.filter { english.contains($0.text) }.count == english.count)
        #expect(plan.requests.filter { english.contains($0.text) }.allSatisfy { $0.sourceLanguage == "en" })
        #expect(plan.groups(excluding: []).map { $0.source?.languageCode?.identifier } == ["ko", "en"])
    }

    @Test func automaticKoreanContextPreservesConfidentOtherLanguages() {
        let plan = LyricsTranslationPlan(input(texts: ["너와 함께 노래해", "Je voudrais voyager avec toi dans le monde entier"],
                                               language: .automatic))
        #expect(plan.requests.last?.sourceLanguage == "fr")
    }

    @Test func mixedLineKeepsInstalledTranslationsAndResumesMissingLanguage() async {
        var koreanInstalled = false
        let store = LyricsTranslationStore(availabilityCheck: { code in
            #expect(["ko", "en", "ja"].contains(code))
            return code == "ko" && !koreanInstalled ? .supported : .installed
        }, availabilityRetryDelay: .zero)
        let song = input(texts: ["Stay 너와 ありがとう", "Stay 너와 ありがとう"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            requests.map { .init(id: $0.id, source: $0.text, text: $0.sourceLanguage == "en" ? "留下" : "謝謝") }
        }
        #expect(store.translations == [7: "留下 너와 謝謝", 17: "留下 너와 謝謝"])
        #expect(store.missingLanguages == ["ko"])
        #expect(!store.loading)
        koreanInstalled = true
        await store.refreshMissingModels(song)
        await store.translate(song) { requests in
            #expect(requests.count == 1)
            #expect(requests.first?.sourceLanguage == "ko")
            return requests.map { .init(id: $0.id, source: $0.text, text: "與你") }
        }
        #expect(store.translations == [7: "留下 與你 謝謝", 17: "留下 與你 謝謝"])
        #expect(store.missingLanguages.isEmpty)
        #expect(store.message == nil)
    }

    @Test func unknownFragmentKeepsOriginalTextWithoutHidingTranslatedParts() async {
        let store = LyricsTranslationStore(availabilityCheck: { code in
            #expect(code == "ja")
            return .installed
        })
        let song = input(texts: ["ありがとう  Ж  ありがとう", "Ж"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            #expect(requests.count == 1)
            return requests.map { .init(id: $0.id, source: $0.text, text: "謝謝") }
        }
        #expect(store.translations == [7: "謝謝  Ж  謝謝"])
        #expect(store.message?.contains("語言無法確認") == true)
        #expect(!store.loading)
    }

    @Test func uncertainLongLatinFragmentsUseSongContextWithoutOverridingConfidentLanguages() {
        let uncertain: [NLLanguage: Double] = [.dutch: 0.48, .english: 0.42]
        #expect(LyricsTranslationPlan.contextualLatinLanguage(uncertain, letterCount: 35, englishContext: true) == "en")
        #expect(LyricsTranslationPlan.contextualLatinLanguage(uncertain, letterCount: 35, englishContext: false) == nil)
        #expect(LyricsTranslationPlan.contextualLatinLanguage([.french: 0.95, .english: 0.05],
                                                             letterCount: 50, englishContext: true) == "fr")
    }

    @Test func adamasEndingIsHandledAsEnglishInJapaneseSong() {
        // Short excerpt for the reported case: https://www.uta-net.com/song/257111/
        let song = input(texts: ["君と歌う", "It's TiME It's TiME “ADAMAS”"], language: .automatic)
        let plan = LyricsTranslationPlan(song)
        #expect(plan.requests.last?.sourceLanguage == "en")
        #expect(plan.requests.allSatisfy { ["ja", "en"].contains($0.sourceLanguage) })
    }

    @Test func typographyAndLongVocalRefrainsDoNotCreateUnknownLanguageRequests() {
        let english = ["Ｈｅｌｌｏ ＷＯＲＬＤ", "Iʼm here", "𝑯𝒆𝒍𝒍𝒐", "Na na na na na na na na na na na na na na"]
        let song = input(texts: ["君と歌う"] + english + ["ー", "ʼ"], language: .automatic)
        let plan = LyricsTranslationPlan(song)
        #expect(plan.requests.filter { $0.sourceLanguage == "en" }.map(\.text) == english)
        #expect(plan.requests.count == 5)
        #expect(plan.requests.allSatisfy { ["ja", "en"].contains($0.sourceLanguage) })
    }

    @Test func mixedTypographyTranslatesWithoutUnknownLanguageWarning() async {
        let store = LyricsTranslationStore(availabilityCheck: { code in
            #expect(["ja", "en"].contains(code))
            return .installed
        })
        let song = input(texts: ["君と Ｉʼｍ here", "Na na na na na na na na na na na na", "ー"], language: .automatic)
        await store.configure(song, enabled: true)
        await store.translate(song) { requests in
            requests.map { .init(id: $0.id, source: $0.text, text: $0.sourceLanguage == "ja" ? "與你" : "英文譯文") }
        }
        #expect(store.translations == [7: "與你 英文譯文", 17: "英文譯文"])
        #expect(store.message == nil)
        #expect(store.missingLanguages.isEmpty)
    }

    @Test func confidentFrenchPassageInJapaneseSongKeepsFrenchModel() {
        let song = input(texts: ["君と歌う", "Je voudrais voyager avec toi dans le monde entier"], language: .automatic)
        #expect(LyricsTranslationPlan(song).requests.last?.sourceLanguage == "fr")
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

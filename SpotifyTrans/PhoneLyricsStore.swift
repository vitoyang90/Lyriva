import Foundation
import SwiftUI

@MainActor
final class PhoneLyricsStore: ObservableObject {
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var readings: [Int: String] = [:]
    @Published private(set) var readingIssues: [Int: [ReadingIssue]] = [:]
    @Published private(set) var readingChoices: [String: String] = [:]
    @Published private(set) var readingChoiceError: String?
    private var baseReadings: [Int: String] = [:]
    private let preferences: ReadingPreferences
    private var choiceRevisions: [Int: UUID] = [:]
    @Published private(set) var loading = false
    @Published private(set) var needsLogin = false
    @Published private(set) var message = "播放歌曲後顯示歌詞。"
    private struct Request: Equatable {
        let trackID: String?
        let language: LyricsLanguage
        let revision: Int
        let loginRevision: Int
    }
    private(set) var displayedTrackID: String?
    private var completedRequest: Request?
    private var generation = UUID()
    private let fetch: @Sendable (String) async throws -> LyricsDocument
    private let convert: @Sendable (LyricsDocument, LyricsLanguage) async -> [Int: String]
    init(preferences: ReadingPreferences? = nil, fetch: @escaping @Sendable (String) async throws -> LyricsDocument = { try await DirectLyricsClient.shared.fetch(trackID: $0) },
         convert: @escaping @Sendable (LyricsDocument, LyricsLanguage) async -> [Int: String] = { document, language in
             await Task.detached(priority: .userInitiated) {
                 let engine = LyricsRomanizer()
                 let converted = engine.convert(document.lines.map(\.words), language: language)
                 return Dictionary(uniqueKeysWithValues: zip(document.lines, converted).compactMap { line, result in
                     guard let reading = result.romanization else { return nil }
                     return (line.id, reading)
                 })
             }.value
         }) {
        self.preferences = preferences ?? ReadingPreferences()
        self.fetch = fetch
        self.convert = convert
    }

    func load(trackID: String?, language: LyricsLanguage, revision: Int = 0, loginRevision: Int = 0) async {
        guard !Task.isCancelled else { return }
        let request = Request(trackID: trackID, language: language, revision: revision, loginRevision: loginRevision)
        // Reappearing views and repeated playback updates must not reload the displayed song.
        // Only the current document is retained; changing tracks discards it.
        guard request != completedRequest else { return }
        completedRequest = nil
        let requestID = UUID()
        generation = requestID
        if trackID == nil || trackID != displayedTrackID {
            document = nil
            readings = [:]
            clearReadingReview()
            displayedTrackID = nil
        }
        loading = trackID != nil
        guard let trackID else { message = "播放歌曲後顯示歌詞。"; return }
        message = "載入歌詞中…"
        defer { if generation == requestID { loading = false } }
        do {
            let lyrics = try await fetch(trackID)
            guard generation == requestID, !Task.isCancelled else { return }
            message = "處理歌詞中…"
            let result = await convert(lyrics, language)
            guard generation == requestID, !Task.isCancelled else { return }
            let savedChoices = preferences.choices
            let reviewed = await Task.detached(priority: .userInitiated) {
                let issues = ReadingReview().issues(document: lyrics, readings: result, language: language)
                var choices: [String: String] = [:]
                var overrides: [Int: [ReadingOverride]] = [:]
                for (index, line) in lyrics.lines.enumerated() {
                    for issue in issues[line.id] ?? [] {
                        let key = ReadingPreferences.key(trackID: trackID, line: line, issue: issue)
                        if let choice = savedChoices[key], let replacement = issue.replacement(for: choice) {
                            choices[issue.id] = choice
                            overrides[index, default: []].append(replacement)
                        }
                    }
                }
                var readings = result
                if !overrides.isEmpty {
                    let converted = LyricsRomanizer().convert(lyrics.lines.map(\.words), language: language, overrides: overrides)
                    for index in overrides.keys { readings[lyrics.lines[index].id] = converted[index].romanization }
                }
                return (issues, choices, readings)
            }.value
            guard generation == requestID, !Task.isCancelled else { return }
            choiceRevisions = [:]
            document = lyrics
            displayedTrackID = trackID
            baseReadings = result
            readingIssues = reviewed.0
            readingChoices = reviewed.1
            readings = reviewed.2
            readingChoiceError = preferences.error
            completedRequest = request
            needsLogin = false
            message = lyrics.isSynced ? "" : "此歌曲不支援逐句同步"
        } catch {
            guard generation == requestID, !Task.isCancelled else { return }
            if case LyricsError.authenticationRequired = error { needsLogin = true }
            message = (error as? LyricsError)?.localizedDescription ?? "暫時無法載入歌詞，請檢查網路後重試。"
        }
    }

    func loginDidChange() {
        generation = UUID()
        completedRequest = nil
        needsLogin = false
        document = nil
        readings = [:]
        clearReadingReview()
        displayedTrackID = nil
        loading = false
    }
    private func clearReadingReview() {
        choiceRevisions = [:]
        baseReadings = [:]
        readingIssues = [:]
        readingChoices = [:]
        readingChoiceError = nil
    }

    func chooseReading(_ choice: String?, issueID: String, lineID: Int,
                       trackID: String, originalLine: String) async {
        guard !loading, displayedTrackID == trackID, let document,
              let line = document.lines.first(where: { $0.id == lineID && $0.words == originalLine }),
              let issue = readingIssues[lineID]?.first(where: { $0.id == issueID }),
              choice == nil || issue.replacement(for: choice!) != nil,
              let language = completedRequest?.language else { return }
        let key = ReadingPreferences.key(trackID: trackID, line: line, issue: issue)
        guard preferences.set(choice, key: key) else { readingChoiceError = preferences.error; return }
        readingChoiceError = nil
        readingChoices[issueID] = choice
        let overrides = (readingIssues[lineID] ?? []).compactMap { issue in
            readingChoices[issue.id].flatMap { issue.replacement(for: $0) }
        }
        let revision = UUID()
        choiceRevisions[lineID] = revision
        let requestGeneration = generation
        let baseline = baseReadings[lineID]
        let context = language == .automatic && document.lines.contains { LyricsRomanizer().containsKana($0.words) }
        let updated = await Task.detached(priority: .userInitiated) {
            overrides.isEmpty ? baseline : LyricsRomanizer().romanize(line.words, language: language,
                                                                     japaneseContext: context, overrides: overrides)
        }.value
        guard choiceRevisions[lineID] == revision, generation == requestGeneration, displayedTrackID == trackID else { return }
        readings[lineID] = updated
    }

}

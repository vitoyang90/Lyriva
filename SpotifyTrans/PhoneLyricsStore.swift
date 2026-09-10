import Foundation
import SwiftUI

@MainActor
final class PhoneLyricsStore: ObservableObject {
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var readings: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var message = "連接 Spotify 並播放歌曲，即可讀取歌詞。"
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
    init(fetch: @escaping @Sendable (String) async throws -> LyricsDocument = { try await DirectLyricsClient.shared.fetch(trackID: $0) },
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
            displayedTrackID = nil
        }
        loading = trackID != nil
        guard let trackID else { message = "請先連接 Spotify 並播放歌曲。"; return }
        message = "正在取得歌詞…"
        defer { if generation == requestID { loading = false } }
        do {
            let lyrics = try await fetch(trackID)
            guard generation == requestID, !Task.isCancelled else { return }
            message = "正在裝置上產生羅馬字…"
            let result = await convert(lyrics, language)
            guard generation == requestID, !Task.isCancelled else { return }
            document = lyrics
            displayedTrackID = trackID
            readings = result
            completedRequest = request
            message = "已直接從 Spotify 取得歌詞。"
            if !lyrics.isSynced { message += "這首歌沒有有效時間標記，使用一般閱讀模式。" }
        } catch {
            guard generation == requestID, !Task.isCancelled else { return }
            message = (error as? LyricsError)?.localizedDescription ?? "暫時無法讀取歌詞，請檢查網路或重新登入歌詞來源。"
        }
    }
}

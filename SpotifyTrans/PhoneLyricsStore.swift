import Foundation
import SwiftUI

@MainActor
final class PhoneLyricsStore: ObservableObject {
    @Published private(set) var document: LyricsDocument?
    @Published private(set) var readings: [Int: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var message = "連接 Spotify 並播放歌曲，即可讀取歌詞。"
    @Published private(set) var conversionMilliseconds: Int?
    private var generation = UUID()
    private let fetch: @Sendable (String) async throws -> LyricsDocument
    private let convert: @Sendable (LyricsDocument, LyricsLanguage) async -> [Int: String]
    init(fetch: @escaping @Sendable (String) async throws -> LyricsDocument = { try await DirectLyricsClient.shared.fetch(trackID: $0) },
         convert: @escaping @Sendable (LyricsDocument, LyricsLanguage) async -> [Int: String] = { document, language in
             await Task.detached(priority: .userInitiated) {
                 let engine = LyricsRomanizer()
                 return Dictionary(uniqueKeysWithValues: document.lines.compactMap { line in
                     guard let reading = engine.convert(line.words, language: language).first?.romanization else { return nil }
                     return (line.id, reading)
                 })
             }.value
         }) {
        self.fetch = fetch
        self.convert = convert
    }

    func load(trackID: String?, language: LyricsLanguage) async {
        let requestID = UUID()
        generation = requestID
        document = nil
        readings = [:]
        conversionMilliseconds = nil
        loading = false
        guard let trackID else { message = "請先連接 Spotify 並播放歌曲。"; return }
        loading = true
        message = "正在取得歌詞…"
        defer { if generation == requestID { loading = false } }
        do {
            let lyrics = try await fetch(trackID)
            guard generation == requestID, !Task.isCancelled else { return }
            message = "正在裝置上產生羅馬字…"
            let start = Date()
            let result = await convert(lyrics, language)
            guard generation == requestID, !Task.isCancelled else { return }
            conversionMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
            guard generation == requestID, !Task.isCancelled else { return }
            document = lyrics
            readings = result
            message = "已直接從 Spotify 取得歌詞。"
            if !lyrics.isSynced { message += "這首歌沒有有效時間標記，使用一般閱讀模式。" }
        } catch {
            guard generation == requestID, !Task.isCancelled else { return }
            message = (error as? LyricsError)?.localizedDescription ?? "暫時無法讀取歌詞，請檢查網路或重新登入歌詞來源。"
        }
    }
}

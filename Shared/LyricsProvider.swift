import Foundation

struct LyricsDocument: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let words: String
        let startTimeMS: Double?
    }
    let lines: [Line]
    let isSynced: Bool

    func activeLine(at milliseconds: Double) -> Int? {
        guard isSynced else { return nil }
        return lines.last(where: { ($0.startTimeMS ?? .infinity) <= milliseconds })?.id
    }

    static func decode(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Entry: Decodable {
                let words: String
                let startTimeMs: String?
            }
            let error: Bool
            let syncType: String?
            let lines: [Entry]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !response.error, let entries = response.lines, !entries.isEmpty else {
            throw LyricsError.message("此歌曲尚無歌詞。")
        }
        let lines = entries.enumerated().map {
            Line(id: $0.offset, words: $0.element.words, startTimeMS: $0.element.startTimeMs.flatMap(Double.init))
        }
        let times = lines.compactMap(\.startTimeMS)
        let validTimes = times.count == lines.count && times.allSatisfy { $0.isFinite && $0 >= 0 }
            && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
        return Self(lines: lines, isSynced: response.syncType == "LINE_SYNCED" && validTimes)
    }
}

enum LyricsError: LocalizedError {
    case message(String)
    case authenticationRequired
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .authenticationRequired: return "請至設定完成 Spotify 歌詞登入。"
        }
    }
}

import CryptoKit
import Foundation

@MainActor
final class ReadingPreferences {
    private(set) var choices: [String: String] = [:]
    private(set) var error: String?
    private let file: URL
    private var readable = true

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("Lyriva/reading-choices.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { choices = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) }
        catch { readable = false; self.error = "無法讀取已選讀音，請重新開啟 App 再試。" }
    }

    func set(_ choice: String?, key: String) -> Bool {
        guard readable else { return false }
        var updated = choices
        updated[key] = choice
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            choices = updated
            error = nil
            return true
        } catch { self.error = "讀音選擇儲存失敗，請稍後再試。"; return false }
    }

    nonisolated static func key(trackID: String, line: LyricsDocument.Line, issue: ReadingIssue) -> String {
        // Store a hash of the song/line/phrase identity, never a historical copy of the lyrics.
        let identity = [trackID, line.words, String(line.startTimeMS ?? -1), String(line.id),
                        String(issue.range.location), String(issue.range.length), issue.original]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

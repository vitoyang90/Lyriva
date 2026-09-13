import Foundation
import NaturalLanguage

// Each Apple translation session receives a single source language. Parts keep
// their original order so a mixed line still shares one lyric timestamp.
struct LyricsTranslationPlan {
    struct Key: Hashable {
        let language: String?
        let text: String
    }
    struct Request: Hashable {
        let id: String
        let key: Key
        var text: String { key.text }
        var sourceLanguage: String? { key.language }
    }
    struct Part {
        let key: Key?
        let literal: String
    }
    struct Line {
        let id: Int
        let parts: [Part]
    }
    struct Group {
        let requests: [Request]
        var source: Locale.Language? { requests.first?.sourceLanguage.map { Locale.Language(identifier: $0) } }
    }
    let lines: [Line]
    let requests: [Request]

    init(_ input: LyricsTranslationInput) {
        var lines: [Line] = []
        var requests: [Request] = []
        var seen = Set<Key>()
        let japaneseContext = input.lines.contains { Self.contains($0.text, pattern: #"[\p{Hiragana}\p{Katakana}]"#) }
        for line in input.textLines {
            let chunks = Self.chunks(line.text)
            var parts: [Part] = []
            for (index, chunk) in chunks.enumerated() {
                let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
                    parts.append(Part(key: nil, literal: chunk))
                    continue
                }
                let source = Self.language(text, selection: input.language, japaneseContext: japaneseContext)
                let key = Key(language: source, text: text)
                let leading = String(chunk.prefix(while: { $0.isWhitespace }))
                let trailing = String(chunk.reversed().prefix(while: { $0.isWhitespace }).reversed())
                if !leading.isEmpty { parts.append(Part(key: nil, literal: leading)) }
                parts.append(Part(key: key, literal: ""))
                if !trailing.isEmpty { parts.append(Part(key: nil, literal: trailing)) }
                if seen.insert(key).inserted {
                    requests.append(Request(id: chunks.count == 1 ? String(line.id) : "\(line.id):\(index)", key: key))
                }
            }
            lines.append(Line(id: line.id, parts: parts))
        }
        self.lines = lines
        self.requests = requests
    }

    func groups(excluding completed: Set<Key>) -> [Group] {
        var order: [String] = []
        var groups: [String: [Request]] = [:]
        for request in requests where !completed.contains(request.key) && request.sourceLanguage != "zh" {
            // Unidentified texts are translated individually, never as a mixed batch.
            let group = request.sourceLanguage ?? "unknown:\(request.id)"
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(request)
        }
        return order.map { Group(requests: groups[$0]!) }
    }

    func assembled(using translations: [Key: String]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { line in
            var text = ""
            for part in line.parts {
                if let key = part.key {
                    guard let translated = translations[key] else { return nil }
                    text += translated
                } else { text += part.literal }
            }
            return (line.id, text)
        })
    }

    private enum Script { case latin, eastAsian, korean, other }
    private static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var previous: Script?
        for character in text {
            let value = String(character)
            let script: Script?
            if contains(value, pattern: #"\p{Latin}"#) { script = .latin }
            else if contains(value, pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}ー々〆]"#) { script = .eastAsian }
            else if contains(value, pattern: #"\p{Hangul}"#) { script = .korean }
            else if value.unicodeScalars.contains(where: CharacterSet.letters.contains) { script = .other }
            else { script = nil }
            if let script, let previous, script != previous {
                chunks.append(current)
                current = ""
            }
            current += value
            if let script { previous = script }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func language(_ text: String, selection: LyricsLanguage, japaneseContext: Bool) -> String? {
        if contains(text, pattern: #"[\p{Hiragana}\p{Katakana}]"#) { return "ja" }
        if contains(text, pattern: #"\p{Hangul}"#) { return "ko" }
        let hasHan = contains(text, pattern: #"\p{Han}"#)
        if hasHan, selection == .japanese { return "ja" }
        if hasHan, selection == .korean { return "ko" }
        let latin = contains(text, pattern: #"\p{Latin}"#)
        let japaneseOrKoreanSong = japaneseContext || selection == .japanese || selection == .korean
        // Brief Latin refrains in Japanese/Korean songs lack enough evidence for
        // reliable detection ("I", "Stay", etc.). Avoid unrelated model downloads.
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        if latin, japaneseOrKoreanSong, letters.count < 20, letters.allSatisfy({ $0.isASCII }) {
            return "en"
        }
        let recognizer = NLLanguageRecognizer()
        if hasHan, japaneseContext {
            recognizer.languageHints = [.japanese: 0.8, .traditionalChinese: 0.1, .simplifiedChinese: 0.1]
        }
        recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue
        if language == "zh-Hans" || language == "zh-Hant" { return "zh" }
        if hasHan { return language }
        // Keep ordinary English greetings/refrains usable; they often have low
        // scores despite English being the recognizer's best candidate.
        if language == "en" { return "en" }
        return confidentLanguage(recognizer.languageHypotheses(withMaximum: 2), letterCount: letters.count)
    }

    // Short ambiguous fragments must not trigger an unrelated model request.
    // English refrains have a separate contextual rule above; longer passages
    // may resolve to any language supported by the system.
    static func confidentLanguage(_ hypotheses: [NLLanguage: Double], letterCount: Int) -> String? {
        let ranked = hypotheses.sorted { $0.value > $1.value }
        guard let first = ranked.first, first.value >= 0.75,
              first.value - (ranked.dropFirst().first?.value ?? 0) >= 0.2,
              letterCount >= 20 || first.key == .english else { return nil }
        return first.key.rawValue
    }

    private static func contains(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

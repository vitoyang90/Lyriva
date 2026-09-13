import Foundation
import NaturalLanguage

struct RomanizedLine: Identifiable, Sendable {
    let id: Int
    let original: String
    let romanization: String?
}

enum LyricsLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自動辨識"
    case japanese = "日文"
    case korean = "韓文"
    case other = "其他語言"

    var id: String { rawValue }
}

struct LyricsRomanizer {
    func convert(_ lyrics: String, language: LyricsLanguage) -> [RomanizedLine] {
        convert(lyrics.components(separatedBy: .newlines), language: language)
    }

    func convert(_ lines: [String], language: LyricsLanguage) -> [RomanizedLine] {
        // Lyrics often place a lone kanji word on its own line. Retain the song's kana
        // evidence while deciding each run separately, so English cannot mask Japanese.
        let japaneseContext = language == .automatic && lines.contains(where: containsKana)
        return lines.enumerated().map { index, line in
            RomanizedLine(id: index, original: line,
                          romanization: romanize(line, language: language, japaneseContext: japaneseContext))
        }
    }

    // Script boundaries are reliable even when the sentence's dominant language is English.
    private static let eastAsianRuns = try! NSRegularExpression(
        pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}ー々〆\u3099\u309A]+"#)
    private static let kana = try! NSRegularExpression(pattern: #"[\p{Hiragana}\p{Katakana}ー]"#)

    private func containsKana(_ text: String) -> Bool {
        Self.kana.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private func romanize(_ text: String, language: LyricsLanguage, japaneseContext: Bool) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let source = text as NSString
        let matches = Self.eastAsianRuns.matches(in: text, range: NSRange(location: 0, length: source.length))
        var output = ""
        var end = 0
        var changed = false
        var previousWasConverted = false

        func append(_ original: String, converted: String) {
            guard !original.isEmpty else { return }
            let wasConverted = original != converted
            // Unspaced script boundaries (helloカタカナworld) need readable word breaks.
            // Existing spaces and punctuation remain exactly as supplied in the lyrics.
            if (wasConverted || previousWasConverted),
               let last = output.last, let first = converted.first,
               (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) {
                output += " "
            }
            output += converted
            changed = changed || wasConverted
            previousWasConverted = wasConverted
        }

        for match in matches {
            let gap = source.substring(with: NSRange(location: end, length: match.range.location - end))
            // English stays untouched by toLatin; Hangul and other non-Latin scripts still convert.
            append(gap, converted: gap.applyingTransform(.toLatin, reverse: false) ?? gap)
            let part = source.substring(with: match.range)
            let hasKana = containsKana(part)
            var isJapanese = hasKana || language == .japanese
            if !isJapanese && language == .automatic {
                // Kana elsewhere in the song makes a Japanese reading more likely for
                // shared words like 世界 / 未来. A hint is not a forced language: preserve
                // a run when the combined Chinese probability still outweighs Japanese.
                let recognizer = NLLanguageRecognizer()
                if japaneseContext {
                    recognizer.languageHints = [.japanese: 0.8, .traditionalChinese: 0.1, .simplifiedChinese: 0.1]
                }
                recognizer.processString(part)
                if japaneseContext {
                    isJapanese = (recognizer.languageHypotheses(withMaximum: 3)[.japanese] ?? 0) > 0.5
                } else {
                    isJapanese = recognizer.dominantLanguage == .japanese
                }
            }
            append(part, converted: isJapanese ? (japaneseReading(part) ?? part) : part)
            end = match.range.location + match.range.length
        }
        let tail = source.substring(from: end)
        append(tail, converted: tail.applyingTransform(.toLatin, reverse: false) ?? tail)
        return changed ? output : nil
    }

    private func japaneseReading(_ text: String) -> String? {
        let source = text.precomposedStringWithCanonicalMapping as NSString
        let tokenizer = CFStringTokenizerCreate(nil, source,
            CFRange(location: 0, length: source.length), kCFStringTokenizerUnitWord,
            NSLocale(localeIdentifier: "ja"))
        var output = ""
        var end = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > end {
                output += source.substring(with: NSRange(location: end, length: range.location - end))
            } else if !output.isEmpty {
                output += " "
            }
            let original = source.substring(with: NSRange(location: range.location, length: range.length))
            let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer,
                kCFStringTokenizerAttributeLatinTranscription) as? String
            // Unknown names/characters can have an empty transcription. Never drop them.
            let transcription = reading.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? original
            // The modern particle を is pronounced o; Katakana ウォ and words
            // containing the full-sized つ keep their own transcriptions.
            output += original == "を" ? "o" : transcription
            end = range.location + range.length
        }
        if end < source.length { output += source.substring(from: end) }
        let normalized = Self.normalizeSokuon(output)
        return normalized == text ? nil : normalized
    }

    // CFStringTokenizer can split an inflection at small っ, e.g.
    // しまっ + た -> shima~tsu + ta. Resolve its marker after joining tokens,
    // while still inside this contiguous Japanese run (never across punctuation
    // or English text). A final small っ represents a clipped ending.
    static func normalizeSokuon(_ reading: String) -> String {
        var result = reading.replacingOccurrences(of: #"\s*~tsu\s*(?=ch)"#,
                                                  with: "t", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s*~tsu\s*(?=([bcdfghjkpqstvxz]))"#,
                                             with: "$1", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s*~tsu"#, with: "’", options: .regularExpression)
    }
}

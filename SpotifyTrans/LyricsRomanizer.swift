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
        lyrics.components(separatedBy: .newlines).enumerated().map { index, line in
            RomanizedLine(id: index, original: line, romanization: romanize(line, language: language))
        }
    }

    private func romanize(_ text: String, language: LyricsLanguage) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Keep English and other Latin-only text intact, including manual Japanese mode.
        let requiresTransliteration = text.unicodeScalars.contains {
            CharacterSet.letters.contains($0) && $0.value > 0x024F
        }
        guard requiresTransliteration else { return nil }
        // A document-wide language guess would incorrectly convert Chinese lines in mixed lyrics.
        var isJapanese = language == .japanese
        if language == .automatic {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let detected = recognizer.dominantLanguage
            isJapanese = detected == .japanese
            if detected == .english || detected == .simplifiedChinese || detected == .traditionalChinese {
                return nil
            }
        }
        if isJapanese { return japaneseReading(text) }
        guard let latin = text.applyingTransform(.toLatin, reverse: false),
              latin != text else { return nil }
        return latin
    }

    private func japaneseReading(_ text: String) -> String? {
        let source = text as NSString
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
            output += reading ?? original
            end = range.location + range.length
        }
        if end < source.length { output += source.substring(from: end) }
        return output == text ? nil : output
    }
}

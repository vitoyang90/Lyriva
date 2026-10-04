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
        let detectionLines = input.textLines.map { $0.text.precomposedStringWithCompatibilityMapping }
        let japaneseContext = detectionLines.contains { Self.contains($0, pattern: #"[\p{Hiragana}\p{Katakana}]"#) }
        let koreanContext = detectionLines.contains { Self.contains($0, pattern: #"\p{Hangul}"#) }
        var latinDetector = LatinDetector()
        for line in input.textLines {
            let chunks = Self.chunks(line.text).flatMap { latinDetector.fragments($0) }
            var parts: [Part] = []
            for (index, fragment) in chunks.enumerated() {
                let chunk = fragment.text
                let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Self.contentLetters(text).isEmpty else {
                    parts.append(Part(key: nil, literal: chunk))
                    continue
                }
                let source = fragment.language ?? Self.language(text, selection: input.language,
                                           japaneseContext: japaneseContext, koreanContext: koreanContext)
                if let selected = input.sourceLanguage,
                   source.flatMap({ Locale.Language(identifier: $0).languageCode?.identifier }) != Locale.Language(identifier: selected).languageCode?.identifier {
                    parts.append(Part(key: nil, literal: chunk))
                    continue
                }
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
            // Show completed fragments even when another language is missing or
            // unrecognized. Keep its original text until a later retry succeeds.
            // Entirely untranslated lines still use the view's original fallback.
            guard line.parts.contains(where: { part in
                part.key.map { translations[$0] != nil } ?? false
            }) else { return nil }
            var text = ""
            for part in line.parts {
                if let key = part.key {
                    text += translations[key] ?? key.text
                } else { text += part.literal }
            }
            return (line.id, text)
        })
    }

    private struct Fragment {
        let text: String
        let language: String?
    }

    // English and Spanish share a script. Look for confident Spanish phrases
    // inside Latin runs, protecting clear English words at their boundaries.
    // Work on original ranges so accents, apostrophes and punctuation survive.
    private struct LatinDetector {
        private static let words = try! NSRegularExpression(pattern: #"\p{Latin}[\p{Latin}\p{M}]*(?:['’ʼ]\p{Latin}[\p{Latin}\p{M}]*)*"#)
        private static let sharedWords: Set<String> = ["a", "no", "me", "la", "oh", "ooh", "ah", "uh", "na", "hey", "yeah", "ha", "woo"]
        private var cache: [String: [Fragment]] = [:]

        mutating func fragments(_ text: String) -> [Fragment] {
            if let cached = cache[text] { return cached }
            let result = split(text)
            cache[text] = result
            return result
        }

        private func split(_ text: String) -> [Fragment] {
            let original = [Fragment(text: text, language: nil)]
            let letters = Self.letters(text)
            guard !letters.isEmpty, letters.allSatisfy({ LyricsTranslationPlan.contains(String($0), pattern: #"\p{Latin}"#) }) else { return original }
            let source = text as NSString
            let words = Self.words.matches(in: text, range: NSRange(location: 0, length: source.length))
            guard !words.isEmpty else { return original }
            let recognizer = NLLanguageRecognizer()
            func prediction(_ phrase: String) -> (language: NLLanguage?, score: Double, margin: Double) {
                recognizer.reset()
                recognizer.processString(phrase.precomposedStringWithCompatibilityMapping)
                let ranked = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
                let score = ranked.first?.value ?? 0
                return (ranked.first?.key, score, score - (ranked.dropFirst().first?.value ?? 0))
            }
            let whole = prediction(text)
            // Do not reinterpret a clearly identified French/Portuguese/etc. run.
            if let language = whole.language, language != .english, language != .spanish,
               whole.score >= 0.75, whole.margin >= 0.2 { return original }

            var english = Set<Int>()
            var spanishPhrases: [Range<Int>] = []
            for start in words.indices {
                for length in 1...min(6, words.count - start) {
                    let end = start + length
                    let range = NSRange(location: words[start].range.location,
                                        length: NSMaxRange(words[end - 1].range) - words[start].range.location)
                    let phrase = source.substring(with: range)
                    let result = prediction(phrase)
                    if length <= 2, result.language == .english,
                       result.score >= 0.65, result.margin >= 0.2 {
                        english.formUnion(start..<end)
                    }
                    let tokens = (start..<end).map {
                        source.substring(with: words[$0].range).precomposedStringWithCompatibilityMapping.lowercased()
                    }
                    if result.language == .spanish,
                       result.score >= (length == 2 ? 0.45 : 0.8),
                       result.margin >= (length == 2 ? 0.15 : 0.3),
                       Self.letters(phrase).count >= 6,
                       !tokens.allSatisfy(Self.sharedWords.contains) {
                        spanishPhrases.append(start..<end)
                    }
                }
            }
            var spanish = Set<Int>()
            for phrase in spanishPhrases where phrase.allSatisfy({ !english.contains($0) }) {
                spanish.formUnion(phrase)
            }
            guard !spanish.isEmpty else { return original }
            // A short, confidently Spanish line must not fail the general
            // twenty-letter cutoff or be forced to English by Japanese context.
            guard !english.isEmpty else {
                return whole.language == .spanish && whole.score >= 0.45 && whole.margin >= 0.15
                    ? [Fragment(text: text, language: "es")] : original
            }
            var result: [Fragment] = []
            var offset = 0
            var isSpanish = spanish.contains(0)
            for index in words.indices.dropFirst() where spanish.contains(index) != isSpanish {
                let boundary = words[index].range.location
                let part = source.substring(with: NSRange(location: offset, length: boundary - offset))
                result.append(Fragment(text: part, language: isSpanish ? "es" : nil))
                offset = boundary
                isSpanish = spanish.contains(index)
            }
            result.append(Fragment(text: source.substring(from: offset), language: isSpanish ? "es" : nil))
            return result
        }

        private static func letters(_ text: String) -> [Unicode.Scalar] {
            LyricsTranslationPlan.contentLetters(text.precomposedStringWithCompatibilityMapping)
        }
    }

    private enum Script { case latin, eastAsian, korean, other }
    private static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var previous: Script?
        for character in text {
            let value = String(character).precomposedStringWithCompatibilityMapping
            let script: Script?
            if contains(value, pattern: #"\p{Latin}"#) { script = .latin }
            else if contains(value, pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}ー々〆]"#) { script = .eastAsian }
            else if contains(value, pattern: #"\p{Hangul}"#) { script = .korean }
            else if !contentLetters(value).isEmpty { script = .other }
            else { script = nil }
            if let script, let previous, script != previous {
                chunks.append(current)
                current = ""
            }
            current.append(character)
            if let script { previous = script }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func language(_ text: String, selection: LyricsLanguage,
                                 japaneseContext: Bool, koreanContext: Bool) -> String? {
        // Normalize only the detection input: full-width/stylized Latin letters
        // still belong to English fragments, while requests retain the lyrics.
        let text = text.precomposedStringWithCompatibilityMapping
        if contains(text, pattern: #"[\p{Hiragana}\p{Katakana}]"#) { return "ja" }
        if contains(text, pattern: #"\p{Hangul}"#) { return "ko" }
        let hasHan = contains(text, pattern: #"\p{Han}"#)
        if hasHan, selection == .japanese { return "ja" }
        if hasHan, selection == .korean { return "ko" }
        let latin = contains(text, pattern: #"\p{Latin}"#)
        let japaneseOrKoreanSong = japaneseContext || koreanContext || selection == .japanese || selection == .korean
        // Brief Latin refrains in Japanese/Korean songs lack enough evidence for
        // reliable detection ("I", "Stay", etc.). Avoid unrelated model downloads.
        let letters = contentLetters(text)
        let englishContext = latin && japaneseOrKoreanSong && letters.allSatisfy { $0.isASCII }
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let refrainWords: Set<String> = ["oh", "ooh", "ah", "uh", "la", "na", "hey", "yeah", "woah", "whoa", "woo", "ha"]
        if englishContext, letters.count < 20 || (!words.isEmpty && words.allSatisfy(refrainWords.contains)) {
            return "en"
        }
        let recognizer = NLLanguageRecognizer()
        if hasHan, japaneseContext {
            recognizer.languageHints = [.japanese: 0.8, .traditionalChinese: 0.1, .simplifiedChinese: 0.1]
        }
        recognizer.processString(text)
        let language = recognizer.dominantLanguage?.rawValue
        if language == "zh-Hans" || language == "zh-Hant" { return "zh" }
        if hasHan { return language ?? (japaneseContext ? "ja" : nil) }
        // Keep ordinary English greetings/refrains usable; they often have low
        // scores despite English being the recognizer's best candidate.
        if language == "en" { return "en" }
        return contextualLatinLanguage(recognizer.languageHypotheses(withMaximum: 2),
                                       letterCount: letters.count, englishContext: englishContext)
    }

    static func contextualLatinLanguage(_ hypotheses: [NLLanguage: Double], letterCount: Int,
                                        englishContext: Bool) -> String? {
        // Long refrains can be just as ambiguous as short ones. In a Japanese
        // song, fall back to English for Latin text only when no language wins
        // confidently; a clearly recognized French/etc. passage keeps its language.
        confidentLanguage(hypotheses, letterCount: letterCount) ?? (englishContext ? "en" : nil)
    }

    private static func contentLetters(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter {
            CharacterSet.letters.contains($0) && $0.properties.generalCategory != .modifierLetter
        }
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

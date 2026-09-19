import Foundation

struct ReadingOverride: Sendable {
    let range: NSRange
    let original: String
    let reading: String
}

struct ReadingCandidate: Identifiable, Equatable, Sendable {
    let reading: String
    let hint: String
    var id: String { reading }
}

struct ReadingIssue: Identifiable, Sendable {
    enum Reason: String, Sendable {
        case ambiguous = "讀音可能有歧義"
        case sokuon = "促音拼音可能異常"
        case particle = "助詞讀音需要確認"
        case unusual = "拼音格式需要確認"
        case unknown = "讀音可能有歧義，請參考原文"
    }
    let lineID: Int
    let range: NSRange
    let original: String
    let current: String
    let reason: Reason
    let candidates: [ReadingCandidate]
    var id: String { "\(lineID):\(range.location):\(range.length)" }
    var originalChoice: String { "original" }
    func replacement(for choice: String) -> ReadingOverride? {
        if choice == originalChoice { return .init(range: range, original: original, reading: original) }
        guard let candidate = candidates.first(where: { "reading:" + $0.id == choice }) else { return nil }
        return .init(range: range, original: original, reading: candidate.reading)
    }
}

struct ReadingReview {
    // Curated word readings, not arbitrary combinations of single-kanji pronunciations.
    // Dictionary references and limitations: design/reading-review.md.
    private static let lexicon: [String: [ReadingCandidate]] = [
        "二人": [.init(reading: "futari", hint: "兩個人，常見讀法"), .init(reading: "ninin", hint: "複合詞等語境")],
        "二": [.init(reading: "ni", hint: "數字二"), .init(reading: "futa", hint: "和語讀法，依語境")],
        "生物": [.init(reading: "seibutsu", hint: "生物"), .init(reading: "namamono", hint: "生鮮食物")],
        "生": [.init(reading: "sei", hint: "生命等語境"), .init(reading: "shou", hint: "音讀，依語境"), .init(reading: "nama", hint: "生的、未加工")],
        "上手": [.init(reading: "jouzu", hint: "擅長"), .init(reading: "uwate", hint: "佔上風、較高明"), .init(reading: "kamite", hint: "舞台上手等語境")],
        "上": [.init(reading: "ue", hint: "上方"), .init(reading: "kami", hint: "上游、上位等"), .init(reading: "jou", hint: "音讀，依語境")],
        "明日": [.init(reading: "ashita", hint: "明天，常見讀法"), .init(reading: "asu", hint: "明天"), .init(reading: "myounichi", hint: "較正式的讀法")],
        "今日": [.init(reading: "kyou", hint: "今天"), .init(reading: "konnichi", hint: "今日、現今")],
        "永遠": [.init(reading: "eien", hint: "常見讀法"), .init(reading: "towa", hint: "歌詞可能採用的唱法，依聽到的讀音選擇")],
        "一度": [.init(reading: "ichido", hint: "一次；「もう一度」使用此讀法"), .init(reading: "hitotabi", hint: "一旦、一次，依語境與唱法")]
    ]

    func issues(document: LyricsDocument, readings: [Int: String], language: LyricsLanguage) -> [Int: [ReadingIssue]] {
        let engine = LyricsRomanizer()
        let context = language == .automatic && document.lines.contains { engine.containsKana($0.words) }
        return Dictionary(uniqueKeysWithValues: document.lines.compactMap { line in
            let found = issues(line: line, reading: readings[line.id], language: language, japaneseContext: context)
            return found.isEmpty ? nil : (line.id, found)
        })
    }

    func issues(line: LyricsDocument.Line, reading: String?, language: LyricsLanguage,
                japaneseContext: Bool = false) -> [ReadingIssue] {
        let engine = LyricsRomanizer()
        let source = line.words as NSString
        let runs = engine.japaneseRanges(in: line.words, language: language, japaneseContext: japaneseContext)
        guard !runs.isEmpty else { return [] }
        // Whole-line residual checks are limited to Japanese text. English lyrics such as
        // literal "wo" / "~tsu" must never be treated as a failed Japanese transcription.
        let hasLatin = line.words.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
        if !hasLatin, let reading {
            if reading.contains("~tsu") {
                return [ReadingIssue(lineID: line.id, range: NSRange(location: 0, length: source.length),
                    original: line.words, current: reading, reason: .sokuon,
                    candidates: [.init(reading: LyricsRomanizer.normalizeSokuon(reading), hint: "合併促音後的讀法")])]
            }
            if line.words.contains("を"), reading.range(of: #"\bwo\b"#, options: .regularExpression) != nil {
                return [ReadingIssue(lineID: line.id, range: NSRange(location: 0, length: source.length),
                    original: line.words, current: reading, reason: .particle,
                    candidates: [.init(reading: engine.romanize(line.words, language: .japanese, japaneseContext: true) ?? reading,
                                       hint: "助詞「を」通常讀 o")])]
            }
        }
        if !hasLatin, let reading, reading.range(of: #"\p{Latin}"#, options: .regularExpression) != nil,
           Self.looksUnusual(reading), runs.reduce(0, { $0 + $1.length }) == source.length {
            let converted = engine.romanize(line.words, language: .japanese, japaneseContext: true)
            let candidates: [ReadingCandidate] = converted.flatMap {
                $0 != reading && !Self.looksUnusual($0) ? [.init(reading: $0, hint: "依原文重新轉寫")] : nil
            } ?? []
            return [.init(lineID: line.id, range: NSRange(location: 0, length: source.length),
                          original: line.words, current: reading, reason: .unusual, candidates: candidates)]
        }
        var result: [ReadingIssue] = []
        for run in runs {
            let text = source.substring(with: run)
            let ns = text as NSString
            let tokenizer = CFStringTokenizerCreate(nil, ns, CFRange(location: 0, length: ns.length),
                                                    kCFStringTokenizerUnitWord, NSLocale(localeIdentifier: "ja"))
            var tokens: [NSRange] = []
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                tokens.append(NSRange(location: range.location, length: range.length))
            }
            if tokens.isEmpty { tokens = [NSRange(location: 0, length: ns.length)] }
            let boundaries = Set(tokens.flatMap { [$0.location, NSMaxRange($0)] })
            var coveredUntil = 0
            for token in tokens {
                guard token.location >= coveredUntil else { continue }
                let phrase = Self.lexicon.keys.sorted { ($0 as NSString).length > ($1 as NSString).length }.first { word in
                    let length = (word as NSString).length
                    guard token.location + length <= ns.length,
                          boundaries.contains(token.location + length),
                          ns.substring(with: NSRange(location: token.location, length: length)) == word else { return false }
                    // Tokenizers may split counters (二 / 度) or compounds. Do not
                    // offer isolated-kanji readings inside an adjacent Han phrase.
                    let before = ns.substring(to: token.location)
                    let after = ns.substring(from: token.location + length)
                    guard before.range(of: #"\p{Han}$"#, options: .regularExpression) == nil,
                          after.range(of: #"^\p{Han}"#, options: .regularExpression) == nil else { return false }
                    return length > 1 || token.length == length
                }
                let range = NSRange(location: token.location, length: phrase.map { ($0 as NSString).length } ?? token.length)
                let original = ns.substring(with: range)
                let current = engine.convert(original, language: .japanese).first?.romanization ?? original
                let candidates = phrase.flatMap { Self.lexicon[$0] } ?? []
                let reason: ReadingIssue.Reason?
                if !candidates.isEmpty { reason = .ambiguous }
                else if current.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil { reason = .unknown }
                else if Self.looksUnusual(current) { reason = .unusual }
                else { reason = nil }
                if let reason {
                    result.append(.init(lineID: line.id,
                        range: NSRange(location: run.location + range.location, length: range.length),
                        original: original, current: current, reason: reason, candidates: candidates))
                    coveredUntil = NSMaxRange(range)
                }
            }
        }
        if result.isEmpty, !hasLatin, let reading, Self.looksUnusual(reading),
           // Do not mislabel preserved Chinese or other scripts in a mixed line.
           runs.reduce(0, { $0 + $1.length }) == source.length {
            result.append(.init(lineID: line.id, range: NSRange(location: 0, length: source.length),
                                original: line.words, current: reading, reason: .unusual, candidates: []))
        }
        return result
    }

    static func looksUnusual(_ reading: String) -> Bool {
        let folded = reading.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja"))
            .lowercased()
        let words = folded.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.contains { word in
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty else { return false }
            // Conservative mora-shaped check; supports long vowels, n, apostrophes and geminates.
            return trimmed.range(of: #"^(?:(?:(?:[kgzstdnhbpmrfvwjy]|[kgstnhbpmrd]y|sh|ch|ts|dy|ty)?[aeiou])|n|[’']|[kstchpbfdgmzjrv](?=[kstchpbfdgmzjrv]))+$"#,
                                 options: .regularExpression) == nil
        }
    }
}

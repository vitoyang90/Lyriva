import SwiftUI
import NaturalLanguage

enum PracticeHighlight: String, CaseIterable, Identifiable {
    case words, syllables
    var id: Self { self }
    var title: String { self == .words ? "逐詞" : "逐字／音節" }
}

// Estimated practice timing, explicitly labeled in the player and options.
// Line timestamps cannot establish vocal activity, pauses, or word ends.
struct PracticeLyricsPlan {
    // A conservative display limit, not a detected vocal ending. Never stretch
    // the estimate across an entire instrumental gap or the track's outro.
    static let maximumEstimatedLineDurationMS = 8_000.0

    struct Token: Equatable {
        let text: String
        let weight: Double

        init(text: String, weight: Double? = nil) {
            self.text = text
            self.weight = weight ?? (text.contains { $0.isLetter || $0.isNumber } ? 1 : 0)
        }
    }
    struct Line {
        let start: Double
        let end: Double
        let original: [Token]
        let reading: [Token]
        func progress(at position: Double?) -> Double? {
            guard let position, position.isFinite, position >= start, position < end, end > start else { return nil }
            return (position - start) / (end - start)
        }
    }
    let lines: [Int: Line]

    init(document: LyricsDocument, readings: [Int: String], highlight: PracticeHighlight,
         durationMS: Double, language: LyricsLanguage) {
        guard document.isSynced else { lines = [:]; return }
        let japanese = language == .japanese || (language == .automatic && document.lines.contains {
            $0.words.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
        })
        var result: [Int: Line] = [:]
        for (index, line) in document.lines.enumerated() {
            guard let start = line.startTimeMS, start.isFinite, start >= 0 else { continue }
            let next = document.lines.dropFirst(index + 1).compactMap(\.startTimeMS).first { $0 > start }
            let end = min(next ?? durationMS, durationMS, start + Self.maximumEstimatedLineDurationMS)
            guard end.isFinite, end > start else { continue }
            let paired = Self.pairedTokens(original: line.words, reading: readings[line.id] ?? "",
                                           highlight: highlight, language: language, japanese: japanese)
            result[line.id] = Line(start: start, end: end, original: paired.original, reading: paired.reading)
        }
        lines = result
    }

    static func tokens(_ text: String, highlight: PracticeHighlight, japaneseReading: Bool = false) -> [Token] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var pieces: [Token] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if cursor < range.lowerBound { pieces.append(Token(text: String(text[cursor..<range.lowerBound]), weight: 0)) }
            let word = String(text[range])
            let units = syllables(word, japaneseReading: japaneseReading).map {
                Token(text: $0, weight: unitWeight($0, japaneseReading: japaneseReading))
            }
            pieces += highlight == .words ? [Token(text: word, weight: units.reduce(0) { $0 + $1.weight })] : units
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { pieces.append(Token(text: String(text[cursor...]), weight: 0)) }
        return pieces
    }

    // Match the displayed reading before sharing timing. A corrected or ambiguous
    // reading must never be silently replaced by a newly generated transcription.
    private static func pairedTokens(original: String, reading: String, highlight: PracticeHighlight,
                                     language: LyricsLanguage, japanese: Bool) -> (original: [Token], reading: [Token]) {
        let engine = LyricsRomanizer()
        var source: [Token] = []
        var generated: [Token] = []
        for word in tokens(original, highlight: .words) {
            guard word.weight > 0 else { source.append(word); generated.append(word); continue }
            let converted = engine.romanize(word.text, language: language, japaneseContext: japanese) ?? word.text
            let isJapanese = !engine.japaneseRanges(in: word.text, language: language, japaneseContext: japanese).isEmpty
            let spoken = tokens(converted, highlight: highlight, japaneseReading: isJapanese)
            let duration = spoken.reduce(0) { $0 + $1.weight }
            generated += spoken
            if highlight == .words {
                source.append(Token(text: word.text, weight: duration))
            } else {
                let units = tokens(word.text, highlight: .syllables)
                let hanCount = units.filter { $0.text.range(of: #"\p{Han}"#, options: .regularExpression) != nil }.count
                let otherWeight = units.filter { $0.text.range(of: #"\p{Han}"#, options: .regularExpression) == nil }
                    .reduce(0) { $0 + $1.weight }
                // Keep kana beats intact; a compound's remaining reading is shared
                // across its kanji because the provider has no per-character timing.
                let weights = units.map { unit in
                    hanCount > 0 && unit.text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                        ? max(1, (duration - otherWeight) / Double(hanCount)) : unit.weight
                }
                let total = weights.reduce(0, +)
                source += zip(units, weights).map { Token(text: $0.0.text, weight: total > 0 ? $0.1 * duration / total : 0) }
            }
        }
        if let aligned = alignedReading(reading, with: generated) { return (source, aligned) }
        return (source, tokens(reading, highlight: highlight, japaneseReading: japanese))
    }

    private static func alignedReading(_ text: String, with generated: [Token]) -> [Token]? {
        func key(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        guard key(text) == key(generated.map(\.text).joined()) else { return nil }
        let letters = text.indices.filter { text[$0].isLetter || text[$0].isNumber }
        var offset = 0
        var cursor = text.startIndex
        var result: [Token] = []
        for token in generated {
            let count = token.text.filter { $0.isLetter || $0.isNumber }.count
            guard count > 0 else { continue }
            guard offset + count <= letters.count else { return nil }
            let start = letters[offset]
            let end = text.index(after: letters[offset + count - 1])
            if cursor < start { result.append(Token(text: String(text[cursor..<start]), weight: 0)) }
            result.append(Token(text: String(text[start..<end]), weight: token.weight))
            cursor = end
            offset += count
        }
        guard offset == letters.count else { return nil }
        if cursor < text.endIndex { result.append(Token(text: String(text[cursor...]), weight: 0)) }
        return result
    }

    private static func unitWeight(_ text: String, japaneseReading: Bool) -> Double {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return 0 }
        // A macron represents two morae even though it is one displayed grapheme.
        return japaneseReading && text.lowercased().contains(where: { "āēīōūâêîôû".contains($0) }) ? 2 : 1
    }

    private static func syllables(_ word: String, japaneseReading: Bool) -> [String] {
        let chars = Array(word)
        guard chars.count > 1 else { return [word] }
        if chars.contains(where: { $0.unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0xd7ff } }) {
            // A grapheme preserves accents/emoji. Small kana stay with their base.
            var pieces: [String] = []
            for char in chars {
                if "ゃゅょぁぃぅぇぉャュョァィゥェォゎヮ".contains(char), !pieces.isEmpty {
                    pieces[pieces.count - 1].append(char)
                } else { pieces.append(String(char)) }
            }
            return pieces
        }
        let vowels = Set("aeiouāēīōūáéíóúàèìòùäëïöüâêîôû")
        let lower = Array(word.lowercased())
        guard lower.count == chars.count else { return [word] }
        var boundaries: [Int] = []
        if japaneseReading {
            for index in lower.indices where index + 1 < chars.count {
                let current = lower[index]
                let next = lower[index + 1]
                // Contracted sounds (kya / shu) are one beat. Syllabic n and
                // doubled consonants each occupy their own beat (ga / k / ko / u).
                if vowels.contains(current)
                    || (current == "n" && !vowels.contains(next) && next != "y" && next != "n")
                    || (current == next && !vowels.contains(current))
                    || (current == "t" && next == "c" && index + 2 < chars.count && lower[index + 2] == "h") {
                    boundaries.append(index + 1)
                }
            }
        } else {
            let latinVowels = vowels.union(["y"])
            let starts = lower.indices.filter { latinVowels.contains(lower[$0]) && ($0 == 0 || !latinVowels.contains(lower[$0 - 1])) }
            for start in starts.dropFirst() {
                // Approximate Latin syllables; never claim phonetic alignment.
                if start == lower.count - 1, lower[start] == "e", lower[start - 1] != "l" { continue }
                boundaries.append(max(1, start - 1))
            }
        }
        let cuts = [0] + Array(Set(boundaries)).sorted() + [chars.count]
        return zip(cuts, cuts.dropFirst()).map { String(chars[$0..<$1]) }
    }

    static func activeToken(in tokens: [Token], progress: Double?) -> Int? {
        guard let progress, progress.isFinite, progress >= 0, progress < 1 else { return nil }
        let total = tokens.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let target = progress * total
        var consumed = 0.0
        for (index, token) in tokens.enumerated() {
            consumed += token.weight
            if token.weight > 0, consumed > target { return index }
        }
        return nil
    }
}

struct PracticeText: View {
    let tokens: [PracticeLyricsPlan.Token]
    let progress: Double?
    let size: Double
    var reading = false

    private var attributed: AttributedString {
        let active = PracticeLyricsPlan.activeToken(in: tokens, progress: progress)
        var text = AttributedString()
        for (index, token) in tokens.enumerated() {
            var part = AttributedString(token.text)
            part.foregroundColor = reading ? Studio.muted : Studio.ink
            if let active {
                if index < active { part.foregroundColor = Studio.accent }
                if index == active {
                    part.foregroundColor = Studio.background
                    part.backgroundColor = Studio.accent
                }
            }
            text += part
        }
        return text
    }

    var body: some View {
        Text(attributed)
            .accessibilityIdentifier("estimated-practice-text")
            .font(.system(size: size, weight: reading ? .medium : .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(tokens.map(\.text).joined())
    }
}

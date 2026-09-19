import SwiftUI
import NaturalLanguage

enum PracticeHighlight: String, CaseIterable, Identifiable {
    case words, syllables
    var id: Self { self }
    var title: String { self == .words ? "逐詞" : "逐字／音節" }
}

// The provider supplies line timestamps. These subdivisions are visual estimates,
// not measured vocal alignment or pronunciation scores.
struct PracticeLyricsPlan {
    struct Token: Equatable {
        let text: String
        var weight: Double { Double(text.filter { $0.isLetter || $0.isNumber }.count) }
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
            let end = min(next ?? durationMS, durationMS)
            guard end.isFinite, end > start else { continue }
            result[line.id] = Line(start: start, end: end,
                original: Self.tokens(line.words, highlight: highlight),
                reading: Self.tokens(readings[line.id] ?? "", highlight: highlight, japaneseReading: japanese))
        }
        lines = result
    }

    static func tokens(_ text: String, highlight: PracticeHighlight, japaneseReading: Bool = false) -> [Token] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var pieces: [String] = []
        var cursor = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if cursor < range.lowerBound { pieces.append(String(text[cursor..<range.lowerBound])) }
            let word = String(text[range])
            pieces += highlight == .words ? [word] : syllables(word, japaneseReading: japaneseReading)
            cursor = range.upperBound
            return true
        }
        if cursor < text.endIndex { pieces.append(String(text[cursor...])) }
        return pieces.map { Token(text: $0) }
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
        let vowels = Set("aeiouyāēīōūáéíóúàèìòùäëïöüâêîôû")
        let lower = Array(word.lowercased())
        guard lower.count == chars.count else { return [word] }
        var boundaries: [Int] = []
        if japaneseReading {
            for index in lower.indices where vowels.contains(lower[index]) && index + 1 < chars.count {
                // Romanized Japanese uses mora-like chunks (se / ka / i).
                boundaries.append(index + 1)
            }
        } else {
            let starts = lower.indices.filter { vowels.contains(lower[$0]) && ($0 == 0 || !vowels.contains(lower[$0 - 1])) }
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
            .font(.system(size: size, weight: reading ? .medium : .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(tokens.map(\.text).joined())
    }
}

import SwiftUI

enum Studio {
    static let background = Color(red: 0.045, green: 0.065, blue: 0.075)
    static let surface = Color(red: 0.085, green: 0.11, blue: 0.12)
    static let raised = Color(red: 0.12, green: 0.15, blue: 0.16)
    static let ink = Color(red: 0.94, green: 0.96, blue: 0.91)
    static let muted = Color(red: 0.61, green: 0.68, blue: 0.67)
    static let accent = Color(red: 0.79, green: 0.95, blue: 0.47)
    static let teal = Color(red: 0.33, green: 0.73, blue: 0.67)
}

struct StudioButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .padding(.horizontal, 20).padding(.vertical, 15)
            .foregroundStyle(prominent ? Studio.background : Studio.ink)
            .background(prominent ? Studio.accent : Studio.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .background(Studio.raised, in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Studio.ink).accessibilityLabel(label)
    }
}

struct StudioPill: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 13).frame(minHeight: 38)
        .foregroundStyle(selected ? Studio.accent : Studio.muted)
        .background(selected ? Studio.accent.opacity(0.1) : Studio.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? Studio.accent.opacity(0.25) : .clear))
    }
}

struct RecordArtwork: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [Studio.teal.opacity(0.65), Studio.raised, Studio.accent.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(0..<8) { index in
                    Circle().stroke(Studio.ink.opacity(0.10), lineWidth: 1)
                        .padding(CGFloat(index) * geometry.size.width / 22 + 9)
                }
                Circle().fill(Studio.background).frame(width: geometry.size.width * 0.37)
                Image(systemName: "waveform").font(.system(size: geometry.size.width * 0.19, weight: .light))
                    .foregroundStyle(Studio.accent)
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct ReadingLine: View {
    let original: String
    let reading: String?
    var showOriginal = true
    var active = false
    var size = 24.0
    @ScaledMetric(relativeTo: .title2) private var scale = 1.0
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 2).fill(active ? Studio.accent : .clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 9) {
                if showOriginal || reading == nil {
                    Text(original.isEmpty ? "♪" : original)
                        .font(.system(size: (reading == nil ? size : size * 0.76) * scale, weight: reading == nil ? .semibold : .regular))
                        .foregroundStyle(reading == nil ? Studio.ink : Studio.muted)
                }
                if let reading {
                    Text(reading)
                        .font(.system(size: size * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? Studio.accent : Studio.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18).padding(.horizontal, 8)
        .background(active ? Studio.accent.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct LanguageMenu: View {
    @Binding var language: LyricsLanguage
    var body: some View {
        Menu {
            Picker("歌詞語言", selection: $language) {
                ForEach(LyricsLanguage.allCases) { Text($0 == .japanese ? "日文（含漢字讀音）" : $0.rawValue).tag($0) }
            }
        } label: { StudioPill(title: language.rawValue, symbol: "character.bubble") }
        .accessibilityLabel("歌詞語言：\(language.rawValue)")
    }
}

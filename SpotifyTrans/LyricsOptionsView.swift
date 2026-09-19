import SwiftUI

struct LyricsOptionsView: View {
    @Binding var showOriginal: Bool
    @Binding var showRomanization: Bool
    @Binding var showChinese: Bool
    @Binding var language: LyricsLanguage
    @Binding var textSize: LyricsTextSize
    @Binding var follow: Bool
    let listeningMode: ListeningMode
    let isSynced: Bool
    let canReload: Bool
    let reload: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("原文", isOn: $showOriginal)
                        .disabled(showOriginal && !showRomanization && !showChinese)
                    Toggle("羅馬字", isOn: $showRomanization)
                        .disabled(showRomanization && !showOriginal && !showChinese)
                    Toggle("中文翻譯", isOn: $showChinese)
                        .accessibilityLabel("繁體中文翻譯")
                        .disabled(showChinese && !showOriginal && !showRomanization)
                }
                .listRowBackground(Studio.raised)
                Section {
                    Picker("歌詞語言", selection: $language) {
                        ForEach(LyricsLanguage.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("lyrics-language-picker")
                    Picker("歌詞字級", selection: $textSize) {
                        ForEach(LyricsTextSize.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityLabel("歌詞字級").accessibilityValue(textSize.title)
                    Toggle("自動捲動", isOn: $follow)
                        .accessibilityLabel("自動捲動歌詞")
                        .disabled(!isSynced)
                } footer: {
                    if !isSynced { Text("有時間標記的歌詞才能自動捲動。") }
                }
                .listRowBackground(Studio.raised)
                if listeningMode == .practice {
                    Section {
                        LabeledContent("跟唱定位", value: isSynced ? "逐句" : "無時間標記")
                            .accessibilityIdentifier("practice-line-timing")
                    } footer: {
                        Text("目前歌詞沒有逐字起訖時間，無法判斷句內停唱與間奏，因此不自動推算逐詞／音節反白。")
                    }
                    .listRowBackground(Studio.raised)
                }
                Section {
                    Button {
                        reload()
                        dismiss()
                    } label: {
                        Label("重新載入歌詞", systemImage: "arrow.clockwise")
                            .foregroundStyle(Studio.accent)
                    }
                    .disabled(!canReload)
                }
                .listRowBackground(Studio.raised)
            }
            .pickerStyle(.menu)
            .scrollContentBackground(.hidden)
            .background(Studio.surface)
            .navigationTitle("歌詞選項")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("close-lyrics-options")
                }
            }
        }
        .foregroundStyle(Studio.ink).tint(Studio.accent).preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .presentationBackground(Studio.surface)
    }
}

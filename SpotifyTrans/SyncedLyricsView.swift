import SwiftUI

struct SyncedLyricsView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var store: PhoneLyricsStore
    var loginRevision: Int
    var landscape = false
    var openSettings: () -> Void
    @State private var revision = 0
    @AppStorage("lyricsLanguage", store: UserDefaults(suiteName: WidgetSongSnapshot.appGroup)) private var language = LyricsLanguage.automatic
    @AppStorage("lyricsShowOriginal") private var showOriginal = true
    @AppStorage("lyricsShowRomanization") private var showRomanization = true
    @AppStorage("lyricsShowChinese") private var showChinese = false
    @State private var follow = true
    @AppStorage("lyricsPortraitTextSize") private var portraitTextSize = LyricsTextSize.medium
    @AppStorage("lyricsLandscapeTextSize") private var landscapeTextSize = LyricsTextSize.medium
    private var textSize: LyricsTextSize { landscape ? landscapeTextSize : portraitTextSize }
    private var textSizeBinding: Binding<LyricsTextSize> {
        landscape ? $landscapeTextSize : $portraitTextSize
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LoadID: Hashable {
        let track: String?
        let language: LyricsLanguage
        let revision: Int
        let login: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: landscape ? 8 : 18) {
            HStack {
                Text("歌詞").font(.title3.bold()).accessibilityIdentifier("lyrics-heading")
                Spacer()
                if spotify.track != nil {
                    IconButton(symbol: "arrow.clockwise", label: "重新載入歌詞") { revision += 1 }
                        .disabled(store.loading)
                }
            }
            if let document = store.document {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        LanguageMenu(language: $language)
                        Button { showOriginal.toggle() } label: {
                            StudioPill(title: "原文", selected: showOriginal)
                        }.accessibilityValue(showOriginal ? "開啟" : "關閉")
                            .disabled(showOriginal && !showRomanization && !showChinese)
                        Button { showRomanization.toggle() } label: {
                            StudioPill(title: "羅馬字", selected: showRomanization)
                        }.accessibilityValue(showRomanization ? "開啟" : "關閉")
                            .disabled(showRomanization && !showOriginal && !showChinese)
                        Button { showChinese.toggle() } label: {
                            StudioPill(title: "中文", selected: showChinese)
                        }.accessibilityLabel("繁體中文翻譯")
                            .accessibilityValue(showChinese ? "開啟" : "關閉")
                            .disabled(showChinese && !showOriginal && !showRomanization)
                        if document.isSynced {
                            Button { follow.toggle() } label: {
                                StudioPill(title: "自動捲動", symbol: "arrow.down", selected: follow)
                            }.accessibilityLabel("自動捲動歌詞").accessibilityValue(follow ? "開啟" : "關閉")
                        }
                        Menu {
                            Picker("歌詞字級", selection: textSizeBinding) {
                                ForEach(LyricsTextSize.allCases) { size in
                                    Text(size.title).tag(size)
                                }
                            }
                        } label: { StudioPill(title: "Aa") }
                            .accessibilityLabel("歌詞字級").accessibilityValue(textSize.title)
                    }.buttonStyle(.plain)
                }.scrollIndicators(.hidden)
                if !store.message.isEmpty {
                    HStack(spacing: 8) {
                        if store.loading { ProgressView().tint(Studio.accent).scaleEffect(0.7) }
                        Text(store.message).font(.caption).foregroundStyle(Studio.muted)
                    }
                }
                let input = LyricsTranslationInput(trackID: store.displayedTrackID ?? "", document: document, language: language)
                TranslatedLyricsContent(input: input, enabled: showChinese) { translations in
                    lyrics(document, translations: translations)
                }
                .id(input)
            } else {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Studio.teal.opacity(0.06)).frame(width: landscape ? 56 : 96, height: landscape ? 56 : 96)
                        Circle().strokeBorder(Studio.teal.opacity(0.17)).frame(width: landscape ? 44 : 72, height: landscape ? 44 : 72)
                        if store.loading { ProgressView().tint(Studio.accent) }
                        else { Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(Studio.teal) }
                    }
                    Text(store.loading ? "載入歌詞中…" : (spotify.track == nil ? "等待歌詞" : "無法顯示歌詞"))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    if !store.loading {
                        Text(spotify.track == nil ? "播放歌曲後，歌詞會顯示在這裡。" : store.message)
                            .font(.subheadline).foregroundStyle(Studio.muted).multilineTextAlignment(.center)
                    }
                    if !store.loading, store.needsLogin, spotify.connected, spotify.track != nil {
                        Button(action: openSettings) {
                            Label("完成歌詞登入", systemImage: "person.crop.circle")
                        }.buttonStyle(StudioButton())
                    }
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 28)
                .background(Studio.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Studio.ink.opacity(0.055)))
            }
        }
        .task(id: LoadID(track: spotify.track?.id, language: language, revision: revision, login: loginRevision)) {
            await store.load(trackID: spotify.track?.id, language: language, revision: revision, loginRevision: loginRevision)
        }
    }
    private func lyrics(_ document: LyricsDocument, translations: [Int: String]) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: scenePhase != .active)) { context in
            let active = spotify.playbackPosition(at: context.date).flatMap { document.activeLine(at: $0) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: landscape ? 6 : 10) {
                        ForEach(document.lines) { line in
                            ReadingLine(original: line.words, reading: store.readings[line.id],
                                        translation: translations[line.id], showOriginal: showOriginal,
                                        showReading: showRomanization, active: active == line.id, size: textSize.points(landscape: landscape), compact: landscape)
                                .id(line.id)
                        }
                    }.textSelection(.enabled).padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .frame(height: landscape ? nil : 430)
                .frame(maxHeight: landscape ? .infinity : nil)
                .onChange(of: active) { _, id in
                    guard follow, let id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: translations.count) { _, _ in
                    if follow, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onChange(of: landscape) { _, _ in
                    if follow, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onChange(of: textSize) { _, _ in
                    if follow, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onChange(of: showOriginal) { _, _ in
                    if follow, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onChange(of: showRomanization) { _, _ in
                    if follow, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onChange(of: follow) { _, enabled in
                    if enabled, let active { proxy.scrollTo(active, anchor: .center) }
                }
                .onAppear { if follow, let active { proxy.scrollTo(active, anchor: .center) } }
            }
        }
    }
}

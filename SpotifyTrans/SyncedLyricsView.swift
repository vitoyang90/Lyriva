import SwiftUI

struct SyncedLyricsView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var store: PhoneLyricsStore
    var loginRevision: Int
    var openSettings: () -> Void
    @State private var revision = 0
    @State private var language = LyricsLanguage.automatic
    @State private var showOriginal = true
    @State private var follow = true
    @State private var fontSize = 24.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct LoadID: Hashable {
        let track: String?
        let language: LyricsLanguage
        let revision: Int
        let login: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WORDS INTO VOICE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Studio.accent)
                    Text("你的跟唱空間").font(.title3.bold())
                }
                Spacer()
                if spotify.track != nil {
                    IconButton(symbol: "arrow.clockwise", label: "重新取得歌詞") { revision += 1 }
                        .disabled(store.loading).opacity(store.loading ? 0.4 : 1)
                }
            }
            if let document = store.document {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        LanguageMenu(language: $language)
                        Button { showOriginal.toggle() } label: {
                            StudioPill(title: "原文", selected: showOriginal)
                        }.accessibilityValue(showOriginal ? "開啟" : "關閉")
                        if document.isSynced {
                            Button { follow.toggle() } label: {
                                StudioPill(title: "跟隨", symbol: "arrow.down", selected: follow)
                            }.accessibilityLabel("自動跟隨目前句子").accessibilityValue(follow ? "開啟" : "關閉")
                        }
                        Menu {
                            Button("小字") { fontSize = 20 }
                            Button("中等") { fontSize = 24 }
                            Button("大字") { fontSize = 30 }
                        } label: { StudioPill(title: "Aa") }.accessibilityLabel("歌詞字級")
                    }.buttonStyle(.plain)
                }.scrollIndicators(.hidden)
                if !document.isSynced {
                    Text("此歌曲沒有時間標記，可以自由閱讀。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }
                TimelineView(.animation(minimumInterval: 0.25, paused: scenePhase != .active)) { context in
                    let active = spotify.playbackPosition(at: context.date).flatMap { document.activeLine(at: $0) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(document.lines) { line in
                                    ReadingLine(original: line.words, reading: store.readings[line.id],
                                                showOriginal: showOriginal, active: active == line.id, size: fontSize)
                                        .id(line.id)
                                }
                            }.textSelection(.enabled).padding(.vertical, 12)
                        }
                        .scrollIndicators(.hidden).frame(height: 430)
                        .onChange(of: active) { _, id in
                            guard follow, let id else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: follow) { _, enabled in
                            if enabled, let active { proxy.scrollTo(active, anchor: .center) }
                        }
                        .onAppear { if follow, let active { proxy.scrollTo(active, anchor: .center) } }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Studio.teal.opacity(0.06)).frame(width: 96, height: 96)
                        Circle().strokeBorder(Studio.teal.opacity(0.17)).frame(width: 72, height: 72)
                        if store.loading { ProgressView().tint(Studio.accent) }
                        else { Image(systemName: "text.bubble").font(.system(size: 26, weight: .light)).foregroundStyle(Studio.teal) }
                    }
                    Text(store.loading ? "正在準備你的歌詞" : (spotify.track == nil ? "歌詞" : "歌詞還沒準備好"))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text(store.loading ? "取得歌詞後，會在裝置上產生羅馬字。" : store.message)
                        .font(.subheadline).foregroundStyle(Studio.muted).multilineTextAlignment(.center).lineSpacing(4)
                    if !store.loading {
                        Button(action: openSettings) {
                            Label(spotify.connected ? "設定歌詞來源" : "設定連線", systemImage: "arrow.up.right")
                        }.buttonStyle(StudioButton())
                    }
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 28)
                .background(Studio.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Studio.ink.opacity(0.055)))
            }
        }
        .task(id: LoadID(track: spotify.track?.id, language: language, revision: revision, login: loginRevision)) {
            await store.load(trackID: spotify.track?.id, language: language)
        }
    }
}

import SwiftUI

struct SyncedLyricsView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var store: PhoneLyricsStore
    var loginRevision: Int
    @Binding var expanded: Bool
    var landscape = false
    var listeningMode = ListeningMode.normal
    var lyricsSetupNeeded = false
    var openSettings: () -> Void
    @State private var revision = 0
    @State private var optionsShown = false
    @State private var readingReview: ReadingReviewSelection?
    @AppStorage("lyricsLanguage", store: UserDefaults(suiteName: WidgetSongSnapshot.appGroup)) private var language = LyricsLanguage.automatic
    @AppStorage("lyricsShowOriginal") private var showOriginal = true
    @AppStorage("lyricsShowRomanization") private var showRomanization = true
    @AppStorage("lyricsShowChinese") private var showChinese = false
    @AppStorage("lyricsTranslationSourceLanguage") private var translationSourceLanguage = ""
    @State private var follow = true
    @State private var browsingLyrics = false
    // One scroll position owns both manual reading and centered playback follow.
    // Mixing a top-anchored ID binding with ScrollViewReader can undo recentering.
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    private var shouldFollow: Bool { follow && !browsingLyrics }
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
        let setupNeeded: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(listeningMode == .practice ? "跟唱歌詞" : "歌詞").font(.title3.bold()).accessibilityIdentifier("lyrics-heading")
                Spacer()
                Button { optionsShown = true } label: {
                    Label("歌詞選項", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 13).frame(minHeight: 44)
                        .background(Studio.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-lyrics-options")
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                        expanded.toggle()
                    }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .opacity(expanded ? 0 : 1)
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .opacity(expanded ? 1 : 0)
                    }
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Studio.raised, in: Capsule())
                    .contentShape(Circle())
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收合歌詞" : "展開歌詞")
                .accessibilityIdentifier("toggle-expanded-lyrics")
                .accessibilityValue(expanded ? "已展開" : "已收合")
            }
            // Move the toolbar as one geometry, including both button backgrounds.
            .geometryGroup()
            if expanded, let track = spotify.track {
                Text(track.name).font(.subheadline.weight(.medium)).foregroundStyle(Studio.muted)
                    .lineLimit(1).accessibilityIdentifier("expanded-lyrics-track")
            }
            if lyricsSetupNeeded {
                ScrollView {
                    VStack(spacing: 14) {
                        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(Studio.teal)
                            .accessibilityHidden(true)
                        Text("歌詞尚未啟用").font(.title3.bold())
                        Text("完成一次 Spotify 網頁登入，就能在播放時閱讀歌詞。也可以先使用播放控制。")
                            .font(.subheadline).foregroundStyle(Studio.muted).multilineTextAlignment(.center)
                        Button("啟用歌詞", action: openSettings).buttonStyle(StudioButton())
                            .accessibilityIdentifier("player-enable-lyrics")
                    }
                    .frame(maxWidth: .infinity).padding(24)
                    .background(Studio.surface, in: RoundedRectangle(cornerRadius: 26))
                }
                .scrollIndicators(.hidden)
            } else if let document = store.document {
                Text(optionsSummary).font(.caption).foregroundStyle(Studio.muted)
                    .accessibilityIdentifier("lyrics-options-summary")
                if listeningMode == .practice {
                    Text(document.isSynced ? "逐句定位 · 缺少逐字時間，暫不提供逐字反白。點歌詞可從該句重唱。" : "此歌曲沒有時間標記，可閱讀練唱，暫不提供反白。")
                        .font(.caption).foregroundStyle(Studio.muted).accessibilityIdentifier("practice-timing-note")
                }
                if !store.message.isEmpty {
                    HStack(spacing: 8) {
                        if store.loading { ProgressView().tint(Studio.accent).scaleEffect(0.7) }
                        Text(store.message).font(.caption).foregroundStyle(Studio.muted)
                    }
                }
                let input = LyricsTranslationInput(trackID: store.displayedTrackID ?? "", document: document,
                                                  language: language, sourceLanguage: translationSourceLanguage)
                TranslatedLyricsContent(input: input, enabled: showChinese) { translations in
                    lyrics(document, translations: translations)
                }
                .id(input)
            } else {
                ScrollView {
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
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $optionsShown) {
            LyricsOptionsView(showOriginal: $showOriginal, showRomanization: $showRomanization,
                              showChinese: $showChinese, language: $language, textSize: textSizeBinding,
                              follow: $follow,
                              listeningMode: listeningMode, isSynced: store.document?.isSynced == true,
                              canReload: spotify.track != nil && !store.loading) { revision += 1 }
                .presentationDetents(landscape ? [.large] : [.height(listeningMode == .practice ? 590 : 530), .large])
        }
        .sheet(item: $readingReview) { selection in
            ReadingReviewView(store: store, selection: selection)
        }
        .onChange(of: spotify.track?.id) { _, trackID in
            if trackID != nil { browsingLyrics = false }
        }
        .task(id: LoadID(track: spotify.track?.id, language: language, revision: revision, login: loginRevision,
                        setupNeeded: lyricsSetupNeeded)) {
            guard !lyricsSetupNeeded else { return }
            await store.load(trackID: spotify.track?.id, language: language, revision: revision, loginRevision: loginRevision)
        }
    }
    private var optionsSummary: String {
        [showOriginal ? "原文" : nil, showRomanization ? "羅馬字" : nil,
         showChinese ? "中文" : nil,
         (follow && store.document?.isSynced == true) ? (browsingLyrics ? "自動捲動已暫停" : "自動捲動") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func lyrics(_ document: LyricsDocument, translations: [Int: String]) -> some View {
        // Line starts locate a lyric row; the gap until the next row is not a
        // vocal interval. Never feed that gap into the estimated token animation,
        // including when an older installation saved a words/syllables preference.
        return TimelineView(.animation(minimumInterval: 0.25,
                                       paused: scenePhase != .active || !spotify.canPredictPlayback)) { context in
            let position = store.displayedTrackID == spotify.track?.id ? spotify.playbackPosition(at: context.date) : nil
            let active = position.flatMap { document.activeLine(at: $0) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: landscape ? 6 : 10) {
                    ForEach(document.lines) { line in
                        let issues = store.readingIssues[line.id] ?? []
                        let row = ReadingLine(original: line.words, reading: store.readings[line.id],
                            translation: translations[line.id], showOriginal: showOriginal || !issues.isEmpty,
                            showReading: showRomanization, active: active == line.id,
                            size: textSize.points(landscape: landscape), compact: landscape)
                        VStack(alignment: .leading, spacing: 4) {
                            Group {
                                if document.isSynced,
                                   let start = line.startTimeMS, start.isFinite, start >= 0,
                                   let trackID = spotify.track?.id, store.displayedTrackID == trackID {
                                    Button { Task { await spotify.seek(to: start, trackID: trackID) } } label: { row }
                                        .buttonStyle(.plain)
                                        .accessibilityHint(listeningMode == .practice ? "從這一句重唱" : "跳到這句歌詞的播放時間")
                                } else { row }
                            }
                            if !issues.isEmpty, let trackID = store.displayedTrackID {
                                let reviewed = issues.allSatisfy { store.readingChoices[$0.id] != nil }
                                Button {
                                    readingReview = .init(trackID: trackID, line: line)
                                } label: {
                                    Label(reviewed ? "已選讀音 · 可變更" : "讀音可能有歧義 · \(issues.count) 處",
                                          systemImage: reviewed ? "checkmark.circle" : "questionmark.circle")
                                        .font(.caption).foregroundStyle(Studio.accent)
                                        .frame(minHeight: 44, alignment: .leading)
                                        .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("reading-review-\(line.id)")
                            }
                        }.id(line.id)
                    }
                }.scrollTargetLayout().textSelection(.enabled).padding(.vertical, 12)
            }
            .scrollPosition($scrollPosition, anchor: .center)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("lyrics-scroll-view")
            .onScrollPhaseChange { _, phase in
                // Programmatic scrolling uses .animating; only a user's
                // drag suspends following, including its subsequent inertia.
                if phase == .interacting, follow, document.isSynced {
                    browsingLyrics = true
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if follow, browsingLyrics, document.isSynced {
                    Button { browsingLyrics = false } label: {
                        Label("回到目前歌詞", systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Studio.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resume-lyrics-follow")
                    .padding(8)
                }
            }
            .onChange(of: active) { _, id in
                guard shouldFollow, let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { scrollPosition.scrollTo(id: id, anchor: .center) }
            }
            .onChange(of: translations.count) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: landscape) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: expanded) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: textSize) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: showOriginal) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: showRomanization) { _, _ in
                if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) }
            }
            .onChange(of: shouldFollow) { _, enabled in
                guard enabled, let active else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    scrollPosition.scrollTo(id: active, anchor: .center)
                }
            }
            .onChange(of: follow) { _, _ in browsingLyrics = false }
            .onAppear { if shouldFollow, let active { scrollPosition.scrollTo(id: active, anchor: .center) } }
        }
    }
}

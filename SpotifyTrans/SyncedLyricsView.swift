import SwiftUI

struct SyncedLyricsView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var store: PhoneLyricsStore
    var loginRevision: Int
    var landscape = false
    var listeningMode = ListeningMode.normal
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
    @AppStorage("practiceHighlight") private var practiceHighlight = PracticeHighlight.words
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
                Text(listeningMode == .practice ? "跟唱歌詞" : "歌詞").font(.title3.bold()).accessibilityIdentifier("lyrics-heading")
                Spacer()
                Button { optionsShown = true } label: {
                    Label("歌詞選項", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 13).frame(minHeight: 44)
                        .background(Studio.raised, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-lyrics-options")
            }
            if let document = store.document {
                Text(optionsSummary).font(.caption).foregroundStyle(Studio.muted)
                    .accessibilityIdentifier("lyrics-options-summary")
                if listeningMode == .practice {
                    Text(document.isSynced ? "估算反白 · 點歌詞可從該句重唱" : "此歌曲沒有時間標記，可閱讀練唱，暫不提供反白。")
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
        .sheet(isPresented: $optionsShown) {
            LyricsOptionsView(showOriginal: $showOriginal, showRomanization: $showRomanization,
                              showChinese: $showChinese, language: $language, textSize: textSizeBinding,
                              follow: $follow, practiceHighlight: $practiceHighlight,
                              listeningMode: listeningMode, isSynced: store.document?.isSynced == true,
                              canReload: spotify.track != nil && !store.loading) { revision += 1 }
                .presentationDetents(landscape ? [.large] : [.height(listeningMode == .practice ? 590 : 530), .large])
        }
        .sheet(item: $readingReview) { selection in
            ReadingReviewView(store: store, selection: selection)
        }
        .task(id: LoadID(track: spotify.track?.id, language: language, revision: revision, login: loginRevision)) {
            await store.load(trackID: spotify.track?.id, language: language, revision: revision, loginRevision: loginRevision)
        }
    }
    private var optionsSummary: String {
        [showOriginal ? "原文" : nil, showRomanization ? "羅馬字" : nil,
         showChinese ? "中文" : nil, (follow && store.document?.isSynced == true) ? "自動捲動" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func lyrics(_ document: LyricsDocument, translations: [Int: String]) -> some View {
        let plan = listeningMode == .practice ? PracticeLyricsPlan(document: document, readings: store.readings,
            highlight: practiceHighlight, durationMS: Double(spotify.track?.duration_ms ?? 0), language: language) : nil
        return TimelineView(.animation(minimumInterval: listeningMode == .practice ? 0.05 : 0.25,
                                       paused: scenePhase != .active || !spotify.canPredictPlayback)) { context in
            let position = store.displayedTrackID == spotify.track?.id ? spotify.playbackPosition(at: context.date) : nil
            let active = position.flatMap { document.activeLine(at: $0) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: landscape ? 6 : 10) {
                        ForEach(document.lines) { line in
                            let issues = store.readingIssues[line.id] ?? []
                            let practiceLine = plan?.lines[line.id]
                            let row = ReadingLine(original: line.words, reading: store.readings[line.id],
                                translation: translations[line.id], showOriginal: showOriginal || !issues.isEmpty,
                                showReading: showRomanization, active: active == line.id,
                                size: textSize.points(landscape: landscape), compact: landscape,
                                practiceLine: practiceLine, practiceProgress: practiceLine?.progress(at: position))
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

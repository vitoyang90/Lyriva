import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: OnboardingStore
    @ObservedObject var spotify: SpotifyConnection
    var onLyricsLogin: () -> Void
    var refreshAccess: () -> Void
    @State private var lyricsLoginShown = false

    private var number: Int {
        (OnboardingStore.Step.allCases.firstIndex(of: store.step) ?? 0) + 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image("LyrivaMark").resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                    Text("Lyriva").font(.title2.bold())
                    Spacer()
                    Text("\(number) / 4").font(.subheadline.monospacedDigit()).foregroundStyle(Studio.muted)
                        .accessibilityLabel("設定進度，第 \(number) 步，共 4 步")
                }
                ProgressView(value: Double(number), total: 4).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                Text("設定進度會自動保存，回到 App 可以繼續。")
                    .font(.footnote).foregroundStyle(Studio.muted)
            }
            .frame(maxWidth: 560).padding(24).frame(maxWidth: .infinity)
        }
        .background(Studio.background.ignoresSafeArea())
        .sheet(isPresented: $lyricsLoginShown, onDismiss: refreshAccess) {
            SpotifyWebLogin { onLyricsLogin() }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.step {
        case .welcome:
            heading("跟著喜歡的歌，輕鬆開口唱", symbol: "music.note")
            Text("連接 Spotify，隨播放閱讀歌詞與羅馬字讀音，也能切換跟唱模式。")
                .foregroundStyle(Studio.muted)
            Label("同步歌詞，跟上每一句", systemImage: "text.alignleft")
            Label("搭配讀音，練習喜歡的歌", systemImage: "character.book.closed")
            action("開始設定", id: "onboarding-begin") { store.begin() }
        case .spotify:
            heading("連接你的 Spotify", symbol: "person.crop.circle.badge.checkmark")
            Text("登入你的 Spotify 帳號，讓 Lyriva 同步歌曲並控制播放。")
                .foregroundStyle(Studio.muted)
            Text("播放控制需要 Spotify Premium；請先安裝並登入 Spotify。")
                .font(.footnote).foregroundStyle(Studio.muted)
            Text(spotify.status).font(.subheadline).foregroundStyle(Studio.muted)
                .accessibilityIdentifier("onboarding-connection-status")
            if store.playbackUnavailable {
                action("重試讀取登入資料", id: "onboarding-retry") { refreshAccess() }
            } else {
                action(spotify.busy ? "連接中…" : "連接 Spotify", id: "onboarding-connect") { spotify.connect() }
                    .disabled(spotify.busy)
            }
            #if DEBUG
            SpotifyDeveloperSettings()
            #endif
        case .lyrics:
            heading("讓歌詞陪你一起唱", symbol: "text.quote")
            Label("Spotify 已連接", systemImage: "checkmark.circle.fill").foregroundStyle(Studio.accent)
            Text("歌詞需要另外完成一次 Spotify 網頁登入。你也可以稍後在播放器或設定中啟用。")
                .foregroundStyle(Studio.muted)
            Text("部分歌曲可能沒有歌詞或同步時間。")
                .font(.footnote).foregroundStyle(Studio.muted)
            if store.lyricsAccess == .unavailable {
                Text("暫時無法讀取歌詞登入資料，請重試或稍後設定。")
                    .font(.subheadline).foregroundStyle(Studio.muted)
                action("重試讀取登入資料", id: "onboarding-retry") { refreshAccess() }
            } else {
                action("啟用歌詞", id: "onboarding-enable-lyrics") { lyricsLoginShown = true }
            }
            Button("稍後設定") { store.deferLyrics() }.buttonStyle(StudioButton())
                .accessibilityIdentifier("onboarding-skip-lyrics")
                .disabled(store.playbackUnavailable)
        case .ready, .completed:
            heading("準備好開始了", symbol: "checkmark.circle")
            Label("Spotify 已連接", systemImage: "checkmark.circle.fill")
            Label(store.lyricsChoice == .deferred ? "歌詞稍後設定" : "歌詞登入已保存",
                  systemImage: store.lyricsChoice == .deferred ? "clock" : "checkmark.circle.fill")
            Text("先在 Spotify 選一首喜歡的歌，再回到 Lyriva 跟著唱。")
                .foregroundStyle(Studio.muted)
            action("開始使用", id: "onboarding-finish") { store.finish() }
                .disabled(store.playbackUnavailable)
        }
        if store.playbackUnavailable, store.step != .spotify {
            Text("暫時無法讀取 Spotify 登入資料。")
                .font(.footnote).foregroundStyle(Studio.muted)
            Button("重試讀取登入資料") { refreshAccess() }.buttonStyle(StudioButton())
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(Studio.accent)
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboarding-heading")
        }
    }

    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(StudioButton(prominent: true)).accessibilityIdentifier(id)
    }
}

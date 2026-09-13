import SwiftUI
import WebKit

struct SpotifyLoginView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var lyrics: PhoneLyricsStore
    var onLyricsLogin: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var loginShown = false
    @State private var lyricsSaved = false
    @State private var credentialUnavailable = false
    @State private var signingOut = false
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("Lyriva").font(.title.bold())
                    Spacer()
                    IconButton(symbol: "xmark", label: "關閉登入頁") { dismiss() }
                }
                Image("LyrivaMark").resizable().scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(spotify.connected && !spotify.requiresReauthorization ? "準備開始跟唱" : "連接你的 Spotify")
                        .font(.largeTitle.bold())
                    Text("連接帳號，讓歌詞跟著音樂走。")
                        .foregroundStyle(Studio.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Spotify 帳號", systemImage: "person.crop.circle").font(.headline)
                    accountStatus("播放", value: spotify.requiresReauthorization ? "需要重新授權" : (spotify.connected ? "已保存登入" : "尚未設定"))
                    accountStatus("歌詞", value: credentialUnavailable ? "暫時無法讀取" : (lyrics.needsLogin ? "需要更新登入" : (lyricsSaved ? "已保存登入" : "尚未啟用")))
                    if !spotify.connected || spotify.requiresReauthorization {
                        if !spotify.connected {
                            TextField("Spotify Client ID", text: $clientID)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(16).background(Studio.background, in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityLabel("Spotify Client ID")
                        }
                        Text(spotify.status).font(.caption).foregroundStyle(Studio.muted)
                        Button(spotify.requiresReauthorization ? "重新授權 Spotify" : "連接 Spotify") {
                            spotify.connect(clientID: spotify.requiresReauthorization ? spotify.savedClientID : clientID)
                        }.buttonStyle(StudioButton(prominent: true)).disabled(spotify.busy || signingOut)
                        if !spotify.connected {
                            DisclosureGroup("如何取得 Client ID") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("在 Spotify Developer Dashboard 建立應用程式，複製 Client ID，並加入以下 Redirect URI。")
                                    Text(SpotifyConnection.redirectURI).textSelection(.enabled).foregroundStyle(Studio.accent)
                                    Link("開啟 Developer Dashboard ↗", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                                }.font(.caption).foregroundStyle(Studio.muted).padding(.top, 12)
                            }
                        }
                    } else if credentialUnavailable {
                        Button("重試讀取登入資料") { readLyricsLogin() }.buttonStyle(StudioButton())
                    } else if !lyricsSaved || lyrics.needsLogin {
                        Text("首次啟用歌詞需完成 Spotify 網頁登入，之後會保存在此裝置。")
                            .font(.caption).foregroundStyle(Studio.muted)
                        Button(lyrics.needsLogin ? "更新歌詞登入" : "啟用歌詞") { loginShown = true }
                            .buttonStyle(StudioButton(prominent: true)).disabled(signingOut)
                    } else {
                        Text("下次開啟 App 將自動連線。")
                            .font(.caption).foregroundStyle(Studio.muted)
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Studio.accent) }
                    if spotify.connected || lyricsSaved || credentialUnavailable {
                        DisclosureGroup("管理帳號") {
                            Button(signingOut ? "登出中…" : "登出 Spotify", role: .destructive) {
                                Task { await signOut() }
                            }.frame(minHeight: 44).disabled(spotify.busy || signingOut)
                        }.font(.subheadline)
                    }
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                if spotify.connected && !spotify.requiresReauthorization {
                    Button(lyricsSaved && !lyrics.needsLogin ? "開始使用" : "稍後啟用歌詞，先開始使用") { dismiss() }
                        .buttonStyle(StudioButton(prominent: lyricsSaved && !lyrics.needsLogin))
                        .disabled(signingOut)
                }
            }.padding(24)
        }
        .foregroundStyle(Studio.ink).background(Studio.background).tint(Studio.accent)
        .preferredColorScheme(.dark)
        .onAppear { readLyricsLogin() }
        .sheet(isPresented: $loginShown) {
            SpotifyWebLogin {
                onLyricsLogin()
                readLyricsLogin()
                message = "已保存登入資料"
            }
        }
    }

    private func accountStatus(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Studio.muted)
        }.font(.subheadline).accessibilityElement(children: .combine)
    }

    private func readLyricsLogin() {
        do {
            lyricsSaved = try LyricsCredential.readIfPresent() != nil
            credentialUnavailable = false
            message = ""
        } catch {
            credentialUnavailable = true
            message = error.localizedDescription
        }
    }

    @MainActor private func signOut() async {
        signingOut = true
        defer { signingOut = false }
        spotify.disconnect()
        guard !spotify.connected else { message = spotify.status; return }
        do {
            try LyricsCredential.delete()
            let dataStore = WKWebsiteDataStore.default()
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            onLyricsLogin()
            readLyricsLogin()
            message = "已登出 Spotify"
        } catch {
            readLyricsLogin()
            message = "播放已登出，但歌詞登入資料尚未清除，請重試。"
        }
    }
}

struct ConnectionSettingsView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var lyrics: PhoneLyricsStore
    var onLyricsLogin: () -> Void
    @State private var loginShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Spotify 帳號", systemImage: "person.crop.circle").font(.headline)
                    Text(spotify.requiresReauthorization ? "需要重新授權" : (spotify.connected ? "已保存登入" : "尚未連接"))
                        .font(.subheadline).foregroundStyle(Studio.muted)
                    Button("管理 Spotify 帳號") { loginShown = true }.buttonStyle(StudioButton())
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                NavigationLink {
                    TranslationLanguagesView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "character.bubble").font(.title2).foregroundStyle(Studio.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("翻譯語言").font(.headline)
                            Text("管理本機翻譯與語言下載").font(.subheadline).foregroundStyle(Studio.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Studio.muted)
                    }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain)
                DisclosureGroup("使用說明") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("播放控制需 Spotify Premium，並已安裝及登入 Spotify。")
                        Text("長按主畫面加入小工具，搜尋 Lyriva。")
                        Text("小工具更新可能延遲，點一下可開啟 App 更新。")
                        Text("歌詞使用非官方來源，部分歌曲可能無法取得。羅馬字讀音僅供參考。")
                    }.font(.caption).foregroundStyle(Studio.muted).padding(.top, 12)
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
            }.padding(24)
        }
        .foregroundStyle(Studio.ink).background(Studio.background).tint(Studio.accent)
        .preferredColorScheme(.dark)
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Studio.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $loginShown) {
            SpotifyLoginView(spotify: spotify, lyrics: lyrics, onLyricsLogin: onLyricsLogin)
        }
    }
}

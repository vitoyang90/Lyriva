import SwiftUI

struct ConnectionSettingsView: View {
    @ObservedObject var spotify: SpotifyConnection
    var onLyricsLogin: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var loginShown = false
    @State private var message = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MAKE IT YOURS").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Studio.accent)
                        Text("連線與設定").font(.title.bold())
                    }
                    Spacer()
                    IconButton(symbol: "xmark", label: "關閉設定") { dismiss() }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("Spotify 播放控制", systemImage: "play.circle").font(.headline)
                    Text(spotify.status).font(.subheadline).foregroundStyle(Studio.muted)
                    if spotify.connected {
                        Button("中斷 Spotify 連線") { spotify.disconnect() }
                            .buttonStyle(StudioButton()).disabled(spotify.busy)
                    } else {
                        Text("CLIENT ID").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Studio.muted)
                        TextField("輸入 Spotify Client ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(16).background(Studio.background, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Spotify Client ID")
                        Button {
                            spotify.connect(clientID: clientID)
                        } label: {
                            HStack { Text("登入 Spotify"); Spacer(); Image(systemName: "arrow.right") }
                        }.buttonStyle(StudioButton(prominent: true)).disabled(spotify.busy)
                        DisclosureGroup("第一次設定") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("在 Developer Dashboard 建立 App，將下方網址加入 Redirect URI。")
                                Text(SpotifyConnection.redirectURI).textSelection(.enabled).foregroundStyle(Studio.accent)
                                Link("開啟 Developer Dashboard ↗", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                            }.font(.caption).foregroundStyle(Studio.muted).padding(.top, 12)
                        }
                    }
                    Text("只需登入一次：App 會安全保存登入，重新開啟時自動恢復並更新授權，供 App 與小工具使用。主動中斷連線或授權被撤銷後才需要重新登入。播放控制需要 Premium，手機須安裝並登入 Spotify；首次啟動播放會切換至 Spotify 完成授權。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 16) {
                    Label("手機歌詞來源", systemImage: "text.bubble").font(.headline)
                    Text("另外登入 Spotify 網頁以讀取歌詞，登入憑證只保存在此手機。")
                        .font(.subheadline).foregroundStyle(Studio.muted)
                    Button("登入／更新歌詞來源") { loginShown = true }.buttonStyle(StudioButton())
                    Button("清除歌詞登入") {
                        do { try LyricsCredential.delete(); message = "已清除歌詞登入。" }
                        catch { message = error.localizedDescription }
                    }.font(.caption).foregroundStyle(Studio.muted).frame(minHeight: 44)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Studio.accent) }
                    Text("使用非官方歌詞介面。若暫時無法取得歌詞，請重新登入或稍後重試。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }.padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 12) {
                    Label("主畫面歌詞小工具", systemImage: "square.grid.2x2").font(.headline)
                    Text("長按 iPhone 主畫面，選擇加入小工具，再搜尋 SpotifyTrans。提供小、中、大三種尺寸，點一下即可回到 App。")
                    Text("依歌曲時間標記預排換句；歌曲播完後會請求更新，在 iOS 允許時自動取得目前歌曲與歌詞。系統可能延後執行，無法保證換歌或換句即時同步；點擊小工具回 App 可立即校正。只保存目前歌曲，換歌覆蓋。")
                        .foregroundStyle(Studio.muted)
                }.font(.caption).padding(22).background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                Text("羅馬字在裝置上產生，不使用 LLM，也不保存歷史歌詞。讀音僅供參考，可能與歌曲唱法不同。")
                    .font(.caption).foregroundStyle(Studio.muted).lineSpacing(4)
            }.padding(24)
        }
        .foregroundStyle(Studio.ink).background(Studio.background).tint(Studio.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $loginShown) {
            SpotifyWebLogin { message = "歌詞登入已更新。"; onLyricsLogin() }
        }
    }
}

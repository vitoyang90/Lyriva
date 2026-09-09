import SwiftUI

struct ContentView: View {
    @StateObject private var spotify = SpotifyConnection()
    @StateObject private var phoneLyrics = PhoneLyricsStore()
    @State private var settingsShown = false
    @State private var loginRevision = 0
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Studio.accent).frame(width: 40, height: 40)
                        .background(Studio.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SpotifyTrans").font(.system(.headline, design: .rounded, weight: .bold))
                        Text("MUSIC BEYOND WORDS").font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(1.6).foregroundStyle(Studio.muted)
                    }
                    Spacer()
                    IconButton(symbol: "slider.horizontal.3", label: "連線與設定") { settingsShown = true }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("聽見世界，跟著唱。")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-1.2)
                        .minimumScaleFactor(0.8)
                    Text("每一種語言，都有你的聲音。")
                        .font(.subheadline).foregroundStyle(Studio.muted)
                }.padding(.top, 4)
                SpotifyConnectionView(spotify: spotify) { settingsShown = true }
                SyncedLyricsView(spotify: spotify, store: phoneLyrics, loginRevision: loginRevision) {
                    settingsShown = true
                }
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                    Text("裝置端轉寫 · 不保存歷史歌詞")
                }
                .font(.system(size: 10)).foregroundStyle(Studio.muted)
                .frame(maxWidth: .infinity).padding(.top, 4).padding(.bottom, 14)
            }
            .padding(.horizontal, 22).padding(.top, 18)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Studio.background.ignoresSafeArea())
        .foregroundStyle(Studio.ink).tint(Studio.accent).preferredColorScheme(.dark)
        .sheet(isPresented: $settingsShown) {
            ConnectionSettingsView(spotify: spotify) { loginRevision += 1 }
                .presentationDragIndicator(.visible)
        }
        .task(id: "\(spotify.connected)-\(scenePhase == .active)") {
            guard spotify.connected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await spotify.refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

}

#Preview { ContentView() }

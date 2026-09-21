import SwiftUI

struct SpotifyConnectionView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var starter: SpotifyPlaybackStarter
    var compact = false
    var landscape = false
    var artworkSize: CGFloat = 100
    var listeningSession = ListeningSession.spotify(.normal)
    var setListeningMode: ((ListeningMode) -> Void)? = nil
    var isFavorite = false
    var toggleFavorite: (() -> Void)? = nil
    var openSettings: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var spotifyUnavailable = false
    @State private var detailsShown = false

    var body: some View {
        Group {
            if compact { compactPlayer } else { detailedPlayer }
        }
        .sheet(isPresented: $detailsShown) {
            NavigationStack {
                ScrollView {
                    SpotifyConnectionView(spotify: spotify, starter: starter,
                        listeningSession: listeningSession, setListeningMode: setListeningMode,
                        isFavorite: isFavorite, toggleFavorite: toggleFavorite) {
                            detailsShown = false
                            openSettings()
                        }
                        .padding(18)
                }
                .background(Studio.background.ignoresSafeArea())
                .navigationTitle("歌曲與播放資訊")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { detailsShown = false }
                            .accessibilityIdentifier("close-player-details")
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var compactPlayer: some View {
        VStack(spacing: landscape ? 8 : 12) {
            Button { detailsShown = true } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: landscape ? 4 : 8) {
                        Text(spotify.track?.name ?? (spotify.connected ? "尚未播放" : "連接 Spotify"))
                            .font(.system(landscape ? .headline : .title2, design: .rounded, weight: .bold))
                            .foregroundStyle(Studio.ink).lineLimit(2)
                        Text(spotify.track?.artists.map(\.name).joined(separator: " · ") ?? "播放歌曲後顯示歌詞")
                            .font(landscape ? .caption : .subheadline).foregroundStyle(Studio.muted).lineLimit(1)
                        Label("歌曲資訊", systemImage: "chevron.up")
                            .font(.caption).foregroundStyle(Studio.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if spotify.showingActivity || starter.isStarting {
                        ProgressView().controlSize(.small)
                    }
                    artwork(size: artworkSize)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-player-details")
            .accessibilityHint("展開專輯封面、完整歌名與播放資訊")
            if spotify.connected {
                PlaybackTimeline(spotify: spotify, starter: starter, trackID: spotify.track?.id)
                    .id(spotify.track?.id)
                playbackControls
                if spotify.requiresReauthorization {
                    Button("更新 Spotify 授權", action: openSettings).buttonStyle(StudioButton())
                } else if let message = starter.message {
                    Text(message).font(.caption).foregroundStyle(Studio.muted).lineLimit(2)
                }
            } else {
                Button("連接 Spotify", action: openSettings).buttonStyle(StudioButton(prominent: true))
            }
        }
        .padding(landscape ? 14 : 18)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Studio.ink.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compact-player")
    }

    private func artwork(size: CGFloat) -> some View {
        AsyncImage(url: spotify.track?.artworkURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { RecordArtwork() }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size >= 80 ? 20 : 12))
        .accessibilityLabel(spotify.track.map { "\($0.name) 的專輯封面" } ?? "唱片圖案")
    }

    private var detailedPlayer: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 22) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(spotify.connected ? Studio.accent : Studio.muted).frame(width: 6, height: 6)
                    Text(spotify.requiresReauthorization ? "需要重新授權" : (spotify.connected ? "已連接 Spotify" : "Spotify"))
                        .font(.caption.weight(.medium))
                }.foregroundStyle(Studio.muted)
                Spacer()
                ProgressView().tint(Studio.accent).scaleEffect(0.8)
                    .frame(width: 20, height: 20)
                    .opacity((spotify.showingActivity || starter.isStarting) ? 1 : 0)
                    .accessibilityHidden(!spotify.showingActivity && !starter.isStarting)
            }
            HStack(alignment: .center, spacing: compact ? 12 : 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(spotify.track?.name ?? (spotify.connected ? "尚未播放" : "連接 Spotify"))
                        .font(.system(compact ? .headline : .title2, design: .rounded, weight: .bold))
                        .lineLimit(compact ? 2 : nil)
                        .foregroundStyle(Studio.ink).fixedSize(horizontal: false, vertical: true)
                    Text(spotify.track?.artists.map(\.name).joined(separator: " · ") ?? (spotify.connected ? "播放歌曲後顯示歌詞" : "查看目前歌曲與羅馬字歌詞"))
                        .font(compact ? .caption : .subheadline).foregroundStyle(Studio.muted).lineSpacing(4)
                        .lineLimit(compact ? 1 : nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                artwork(size: 108)
            }
            if spotify.connected {
                PlaybackTimeline(spotify: spotify, starter: starter, trackID: spotify.track?.id)
                    .id(spotify.track?.id)
                playbackControls
                Text(starter.message ?? spotify.status).font(.caption).foregroundStyle(Studio.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if spotify.requiresReauthorization {
                    Button("更新 Spotify 授權", action: openSettings).buttonStyle(StudioButton())
                }
                Text("播放裝置：\(spotify.playbackDeviceName ?? "沿用 Spotify 目前裝置")")
                    .font(.caption).foregroundStyle(Studio.muted)
                    .accessibilityIdentifier("playback-device")
                if spotify.needsPlaybackDevicePermission && !spotify.requiresReauthorization {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("更新播放裝置權限") { spotify.connect(clientID: spotify.savedClientID) }
                            .disabled(spotify.busy)
                        Text("只需更新一次，即可辨識手機或電腦；切歌沿用已保存的授權。")
                            .font(.caption).foregroundStyle(Studio.muted)
                    }
                }
                if setListeningMode != nil {
                    listeningModePicker
                }
            } else {
                Button(action: openSettings) {
                    HStack { Text("連接 Spotify"); Spacer(); Image(systemName: "arrow.up.right") }
                }.buttonStyle(StudioButton(prominent: true))
            }
            if spotify.connected || spotify.track?.id != nil {
                HStack(alignment: .center) {
                    if spotify.connected {
                        spotifyLink
                    }
                    Spacer(minLength: 12)
                    favoriteButton
                }
            }
        }
        .padding(compact ? 14 : 24)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Studio.ink.opacity(0.07)))
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if spotify.track?.id != nil, let toggleFavorite {
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? Studio.accent : Studio.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "取消收藏目前歌曲" : "收藏目前歌曲")
            .accessibilityIdentifier("favorite-current-song")
        }
    }

    private var playbackControls: some View {
        ZStack {
            // The transport stays centered in the card regardless of the side action.
            PlaybackTransport(spotify: spotify, starter: starter,
                              buttonSize: compact && landscape ? 48 : 64,
                              spacing: compact && landscape ? 4 : 18)
            HStack {
                if compact {
                    favoriteButton
                } else {
                    IconButton(symbol: "arrow.clockwise", label: "更新目前歌曲") { Task { await spotify.refresh() } }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(StudioIconButtonStyle()).foregroundStyle(Studio.ink)
        .disabled(spotify.busy || starter.isStarting || spotify.requiresReauthorization)
    }

    private var listeningModePicker: some View {
        Picker("播放模式", selection: Binding(
            get: { listeningSession.mode(for: spotify.track?.id) },
            set: { setListeningMode?($0) }
        )) {
            Text("一般").tag(ListeningMode.normal)
            Text("跟唱").tag(ListeningMode.practice)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityIdentifier("listening-mode")
        .accessibilityLabel("播放模式")
    }

    private var spotifyLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                // Switch apps without opening a track or sending a playback command.
                // Spotify retains control of its current screen and playback context.
                spotifyUnavailable = false
                openURL(URL(string: "spotify://")!) { accepted in
                    spotifyUnavailable = !accepted
                }
            } label: {
                Label("切換至 Spotify", systemImage: "arrow.up.right").font(.caption.weight(.medium))
            }
            .foregroundStyle(Studio.accent)
            .accessibilityHint("返回 Spotify，保留目前播放列表與佇列")
            if spotifyUnavailable {
                Text("無法開啟 Spotify，請確認此裝置已安裝 Spotify。")
                    .font(.caption)
                    .foregroundStyle(Studio.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Shared by the player card and the expanded lyrics view.
struct PlaybackTransport: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var starter: SpotifyPlaybackStarter
    var buttonSize: CGFloat = 64
    var spacing: CGFloat = 18

    var body: some View {
        HStack(spacing: spacing) {
            Button { Task { await spotify.control(.previous) } } label: {
                Image(systemName: "backward.end.fill").frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }.accessibilityLabel("上一首")
            Button { Task { await spotify.control(spotify.isPlaying ? .pause : .play) } } label: {
                Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Studio.background)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Studio.accent, in: Circle())
            }.accessibilityLabel(spotify.isPlaying ? "暫停" : "播放")
            Button { Task { await spotify.control(.next) } } label: {
                Image(systemName: "forward.end.fill").frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }.accessibilityLabel("下一首")
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(StudioIconButtonStyle()).foregroundStyle(Studio.ink)
        .disabled(spotify.busy || starter.isStarting || spotify.requiresReauthorization)
    }
}

private struct PlaybackTimeline: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var starter: SpotifyPlaybackStarter
    let trackID: String?
    @State private var previewPosition: Double?
    @State private var submitting = false
    @State private var seekTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = Double(max(0, spotify.track?.duration_ms ?? 0))
            let position = min(duration, max(0, previewPosition ?? spotify.playbackPosition(at: context.date) ?? 0))
            VStack(spacing: 0) {
                Slider(value: Binding(
                    get: { position },
                    set: { previewPosition = $0 }
                ), in: 0...max(1, duration), onEditingChanged: { editing in
                    if !editing { commitSeek() }
                })
                .tint(Studio.accent)
                .frame(minHeight: 44)
                .disabled(duration <= 0 || spotify.track?.id == nil || starter.isStarting || submitting || spotify.showingActivity)
                .accessibilityLabel("播放進度")
                .accessibilityValue("\(time(position))，總長 \(time(duration))")
                .accessibilityHint("向上或向下滑動調整播放時間")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: previewPosition = min(duration, position + 5000)
                    case .decrement: previewPosition = max(0, position - 5000)
                    @unknown default: return
                    }
                    commitSeek()
                }
                HStack {
                    Text(time(position))
                    Spacer()
                    Text(time(duration))
                }
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Studio.muted)
                .accessibilityHidden(true)
            }
        }
        .onDisappear { seekTask?.cancel() }
    }

    private func commitSeek() {
        guard !submitting, let target = previewPosition, let trackID else { return }
        submitting = true
        seekTask = Task {
            await spotify.seek(to: target, trackID: trackID)
            previewPosition = nil
            submitting = false
        }
    }

    private func time(_ ms: Double) -> String {
        let seconds = Int(max(0, ms) / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

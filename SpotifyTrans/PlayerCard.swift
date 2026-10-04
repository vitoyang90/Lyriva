import SwiftUI

enum PlayerExpansionMotion {
    static let animation = Animation.smooth(duration: 0.32, extraBounce: 0)
}

struct SpotifyConnectionView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var starter: SpotifyPlaybackStarter
    @Binding var expanded: Bool
    var compact = false
    var artworkSize: CGFloat = 100
    var listeningSession = ListeningSession.spotify(.normal)
    var setListeningMode: ((ListeningMode) -> Void)? = nil
    var isFavorite = false
    var toggleFavorite: (() -> Void)? = nil
    var openSettings: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spotifyUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            songHeader
            if spotify.connected {
                PlaybackTimeline(spotify: spotify, starter: starter, trackID: spotify.track?.id)
                    .id(spotify.track?.id)
                playbackControls
                if spotify.requiresReauthorization {
                    Button("更新 Spotify 授權", action: openSettings).buttonStyle(StudioButton())
                } else if let message = playbackMessage {
                    Text(message).font(.caption).foregroundStyle(Studio.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("連接 Spotify", action: openSettings).buttonStyle(StudioButton(prominent: true))
            }
            if expanded, spotify.connected {
                playbackDetails
                    .transition(.opacity)
            }
        }
        .padding(compact ? 14 : 18)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Studio.ink.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compact-player")
    }

    private var songHeader: some View {
        let artworkFootprint = artworkSize + 12
        return Button {
            withAnimation(reduceMotion ? nil : PlayerExpansionMotion.animation) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                    Text(spotify.track?.name ?? (spotify.connected ? "尚未播放" : "連接 Spotify"))
                        .font(.system(compact ? .headline : .title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Studio.ink)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(spotify.track?.artists.map(\.name).joined(separator: " · ") ?? "播放歌曲後顯示歌詞")
                        .font(compact ? .caption : .subheadline).foregroundStyle(Studio.muted)
                        .lineLimit(expanded ? nil : 1)
                    Label {
                        Text(expanded ? "收合歌曲與播放" : "展開歌曲與播放")
                    } icon: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.caption).foregroundStyle(Studio.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Reserve a stable text width so scaling the cover does not
                // repeatedly reflow the song title during the animation.
                artwork(size: artworkFootprint)
                    .scaleEffect(expanded ? 1 : artworkSize / artworkFootprint, anchor: .trailing)
                    .overlay(alignment: .bottomTrailing) {
                        if spotify.showingActivity || starter.isStarting {
                            ProgressView().controlSize(.small).padding(6)
                                .background(Studio.surface, in: Circle())
                        }
                    }
            }
            .frame(minHeight: 44).contentShape(Rectangle())
            .geometryGroup()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toggle-player-details")
        .accessibilityValue(expanded ? "已展開" : "已收合")
        .accessibilityHint(expanded ? "縮小歌曲區域，讓歌詞顯示更多內容" : "在目前畫面顯示完整歌名、播放模式與裝置資訊")
    }

    private var playbackDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Studio.ink.opacity(0.08)).frame(height: 1)
            if compact {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        if setListeningMode != nil { listeningModePicker }
                        playbackDevice
                    }
                    Menu {
                        Button("切換至 Spotify", systemImage: "arrow.up.right", action: switchToSpotify)
                        if spotify.needsPlaybackDevicePermission && !spotify.requiresReauthorization {
                            Button("更新播放裝置權限") { spotify.connect(clientID: spotify.savedClientID) }
                                .disabled(spotify.busy)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多播放操作")
                    .accessibilityIdentifier("player-more-actions")
                }
                if spotifyUnavailable { spotifyUnavailableMessage }
            } else {
                if setListeningMode != nil { listeningModePicker }
                playbackDevice
                HStack(spacing: 12) {
                    spotifyLink
                    Spacer(minLength: 0)
                    if spotify.needsPlaybackDevicePermission && !spotify.requiresReauthorization {
                        Button("更新裝置權限") { spotify.connect(clientID: spotify.savedClientID) }
                            .font(.caption).frame(minHeight: 44).disabled(spotify.busy)
                            .accessibilityLabel("更新播放裝置權限")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inline-player-details")
    }

    private var playbackDevice: some View {
        Text("播放裝置：\(spotify.playbackDeviceName ?? "沿用 Spotify 目前裝置")")
            .font(compact ? .caption2 : .caption).foregroundStyle(Studio.muted)
            .lineLimit(compact ? 1 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("playback-device")
    }

    private var playbackMessage: String? {
        if let message = starter.message { return message }
        let routineStatuses = ["播放中", "已暫停", "尚未播放", "已連接 Spotify", "正在同步…"]
        return routineStatuses.contains(spotify.status) ? nil : spotify.status
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

    private var playbackControls: some View {
        // Equal side slots keep the transport centered without overlaying its
        // hit targets on narrower screens. Only transport actions wait for sync.
        HStack(spacing: 0) {
            Group {
                if spotify.track?.id != nil, let toggleFavorite {
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? Studio.accent : Studio.muted)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(isFavorite ? "取消收藏目前歌曲" : "收藏目前歌曲")
                    .accessibilityIdentifier("favorite-current-song")
                } else { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
            }
            PlaybackTransport(spotify: spotify, starter: starter,
                              buttonSize: compact ? 48 : 64, spacing: compact ? 4 : 18)
            Button { Task { await spotify.refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更新目前歌曲")
            .disabled(spotify.busy || starter.isStarting || spotify.requiresReauthorization)
        }
        .buttonStyle(StudioIconButtonStyle()).foregroundStyle(Studio.ink)
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
            Button(action: switchToSpotify) {
                Label("切換至 Spotify", systemImage: "arrow.up.right")
                    .font(.caption.weight(.medium)).frame(minHeight: 44)
            }
            .foregroundStyle(Studio.accent)
            .accessibilityHint("返回 Spotify，保留目前播放列表與佇列")
            if spotifyUnavailable { spotifyUnavailableMessage }
        }
    }

    private var spotifyUnavailableMessage: some View {
        Text("無法開啟 Spotify，請確認此裝置已安裝 Spotify。")
            .font(.caption).foregroundStyle(Studio.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func switchToSpotify() {
        spotifyUnavailable = false
        openURL(URL(string: "spotify://")!) { accepted in
            spotifyUnavailable = !accepted
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

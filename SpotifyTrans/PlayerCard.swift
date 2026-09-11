import SwiftUI

struct SpotifyConnectionView: View {
    @ObservedObject var spotify: SpotifyConnection
    @ObservedObject var starter: SpotifyPlaybackStarter
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(spotify.connected ? Studio.accent : Studio.muted).frame(width: 6, height: 6)
                    Text(spotify.connected ? "CONNECTED TO SPOTIFY" : "YOUR PERSONAL SING-ALONG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                }.foregroundStyle(Studio.muted)
                Spacer()
                ProgressView().tint(Studio.accent).scaleEffect(0.8)
                    .frame(width: 20, height: 20)
                    .opacity((spotify.showingActivity || starter.isStarting) ? 1 : 0)
                    .accessibilityHidden(!spotify.showingActivity && !starter.isStarting)
            }
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(spotify.track?.name ?? (spotify.connected ? "準備好下一首。" : "喜歡的歌，\n一起唱。"))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Studio.ink).fixedSize(horizontal: false, vertical: true)
                    Text(spotify.track?.artists.map(\.name).joined(separator: " · ") ?? "原文與羅馬字，讓發音不再陌生。")
                        .font(.subheadline).foregroundStyle(Studio.muted).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AsyncImage(url: spotify.track?.artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        RecordArtwork()
                    }
                }
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel(spotify.track.map { "\($0.name) 的專輯封面" } ?? "唱片圖案")
            }
            if spotify.connected {
                PlaybackTimeline(spotify: spotify, starter: starter, trackID: spotify.track?.id)
                    .id(spotify.track?.id)
                HStack(spacing: 12) {
                    IconButton(symbol: "arrow.clockwise", label: "更新目前歌曲") { Task { await spotify.refresh() } }
                    Spacer(minLength: 0)
                    Button { Task { await spotify.control(.previous) } } label: {
                        Image(systemName: "backward.end.fill").frame(width: 44, height: 48)
                    }.accessibilityLabel("上一首")
                    Button { Task { await spotify.control(spotify.isPlaying ? .pause : .play) } } label: {
                        Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Studio.background).frame(width: 64, height: 64)
                            .background(Studio.accent, in: Circle())
                    }.accessibilityLabel(spotify.isPlaying ? "暫停" : "播放")
                    Button { Task { await spotify.control(.next) } } label: {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 48)
                    }.accessibilityLabel("下一首")
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlaybackControlButtonStyle()).foregroundStyle(Studio.ink)
                .disabled(spotify.busy || starter.isStarting).opacity((spotify.showingActivity || starter.isStarting) ? 0.55 : 1)
                Text(starter.message ?? spotify.status).font(.caption).foregroundStyle(Studio.muted)
                    .lineLimit(2, reservesSpace: true)
                if spotify.track == nil {
                    Text("按播放以開啟 Spotify，接續上次播放後返回這裡。")
                        .font(.caption).foregroundStyle(Studio.muted)
                }
                if let url = spotify.track?.external_urls.spotify {
                    Link(destination: url) {
                        Label("在 Spotify 開啟", systemImage: "arrow.up.right").font(.caption.weight(.medium))
                    }.foregroundStyle(Studio.accent)
                }
            } else {
                Button(action: openSettings) {
                    HStack { Text("連接 Spotify"); Spacer(); Image(systemName: "arrow.up.right") }
                }.buttonStyle(StudioButton(prominent: true))
            }
        }
        .padding(24)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Studio.ink.opacity(0.07)))
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

// Silent polling briefly disables controls. Keep their appearance stable instead
// of letting the system's plain style dim them on every playback refresh.
private struct PlaybackControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

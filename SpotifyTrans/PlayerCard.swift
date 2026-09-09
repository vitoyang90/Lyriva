import SwiftUI

struct SpotifyConnectionView: View {
    @ObservedObject var spotify: SpotifyConnection
    var openSettings: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(spotify.connected ? Studio.accent : Studio.muted).frame(width: 6, height: 6)
                    Text(spotify.connected ? "CONNECTED TO SPOTIFY" : "YOUR PERSONAL SING-ALONG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                }.foregroundStyle(Studio.muted)
                Spacer()
                if spotify.busy { ProgressView().tint(Studio.accent).scaleEffect(0.8) }
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let position = spotify.playbackPosition(at: context.date) ?? 0
                    let duration = Double(spotify.track?.duration_ms ?? 0)
                    VStack(spacing: 8) {
                        GeometryReader { geometry in
                            Capsule().fill(Studio.ink.opacity(0.1))
                            Capsule().fill(Studio.accent)
                                .frame(width: geometry.size.width * (duration > 0 ? min(1, max(0, position / duration)) : 0))
                        }.frame(height: 3)
                        HStack {
                            Text(time(position))
                            Spacer()
                            Text(time(duration))
                        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("播放進度 \(time(position))，總長 \(time(duration))")
                }
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
                .buttonStyle(.plain).foregroundStyle(Studio.ink)
                .disabled(spotify.busy).opacity(spotify.busy ? 0.55 : 1)
                Text(spotify.status).font(.caption).foregroundStyle(Studio.muted)
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
    private func time(_ ms: Double) -> String {
        let seconds = Int(max(0, ms) / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

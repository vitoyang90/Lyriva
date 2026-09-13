import SwiftUI
import WidgetKit

struct LyricsWidgetEntry: TimelineEntry {
    let date: Date
    let song: WidgetSongSnapshot?
    var isPredicted = false
    var isExpired = false

    static func scheduled(song: WidgetSongSnapshot?, at date: Date) -> Self {
        var displayed = song?.lyrics(at: date)
        // WidgetKit receives only the two displayed lines, not a copy of the whole
        // remaining song in every entry of the timeline.
        displayed?.playback = nil
        return Self(date: date, song: displayed, isPredicted: song?.playback?.isValid == true,
                    isExpired: song?.isExpired(at: date) == true)
    }
}

struct LyricsWidgetView: View {
    let entry: LyricsWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private let accent = Color(red: 0.78, green: 0.96, blue: 0.39)
    private var small: Bool { family == .systemSmall }

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 8 : 12) {
            if let song = entry.song {
                HStack(spacing: 10) {
                    artwork(song.artwork)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.system(size: small ? 12 : 15, weight: .bold, design: .rounded)).lineLimit(small ? 1 : 2)
                        if !small { Text(song.artist).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                if entry.isExpired || song.isExpired(at: entry.date) {
                    Text("待更新")
                        .font(.system(size: small ? 15 : 21, weight: .semibold, design: .rounded))
                    Text("點一下開啟 App 更新").font(.caption).foregroundStyle(accent)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.original.flatMap { $0.isEmpty ? nil : $0 } ?? (song.notice ?? (entry.isPredicted ? "♪" : "暫無歌詞")))
                            .font(.system(size: small ? 15 : 20, weight: .semibold, design: .rounded))
                            .lineLimit(family == .systemMedium ? 1 : 2).minimumScaleFactor(0.85)
                        if let reading = song.romanization, !reading.isEmpty {
                            Text(reading).font(.system(size: small ? 12 : 15, weight: .medium, design: .rounded))
                                .foregroundStyle(accent).lineLimit(2)
                        }
                    }
                    if family == .systemLarge, let next = song.nextOriginal, !next.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 6)
                            Text("下一句").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                            Text(next).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                            if let reading = song.nextRomanization { Text(reading).font(.subheadline).foregroundStyle(accent.opacity(0.7)).lineLimit(2) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock").foregroundStyle(accent)
                    Text(entry.isPredicted ? "預估進度" : "更新於").lineLimit(1)
                    Text(song.updatedAt, style: .time).monospacedDigit().lineLimit(1)
                    Spacer(minLength: 0)
                    if !small { Image(systemName: "arrow.up.right") }
                }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            } else {
                Image(systemName: "waveform").font(.system(size: 23, weight: .bold)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Text("尚無歌曲")
                    .font(.system(size: small ? 19 : 25, weight: .bold, design: .rounded))
                Text("開啟 App 開始播放").font(.caption).foregroundStyle(accent)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.07, green: 0.16, blue: 0.14), Color(red: 0.025, green: 0.055, blue: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: "spotifytrans://lyrics"))
    }

    @ViewBuilder private func artwork(_ data: Data?) -> some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "waveform").foregroundStyle(accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(accent.opacity(0.1)) }
        }.frame(width: small ? 28 : 42, height: small ? 28 : 42)
            .clipShape(RoundedRectangle(cornerRadius: small ? 7 : 10))
    }
}

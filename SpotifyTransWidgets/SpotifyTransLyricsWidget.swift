import SwiftUI
import WidgetKit

struct LyricsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsWidgetEntry { Self.preview }
    func getSnapshot(in context: Context, completion: @escaping (LyricsWidgetEntry) -> Void) {
        completion(context.isPreview ? Self.preview : LyricsWidgetEntry(date: Date(), song: WidgetSnapshotStorage().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsWidgetEntry>) -> Void) {
        let now = Date()
        let song = WidgetSnapshotStorage().read()
        var entries = [LyricsWidgetEntry(date: now, song: song)]
        if let song, !song.isExpired(at: now) {
            entries.append(LyricsWidgetEntry(date: song.updatedAt.addingTimeInterval(WidgetSongSnapshot.freshness), song: song))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
    static var preview: LyricsWidgetEntry {
        LyricsWidgetEntry(date: Date(), song: WidgetSongSnapshot(trackID: "preview", title: "每一種語言，都有你的聲音", artist: "SpotifyTrans",
            original: "世界", romanization: "sekai", nextOriginal: "未来", nextRomanization: "mirai", updatedAt: Date()))
    }
}

@main
struct SpotifyTransLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSongSnapshot.kind, provider: LyricsWidgetProvider()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("SpotifyTrans 歌詞快照")
        .description("保留最近同步的歌詞與羅馬拼音，不會自動逐句換詞。點一下回 App 即時跟唱。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) { SpotifyTransLyricsWidget() } timeline: { LyricsWidgetProvider.preview }

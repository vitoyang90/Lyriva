import SwiftUI
import WidgetKit

struct LyricsWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsWidgetEntry { Self.preview }
    func getSnapshot(in context: Context, completion: @escaping (LyricsWidgetEntry) -> Void) {
        completion(context.isPreview ? Self.preview : LyricsWidgetEntry.scheduled(song: WidgetSnapshotStorage().read(), at: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsWidgetEntry>) -> Void) {
        Task {
            let result = await WidgetTimelineLoader().load()
            let now = Date()
            let entries = (result.song?.presentationDates(after: now) ?? [now]).map {
                LyricsWidgetEntry.scheduled(song: result.song, at: $0)
            }
            completion(Timeline(entries: entries, policy: .after(result.refreshAt)))
        }
    }

    static var preview: LyricsWidgetEntry {
        LyricsWidgetEntry(date: Date(), song: WidgetSongSnapshot(trackID: "preview", title: "範例歌曲", artist: "Lyriva",
            original: "世界", romanization: "sekai", nextOriginal: "未来", nextRomanization: "mirai", updatedAt: Date(),
            authorizationID: UUID(), isPlaying: true))
    }
}

@main
struct SpotifyTransLyricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSongSnapshot.kind, provider: LyricsWidgetProvider()) { entry in
            LyricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Lyriva 歌詞")
        .description("查看歌詞與羅馬字，直接切歌、播放或暫停。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) { SpotifyTransLyricsWidget() } timeline: { LyricsWidgetProvider.preview }

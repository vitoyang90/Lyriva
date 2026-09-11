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
        .configurationDisplayName("SpotifyTrans 歌詞")
        .description("依歌曲時間軸預排歌詞，並於系統允許時重新取得目前歌曲。更新可能延遲。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) { SpotifyTransLyricsWidget() } timeline: { LyricsWidgetProvider.preview }

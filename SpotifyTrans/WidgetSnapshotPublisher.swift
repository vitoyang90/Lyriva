import SwiftUI
import WidgetKit

@MainActor
final class WidgetSnapshotPublisher: ObservableObject {
    @Published private(set) var error: String?
    private let storage = WidgetSnapshotStorage()
    private var lastSnapshot: WidgetSongSnapshot?
    private var artworkKey: String?
    private var artworkTask: Task<Void, Never>?
    private var artworkData: Data?
    private var hasCleared = false

    static func snapshot(track: SpotifyConnection.Track, document: LyricsDocument?, readings: [Int: String],
                         position: Double?, date: Date = Date()) -> WidgetSongSnapshot? {
        guard let id = track.id else { return nil }
        let index: Int?
        if let document, document.isSynced {
            let active = position.flatMap { document.activeLine(at: $0) }
            index = document.lines.firstIndex { $0.id == active }
        } else { index = document?.lines.firstIndex { !$0.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        let line = index.flatMap { document?.lines[$0] }
        let next = index.flatMap { i -> LyricsDocument.Line? in
            guard let document, document.lines.indices.contains(i + 1) else { return nil }
            return document.lines[i + 1]
        }
        // Bound the shared payload even if a provider returns unusually long metadata or lyrics.
        func clipped(_ text: String?) -> String? { text.map { String($0.prefix(240)) } }
        return WidgetSongSnapshot(trackID: id, title: String(track.name.prefix(120)),
                                  artist: String(track.artists.map(\.name).joined(separator: " · ").prefix(160)),
                                  original: clipped(line?.words), romanization: clipped(line.flatMap { readings[$0.id] }),
                                  nextOriginal: clipped(next?.words), nextRomanization: clipped(next.flatMap { readings[$0.id] }),
                                  updatedAt: date)
    }

    func update(spotify: SpotifyConnection, lyrics: PhoneLyricsStore, force: Bool = false) {
        // Keep the last widget snapshot on a cold launch before the user reconnects.
        guard spotify.connected else { return }
        guard let track = spotify.track, let id = track.id else { clear(); return }
        let document = lyrics.displayedTrackID == id ? lyrics.document : nil
        guard var snapshot = Self.snapshot(track: track, document: document, readings: lyrics.readings,
                                           position: spotify.playbackPosition(at: Date()),
                                           date: spotify.lastPlaybackSync ?? Date()) else { return }
        let key = id + (track.artworkURL?.absoluteString ?? "")
        if artworkKey != key {
            artworkKey = key
            artworkTask?.cancel()
            artworkData = nil
            if let url = track.artworkURL {
                artworkTask = Task { [weak self] in
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                              let image = UIImage(data: data), let self, self.artworkKey == key,
                              image.size.width > 0, image.size.height > 0 else { return }
                        let size = CGSize(width: 160, height: 160)
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 1
                        self.artworkData = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: size))
                        }.jpegData(compressionQuality: 0.8)
                        // Do not change the lyric timestamp when only the cover finishes downloading.
                        if var current = self.lastSnapshot, current.trackID == id {
                            current.artwork = self.artworkData
                            self.save(current)
                        }
                    } catch { /* The text widget remains useful without a cover. */ }
                }
            }
        }
        snapshot.artwork = artworkData
        if let previous = lastSnapshot, !force {
            var comparable = snapshot
            comparable.updatedAt = previous.updatedAt
            // Refresh a stable paused line occasionally without requesting a reload every second.
            if comparable == previous, snapshot.updatedAt.timeIntervalSince(previous.updatedAt) < 60 { return }
        }
        save(snapshot)
    }

    private func save(_ snapshot: WidgetSongSnapshot) {
        do {
            try storage.write(snapshot)
            lastSnapshot = snapshot
            hasCleared = false
            error = nil
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
        } catch { self.error = "小工具資料無法更新，請確認 App 與小工具的 App Groups 簽署設定。" }
    }

    func clear() {
        guard !hasCleared else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        artworkData = nil
        do {
            try storage.clear()
            lastSnapshot = nil
            hasCleared = true
            error = nil
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
        } catch { self.error = "小工具資料無法清除，請確認 App Groups 設定。" }
    }
}

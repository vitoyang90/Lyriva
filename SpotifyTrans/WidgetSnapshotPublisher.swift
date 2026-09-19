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

    static func snapshot(track: SpotifyTrack, document: LyricsDocument?, readings: [Int: String],
                         position: Double?, date: Date = Date()) -> WidgetSongSnapshot? {
        WidgetSongSnapshot.snapshot(track: track, document: document, readings: readings, position: position, date: date)
    }

    func update(spotify: SpotifyConnection, lyrics: PhoneLyricsStore, force: Bool = false) {
        // Keep the last widget snapshot on a cold launch before the user reconnects.
        guard spotify.connected else { return }
        guard let track = spotify.track, let id = track.id else {
            clear(controlID: spotify.playbackControlID, checkingControl: true)
            return
        }
        let document = lyrics.displayedTrackID == id ? lyrics.document : nil
        guard var snapshot = Self.snapshot(track: track, document: document, readings: lyrics.readings,
                                           position: spotify.playbackPosition(at: Date()),
                                           date: spotify.lastPlaybackSync ?? Date()) else { return }
        snapshot.authorizationID = try? KeychainSessionStorage().read()?.id
        snapshot.controlID = spotify.playbackControlID
        snapshot.isPlaying = spotify.isPlaying
        // Persist the position at updatedAt, not the position extrapolated for
        // this view render. Widget pause/restore uses this shared time anchor.
        snapshot.positionMS = spotify.progressMS
        if spotify.canPredictPlayback, let sampledAt = spotify.lastPlaybackSync, let position = spotify.progressMS {
            snapshot.playbackEndsAt = sampledAt.addingTimeInterval(max(0, Double(track.duration_ms) - position) / 1000)
        }
        if spotify.canPredictPlayback, let sampledAt = spotify.lastPlaybackSync, let position = spotify.progressMS,
           let document, document.isSynced {
            snapshot.playback = WidgetSongSnapshot.plan(track: track, document: document, readings: lyrics.readings,
                                                        sampledAt: sampledAt, position: position)
        }
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
        } catch { self.error = "小工具更新失敗，請稍後再試。" }
    }

    func clear(controlID: UUID? = nil, checkingControl: Bool = false) {
        guard !hasCleared else { return }
        do {
            if checkingControl {
                guard try storage.clearPlayback(controlID: controlID) else { return }
            } else { try storage.clear() }
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = nil
            artworkData = nil
            lastSnapshot = nil
            hasCleared = true
            error = nil
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
        } catch { self.error = "小工具資料清除失敗，請重新開啟 App。" }
    }
}

import Foundation
import UIKit
import ImageIO

struct WidgetPlaybackState: Sendable {
    let track: SpotifyTrack
    let positionMS: Double
    let isPlaying: Bool
    let sampledAt: Date

    static func decode(_ data: Data, at date: Date) throws -> Self? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["currently_playing_type"] as? String == "track" else { return nil }
        struct Playback: Decodable {
            let item: SpotifyTrack?
            let progress_ms: Double?
            let is_playing: Bool
        }
        let value = try JSONDecoder().decode(Playback.self, from: data)
        guard let track = value.item, track.id != nil, track.duration_ms > 0,
              let position = value.progress_ms, position.isFinite, position >= 0 else { return nil }
        return Self(track: track, positionMS: min(position, Double(track.duration_ms)),
                    isPlaying: value.is_playing, sampledAt: date)
    }
    var endsAt: Date? {
        isPlaying ? sampledAt.addingTimeInterval((Double(track.duration_ms) - positionMS) / 1000) : nil
    }
}

struct WidgetRefreshResult {
    let song: WidgetSongSnapshot?
    let refreshAt: Date
    static func nextRefresh(song: WidgetSongSnapshot?, now: Date) -> Date {
        // A request, not an alarm: WidgetKit can defer this date under its budget.
        // Keep retrying even after an expired snapshot, no lyrics, or paused playback.
        min(now.addingTimeInterval(300), max(now.addingTimeInterval(60), (song?.playbackEndsAt ?? song?.expiresAt ?? now).addingTimeInterval(2)))
    }
}

struct WidgetPlaybackRefresh {
    var playback: () async throws -> WidgetPlaybackState?
    var lyrics: (String) async throws -> LyricsDocument
    var artwork: (URL) async -> Data? = Self.cover
    var language: LyricsLanguage = .automatic

    // A successful playback response replaces the old song even if lyrics are unavailable.
    // Failures before playback is known throw, leaving the caller's last snapshot untouched.
    func load(previous: WidgetSongSnapshot?) async throws -> WidgetSongSnapshot? {
        guard let state = try await playback(), let id = state.track.id else { return nil }
        let document = try? await lyrics(id)
        try Task.checkCancellation()
        let converted = document.map { LyricsRomanizer().convert($0.lines.map(\.words), language: language) } ?? []
        let readings = Dictionary(uniqueKeysWithValues: zip(document?.lines ?? [], converted).compactMap { line, reading in
            reading.romanization.map { (line.id, $0) }
        })
        guard var song = WidgetSongSnapshot.snapshot(track: state.track, document: document, readings: readings,
                                                      position: state.positionMS, date: state.sampledAt) else { return nil }
        song.playbackEndsAt = state.endsAt
        if state.isPlaying, let document, document.isSynced {
            song.playback = WidgetSongSnapshot.plan(track: state.track, document: document, readings: readings,
                                                     sampledAt: state.sampledAt, position: state.positionMS)
        }
        if document == nil { song.notice = "暫時無法取得這首歌的歌詞" }
        if previous?.trackID == id { song.artwork = previous?.artwork }
        if song.artwork == nil, let url = state.track.smallArtworkURL { song.artwork = await artwork(url) }
        try Task.checkCancellation()
        return song
    }

    static func cover(_ url: URL) async -> Data? {
        // Spotify album metadata offers a small image; decode to a thumbnail to stay
        // within the extension's memory budget, including unexpectedly large images.
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4)),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

struct WidgetSpotifyClient {
    struct RateLimit: Error { let until: Date }
    let authorization: SpotifyAuthorization
    let session: URLSession
    init(authorization: SpotifyAuthorization = .shared, session: URLSession? = nil) {
        self.authorization = authorization
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoSpotifyRedirects(), delegateQueue: nil)
    }
    func playback() async throws -> WidgetPlaybackState? {
        for attempt in 0..<2 {
            let credential = try await authorization.validSession()
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!, timeoutInterval: 8)
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, rawResponse) = try await session.data(for: request)
            let response = rawResponse as? HTTPURLResponse
            switch response?.statusCode {
            case 200: return try WidgetPlaybackState.decode(data, at: Date())
            case 204: return nil
            case 401 where attempt == 0:
                try await authorization.invalidate(credential)
            case 429:
                let seconds = Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "300") ?? 300
                throw RateLimit(until: Date().addingTimeInterval(seconds.isFinite ? max(60, seconds) : 300))
            default: throw AuthorizationError.response(response?.statusCode ?? 0)
            }
        }
        throw AuthorizationError.signedOut
    }
}

// Called only when WidgetKit grants this extension an execution opportunity.
// It does not start a background polling loop or require the containing app to run.
struct WidgetTimelineLoader {
    func load() async -> WidgetRefreshResult {
        let storage = WidgetSnapshotStorage()
        let now = Date()
        let previous = storage.read()
        guard let credential = try? KeychainSessionStorage().read() else {
            return .init(song: nil, refreshAt: now.addingTimeInterval(300))
        }
        // Foreground app updates already provide fresh data. Avoid duplicating network
        // requests on every reloadTimelines call, but never reuse a finished song.
        if let previous, previous.authorizationID == credential.id, !previous.isExpired(at: now), now.timeIntervalSince(previous.updatedAt) < 15 {
            return .init(song: previous, refreshAt: WidgetRefreshResult.nextRefresh(song: previous, now: now))
        }
        do {
            var song = try await withThrowingTaskGroup(of: WidgetSongSnapshot?.self) { group in
                group.addTask {
                    let language = UserDefaults(suiteName: WidgetSongSnapshot.appGroup)?.string(forKey: "lyricsLanguage")
                        .flatMap(LyricsLanguage.init(rawValue:)) ?? .automatic
                    let loader = WidgetPlaybackRefresh(playback: { try await WidgetSpotifyClient().playback() },
                        lyrics: { try await DirectLyricsClient.shared.fetch(trackID: $0) }, language: language)
                    return try await loader.load(previous: previous)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(22))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            // Check the login again after every asynchronous operation. A response for
            // a previous account must not overwrite data after logout or reconnection.
            guard try KeychainSessionStorage().read()?.id == credential.id else {
                return .init(song: nil, refreshAt: Date().addingTimeInterval(300))
            }
            song?.authorizationID = credential.id
            let resolved = try storage.updateFromWidget(song, observedAt: now, sessionID: credential.id)
            return .init(song: resolved, refreshAt: WidgetRefreshResult.nextRefresh(song: resolved, now: Date()))
        } catch {
            let retry = (error as? WidgetSpotifyClient.RateLimit)?.until ?? Date().addingTimeInterval(300)
            let current = storage.read()
            let sameLogin = (try? KeychainSessionStorage().read()?.id) == credential.id
                && current?.authorizationID == credential.id
            return .init(song: sameLogin ? current : nil, refreshAt: retry)
        }
    }
}

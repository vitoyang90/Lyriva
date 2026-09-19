import Foundation
import UIKit
import ImageIO
import WidgetKit
import OSLog

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
    struct AwaitingCommandState: Error {}
    var playback: () async throws -> WidgetPlaybackState?
    var lyrics: (String) async throws -> LyricsDocument
    var artwork: (URL) async -> Data? = Self.cover
    var language: LyricsLanguage = .automatic
    var confirmationDelay: Duration = .milliseconds(350)
    var onPlayback: ((WidgetSongSnapshot) throws -> Void)? = nil

    // A successful playback response replaces the old song even if lyrics are unavailable.
    // Failures before playback is known throw, leaving the caller's last snapshot untouched.
    func load(previous: WidgetSongSnapshot?) async throws -> WidgetSongSnapshot? {
        var observed = try await playback()
        for _ in 0..<3 where previous?.acceptsPlayback(observed, at: Date()) == false {
            try await Task.sleep(for: confirmationDelay)
            observed = try await playback()
        }
        guard previous?.acceptsPlayback(observed, at: Date()) != false else { throw AwaitingCommandState() }
        guard let state = observed, let id = state.track.id else { return nil }
        // Publish the authoritative song before waiting for a different service's
        // lyrics/artwork. The operation identity also guards that later response.
        if var metadata = WidgetSongSnapshot.snapshot(track: state.track, document: nil, readings: [:],
                                                       position: state.positionMS, date: state.sampledAt) {
            metadata.controlID = previous?.controlID
            metadata.isPlaying = state.isPlaying
            metadata.playbackEndsAt = state.endsAt
            metadata.needsPlaybackRefresh = true
            if previous?.trackID == id {
                metadata.original = previous?.original
                metadata.romanization = previous?.romanization
                metadata.artwork = previous?.artwork
            }
            try onPlayback?(metadata)
        }
        let document = try? await lyrics(id)
        try Task.checkCancellation()
        let converted = document.map { LyricsRomanizer().convert($0.lines.map(\.words), language: language) } ?? []
        let readings = Dictionary(uniqueKeysWithValues: zip(document?.lines ?? [], converted).compactMap { line, reading in
            reading.romanization.map { (line.id, $0) }
        })
        guard var song = WidgetSongSnapshot.snapshot(track: state.track, document: document, readings: readings,
                                                      position: state.positionMS, date: state.sampledAt) else { return nil }
        song.playbackEndsAt = state.endsAt
        song.isPlaying = state.isPlaying
        song.controlID = previous?.controlID
        if state.isPlaying, let document, document.isSynced {
            song.playback = WidgetSongSnapshot.plan(track: state.track, document: document, readings: readings,
                                                     sampledAt: state.sampledAt, position: state.positionMS)
        }
        if document == nil { song.notice = "暫無歌詞" }
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

    func command(_ action: WidgetPlaybackAction, sessionID: UUID) async throws {
        guard action != .toggle else { throw WidgetPlaybackControlError.failed }
        for attempt in 0..<2 {
            let credential = try await authorization.validSession()
            guard credential.id == sessionID else { throw AuthorizationError.signedOut }
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(action.rawValue)")!,
                                     timeoutInterval: 8)
            request.httpMethod = action.method
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, rawResponse) = try await session.data(for: request)
            let response = rawResponse as? HTTPURLResponse
            // Record status only; never credentials or arbitrary server bodies.
            Logger(subsystem: "order.SpotifyTrans", category: "WidgetPlayback")
                .info("Spotify command \(action.rawValue, privacy: .public): HTTP \(response?.statusCode ?? 0)")
            switch response?.statusCode {
            case 200, 202, 204: return
            case 401 where attempt == 0: try await authorization.invalidate(credential)
            case 401: throw AuthorizationError.reauthorizationRequired
            case 403:
                struct Failure: Decodable {
                    struct Detail: Decodable { let reason: String?; let message: String? }
                    let error: Detail
                }
                let detail = try? JSONDecoder().decode(Failure.self, from: data).error
                if detail?.reason == "PREMIUM_REQUIRED" { throw WidgetPlaybackControlError.premiumRequired }
                if detail?.message?.lowercased().contains("insufficient client scope") == true {
                    throw WidgetPlaybackControlError.missingScope
                }
                throw WidgetPlaybackControlError.restricted
            case 404: throw WidgetPlaybackControlError.unavailableDevice
            case 429:
                let seconds = Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "300") ?? 300
                throw RateLimit(until: Date().addingTimeInterval(seconds.isFinite ? max(60, seconds) : 300))
            default: throw WidgetPlaybackControlError.failed
            }
        }
        throw AuthorizationError.reauthorizationRequired
    }
}

// Called only when WidgetKit grants this extension an execution opportunity.
// It does not start a background polling loop or require the containing app to run.
struct WidgetTimelineLoader {
    func load(forceRefresh: Bool = false) async -> WidgetRefreshResult {
        let storage = WidgetSnapshotStorage()
        let now = Date()
        let previous = storage.read()
        guard let credential = try? KeychainSessionStorage().read() else {
            return .init(song: nil, refreshAt: now.addingTimeInterval(300))
        }
        if previous?.isControlInFlight == true, previous?.authorizationID == credential.id {
            return .init(song: previous, refreshAt: now.addingTimeInterval(1))
        }
        // The intent-triggered reload must show pause/skip immediately, even if
        // the next Spotify/lyrics request is slow or fails. Never reuse old cues.
        if !forceRefresh, let controlled = try? storage.consumeControlPresentation(sessionID: credential.id) {
            return .init(song: controlled, refreshAt: now.addingTimeInterval(1))
        }
        // Foreground app updates already provide fresh data. Avoid duplicating network
        // requests on every reloadTimelines call, but never reuse a finished song.
        if !forceRefresh, let previous, previous.needsPlaybackRefresh != true,
           previous.authorizationID == credential.id, !previous.isExpired(at: now), now.timeIntervalSince(previous.updatedAt) < 15 {
            return .init(song: previous, refreshAt: WidgetRefreshResult.nextRefresh(song: previous, now: now))
        }
        do {
            var song = try await withThrowingTaskGroup(of: WidgetSongSnapshot?.self) { group in
                group.addTask {
                    if previous?.needsPlaybackRefresh == true {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let language = UserDefaults(suiteName: WidgetSongSnapshot.appGroup)?.string(forKey: "lyricsLanguage")
                        .flatMap(LyricsLanguage.init(rawValue:)) ?? .automatic
                    let loader = WidgetPlaybackRefresh(playback: { try await WidgetSpotifyClient().playback() },
                        lyrics: { try await DirectLyricsClient.shared.fetch(trackID: $0) }, language: language,
                        onPlayback: { metadata in
                            var metadata = metadata
                            metadata.authorizationID = credential.id
                            metadata.needsControlPresentation = true
                            let resolved = try storage.updateFromWidget(metadata, observedAt: now,
                                sessionID: credential.id, controlID: previous?.controlID)
                            guard resolved?.controlID == previous?.controlID,
                                  resolved?.isControlInFlight != true else { throw CancellationError() }
                            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSongSnapshot.kind)
                        })
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
            if song?.trackID == previous?.trackID, previous?.authorizationID == credential.id,
               previous?.acceptsPlayback(nil, at: Date()) == true {
                song?.controlError = previous?.controlError
            }
            let resolved = try storage.updateFromWidget(song, observedAt: now, sessionID: credential.id,
                                                       controlID: previous?.controlID)
            return .init(song: resolved, refreshAt: WidgetRefreshResult.nextRefresh(song: resolved, now: Date()))
        } catch {
            let retry = (error as? WidgetSpotifyClient.RateLimit)?.until
                ?? Date().addingTimeInterval(error is WidgetPlaybackRefresh.AwaitingCommandState ? 2 : 300)
            let current = storage.read()
            let sameLogin = (try? KeychainSessionStorage().read()?.id) == credential.id
                && current?.authorizationID == credential.id
            return .init(song: sameLogin ? current : nil, refreshAt: retry)
        }
    }
}

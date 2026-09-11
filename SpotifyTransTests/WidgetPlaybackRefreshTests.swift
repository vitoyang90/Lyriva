import Foundation
import Testing
@testable import SpotifyTrans

@Suite(.serialized)
struct WidgetPlaybackRefreshTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func state(id: String, playing: Bool = true, position: Double = 2000) throws -> WidgetPlaybackState {
        let data = Data("""
        {"currently_playing_type":"track","is_playing":\(playing),"progress_ms":\(position),
         "item":{"id":"\(id)","duration_ms":10000,"name":"\(id)","artists":[{"name":"Artist"}],"external_urls":{}}}
        """.utf8)
        return try #require(try WidgetPlaybackState.decode(data, at: now))
    }
    private var document: LyricsDocument {
        LyricsDocument(lines: [.init(id: 10, words: "こんにちは", startTimeMS: 1000),
                               .init(id: 40, words: "世界", startTimeMS: 3000)], isSynced: true)
    }
    @Test func automaticNextSongReplacesOldLyricsAndSchedulesFurtherRefresh() async throws {
        let oldState = try state(id: "old")
        let old = WidgetSongSnapshot.snapshot(track: oldState.track, document: document, readings: [:], position: 2000, date: now)
        let next = try state(id: "next")
        let loader = WidgetPlaybackRefresh(playback: { next }, lyrics: { id in
            #expect(id == "next")
            return document
        }, artwork: { _ in nil })
        let result = try #require(try await loader.load(previous: old))
        #expect(result.trackID == "next")
        #expect(result.title == "next")
        #expect(result.romanization != nil)
        #expect(result.lyrics(at: now.addingTimeInterval(1)).original == "世界")
        #expect(result.lyrics(at: now.addingTimeInterval(1)).romanization == "sekai")
        #expect(result.expiresAt == now.addingTimeInterval(8))
        #expect(WidgetRefreshResult.nextRefresh(song: result, now: now) > now)
        #expect(WidgetRefreshResult.nextRefresh(song: result, now: now.addingTimeInterval(60)) > now.addingTimeInterval(60))
    }
    @Test func missingLyricsStillChangesSongAndDropsPreviousWordsAndArtwork() async throws {
        let next = try state(id: "next")
        let old = WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", original: "old lyrics", updatedAt: now, artwork: Data([1]))
        let loader = WidgetPlaybackRefresh(playback: { next }, lyrics: { _ in throw URLError(.badServerResponse) })
        let song = try #require(try await loader.load(previous: old))
        #expect(song.trackID == "next")
        #expect(song.original == nil)
        #expect(song.romanization == nil)
        #expect(song.artwork == nil)
        #expect(song.notice != nil)
        #expect(song.expiresAt == now.addingTimeInterval(8))
    }
    @Test func pausedPlaybackFreezesLineButKeepsRequestingUpdates() async throws {
        let paused = try state(id: "paused", playing: false)
        let loader = WidgetPlaybackRefresh(playback: { paused }, lyrics: { _ in document })
        let song = try #require(try await loader.load(previous: nil))
        #expect(song.playback == nil)
        #expect(song.playbackEndsAt == nil)
        #expect(song.lyrics(at: now.addingTimeInterval(20)).original == "こんにちは")
        #expect(WidgetRefreshResult.nextRefresh(song: song, now: now) == now.addingTimeInterval(300))
    }
    @Test func noPlaybackClearsSongAndTransientFailureDoesNotMasqueradeAsNoPlayback() async throws {
        let stopped = WidgetPlaybackRefresh(playback: { nil }, lyrics: { _ in
            Issue.record("No song must not fetch lyrics")
            return document
        })
        #expect(try await stopped.load(previous: nil) == nil)
        let failed = WidgetPlaybackRefresh(playback: { throw URLError(.notConnectedToInternet) }, lyrics: { _ in document })
        await #expect(throws: (any Error).self) { try await failed.load(previous: nil) }
        #expect(try WidgetPlaybackState.decode(Data(#"{"currently_playing_type":"episode","item":{"name":"Podcast"}}"#.utf8), at: now) == nil)
    }
    @Test func staleArtworkCannotOverwriteANewerSong() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStorage(directory: directory)
        let next = WidgetSongSnapshot(trackID: "next", title: "Next", artist: "", updatedAt: now.addingTimeInterval(10))
        try store.write(next)
        try store.write(WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", updatedAt: now, artwork: Data([1])))
        #expect(store.read()?.trackID == "next")
    }
    @Test func reloadIsRequestedAtSongEndEvenWithoutTimedLyrics() throws {
        var song = WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", updatedAt: now)
        song.playbackEndsAt = now.addingTimeInterval(120)
        #expect(WidgetRefreshResult.nextRefresh(song: song, now: now) == now.addingTimeInterval(122))
        #expect(WidgetRefreshResult.nextRefresh(song: nil, now: now) == now.addingTimeInterval(60))
    }

    @Test func tokenRefreshIsSharedAndRotatedAcrossConcurrentClients() async throws {
        let store = MemorySessionStorage(value: credential(expired: true))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests = 0
        WidgetAuthProtocol.handler = { request in
            requests += 1
            #expect(request.url?.host == "accounts.spotify.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (200, [:], Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        let first = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        let second = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        async let a = first.validSession()
        async let b = second.validSession()
        let sessions = try await [a, b]
        #expect(sessions.allSatisfy { $0.accessToken == "new-access" && $0.refreshToken == "new-refresh" })
        #expect(requests == 1)
    }
    @Test @MainActor func appRelaunchRestoresEvenExpiredLoginAndExplicitLogoutClearsIt() throws {
        let store = MemorySessionStorage(value: credential(expired: true))
        let first = SpotifyConnection(sessionStorage: store)
        #expect(first.connected)
        let relaunched = SpotifyConnection(sessionStorage: store)
        #expect(relaunched.connected)
        relaunched.disconnect()
        #expect(try store.read() == nil)
        relaunched.restoreSavedSession()
        #expect(!relaunched.connected)
        #expect(!SpotifyConnection(sessionStorage: store).connected)
    }
    @Test @MainActor func temporarilyUnavailableSavedLoginCanBeRestoredWithoutSigningIn() throws {
        let original = credential(expired: false)
        let store = MemorySessionStorage(value: original)
        store.failReads = true
        let connection = SpotifyConnection(sessionStorage: store)
        #expect(!connection.connected)
        #expect(connection.status.contains("自動重試"))
        store.failReads = false
        connection.restoreSavedSession()
        #expect(connection.connected)
        #expect(try store.read() == original)
    }
    @Test func logoutDuringRefreshCannotRestoreCredentials() async throws {
        let store = MemorySessionStorage(value: credential(expired: true))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        WidgetAuthProtocol.handler = { _ in
            store.update { $0 = nil }
            return (200, [:], Data(#"{"access_token":"late","expires_in":3600}"#.utf8))
        }
        let authorization = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        await #expect(throws: AuthorizationError.self) { try await authorization.validSession() }
        #expect(try store.read() == nil)
    }
    @Test func temporaryTokenFailurePreservesLogin() async throws {
        let original = credential(expired: true)
        let store = MemorySessionStorage(value: original)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        WidgetAuthProtocol.handler = { _ in (503, [:], Data()) }
        let auth = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        await #expect(throws: AuthorizationError.self) { try await auth.validSession() }
        #expect(try store.read() == original)
    }
    @Test func widgetHTTPClientRefreshes401AndRespectsRateLimit() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = mockSession()
        let auth = SpotifyAuthorization(store: store, session: session, lockDirectory: directory)
        var playbackCalls = 0
        WidgetAuthProtocol.handler = { request in
            if request.url?.host == "accounts.spotify.com" {
                return (200, [:], Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            playbackCalls += 1
            if playbackCalls == 1 { return (401, [:], Data()) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
            return (204, [:], Data())
        }
        let client = WidgetSpotifyClient(authorization: auth, session: session)
        #expect(try await client.playback() == nil)
        #expect(playbackCalls == 2)
        WidgetAuthProtocol.handler = { _ in (429, ["Retry-After": "600"], Data()) }
        let before = Date()
        do {
            _ = try await client.playback()
            Issue.record("Expected rate limit")
        } catch let error as WidgetSpotifyClient.RateLimit {
            #expect(error.until.timeIntervalSince(before) >= 600)
        }
    }
    @Test @MainActor func seekUpdatesPositionWithoutStartingPausedPlaybackAndClampsBounds() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let session = mockSession()
        let auth = SpotifyAuthorization(store: store, session: session)
        let connection = SpotifyConnection(sessionStorage: store, authorization: auth, playbackSession: session)
        let data = Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":2000,"item":{"id":"seek-song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8)
        try connection.applyPlaybackResponse(data: data, response: HTTPURLResponse(url: URL(string: "https://api.spotify.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        var positions: [String] = []
        WidgetAuthProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/v1/me/player/seek")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
            positions.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)
            return (204, [:], Data())
        }
        await connection.seek(to: 5000, trackID: "seek-song")
        #expect(connection.progressMS == 5000)
        #expect(!connection.isPlaying)
        #expect(connection.playbackPosition(at: Date().addingTimeInterval(10)) == 5000)
        await connection.seek(to: -100, trackID: "seek-song")
        #expect(connection.progressMS == 0)
        await connection.seek(to: 20000, trackID: "seek-song")
        #expect(connection.progressMS == 9999)
        await connection.seek(to: .nan, trackID: "seek-song")
        await connection.seek(to: .infinity, trackID: "seek-song")
        await connection.seek(to: 1000, trackID: "previous-song")
        #expect(positions == ["5000", "0", "9999"])

        WidgetAuthProtocol.handler = { _ in (403, [:], Data()) }
        await connection.seek(to: 4000, trackID: "seek-song")
        #expect(connection.progressMS == 9999)
        #expect(connection.status.contains("Premium"))
        #expect(!connection.busy)
        #expect(!connection.showingActivity)
    }

    @Test @MainActor func seekWaitsForPollingAndThenOverridesItsOldPosition() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let session = mockSession()
        let auth = SpotifyAuthorization(store: store, session: session)
        let connection = SpotifyConnection(sessionStorage: store, authorization: auth, playbackSession: session)
        let data = Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":2000,"item":{"id":"seek-song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8)
        try connection.applyPlaybackResponse(data: data, response: HTTPURLResponse(url: URL(string: "https://api.spotify.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        var paths: [String] = []
        WidgetAuthProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("currently-playing") {
                return (200, [:], data)
            }
            return (204, [:], Data())
        }
        let poll = Task { await connection.refresh(showActivity: false) }
        await Task.yield()
        await connection.seek(to: 7000, trackID: "seek-song")
        await poll.value
        #expect(paths == ["/v1/me/player/currently-playing", "/v1/me/player/seek"])
        #expect(connection.progressMS == 7000)
        #expect(connection.isPlaying)
        #expect(connection.playbackPosition(at: Date().addingTimeInterval(1))! >= 8000)
    }

    private func credential(expired: Bool) -> SpotifySession {
        .init(id: UUID(), clientID: "test-client", accessToken: "old-access", refreshToken: "old-refresh",
              expiresAt: expired ? .distantPast : .distantFuture)
    }
    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WidgetAuthProtocol.self]
        return URLSession(configuration: config)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class MemorySessionStorage: SpotifySessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpotifySession?
    var failReads = false
    init(value: SpotifySession?) { self.value = value }
    func read() throws -> SpotifySession? {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw AuthorizationError.storage }
        return value
    }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }; try mutation(&value)
    }
}

private final class WidgetAuthProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

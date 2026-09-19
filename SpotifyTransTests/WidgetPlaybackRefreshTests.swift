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

    @Test @MainActor func returningFromSpotifyPollsDespitePendingCallbackAndClearsStartupMessage() async throws {
        let credential = credential(expired: false)
        let storage = MemorySessionStorage(value: credential)
        let session = mockSession()
        let starter = SpotifyPlaybackStarter(authorizer: ReturningPlaybackAuthorizer())
        let connection = SpotifyConnection(sessionStorage: storage,
            authorization: SpotifyAuthorization(store: storage), playbackSession: session, playbackStarter: starter)
        var calls = 0
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" { commands += 1; return (204, [:], Data()) }
            calls += 1
            if calls == 1 { return (204, [:], Data()) }
            if calls == 2 { return (503, [:], Data()) }
            return (200, [:], Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":2000,"item":{"id":"playing","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8))
        }
        starter.start(clientID: "test-client")
        await connection.refresh(showActivity: false)
        #expect(calls == 0)
        starter.returnedWithoutCallback()
        await connection.refresh(showActivity: false)
        #expect(calls == 2)
        #expect(commands == 1)
        #expect(starter.isConfirmingPlayback)
        await connection.refresh(showActivity: false)
        #expect(calls == 3)
        #expect(connection.isPlaying)
        #expect(connection.track?.id == "playing")
        #expect(!starter.isStarting)
        #expect(starter.message == nil)
    }

    @Test @MainActor func missingLocalTrackUsesSavedPlaybackGrantBeforeSDKAuthorization() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let authorizer = ReturningPlaybackAuthorizer()
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" { commands += 1; return (204, [:], Data()) }
            return (200, [:], Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":2000,"item":{"id":"song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
        #expect(connection.track == nil)
        await connection.control(.play)
        #expect(commands == 1)
        #expect(authorizer.calls == 0)
        #expect(connection.isPlaying)
        #expect(connection.track?.id == "song")
    }

    @Test @MainActor func deniedSDKCallbackResumesPausedSpotifyWithSavedWebAuthorization() async throws {
        let saved = credential(expired: false)
        let store = MemorySessionStorage(value: saved)
        let authorizer = ReturningPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
            if request.httpMethod == "PUT" {
                commands += 1
                return (commands == 1 ? 404 : 204, [:], Data())
            }
            return (200, [:], Data("""
                {"currently_playing_type":"track","is_playing":\(commands >= 2),"progress_ms":2000,
                 "item":{"id":"song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}
                """.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: starter)
        await connection.control(.play)
        #expect(authorizer.calls == 1)
        authorizer.callbackResult = false
        #expect(starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        await connection.refresh(showActivity: false)
        #expect(commands == 2)
        #expect(connection.isPlaying)
        #expect(!connection.requiresReauthorization)
        #expect(try store.read() == saved)
        #expect(starter.message == nil)
    }

    @Test func widgetCommandsUseCorrectEndpointsAndMethods() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let client = WidgetSpotifyClient(authorization: SpotifyAuthorization(store: store), session: mockSession())
        for (action, method) in [(WidgetPlaybackAction.previous, "POST"), (.next, "POST"), (.pause, "PUT"), (.play, "PUT")] {
            var requests = 0
            WidgetAuthProtocol.handler = { request in
                requests += 1
                #expect(request.url?.absoluteString == "https://api.spotify.com/v1/me/player/\(action.rawValue)")
                #expect(request.httpMethod == method)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
                return (204, [:], Data())
            }
            try await client.command(action, sessionID: credential.id)
            #expect(requests == 1)
        }
    }

    @Test @MainActor func favoriteTrackStartsAtBeginningThroughSpotify() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let request = SpotifyConnection.PlaybackCommand.track("chosen-song").request(token: "test")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/me/player/play")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["uris"] as? [String] == ["spotify:track:chosen-song"])
        #expect(body["position_ms"] as? Int == 0)
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" { commands += 1; return (204, [:], Data()) }
            return (200, [:], Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":0,"item":{"id":"chosen-song","duration_ms":10000,"name":"Chosen","artists":[],"external_urls":{}}}"#.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store), playbackSession: mockSession())
        await connection.playTrack(id: "chosen-song")
        #expect(commands == 1)
        #expect(connection.track?.id == "chosen-song")
        #expect(connection.isPlaying)
    }

    @Test @MainActor func favoriteRetriesSameSelectionAfterUnauthorizedResponse() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = mockSession()
        var commands: [String?] = []
        var refreshes = 0
        WidgetAuthProtocol.handler = { request in
            if request.url?.host == "accounts.spotify.com" {
                refreshes += 1
                return (200, [:], Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            }
            if request.httpMethod == "PUT" {
                commands.append(request.value(forHTTPHeaderField: "Authorization"))
                #expect(request.url?.path == "/v1/me/player/play")
                return (commands.count == 1 ? 401 : 204, [:], Data())
            }
            return (200, [:], Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":0,"item":{"id":"chosen-song","duration_ms":10000,"name":"Chosen","artists":[],"external_urls":{}}}"#.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store,
            authorization: SpotifyAuthorization(store: store, session: session, lockDirectory: directory), playbackSession: session)
        await connection.playTrack(id: "chosen-song")
        #expect(commands == ["Bearer old-access", "Bearer new-access"])
        #expect(refreshes == 1)
        #expect(connection.track?.id == "chosen-song")
        #expect(connection.isPlaying)
        #expect(!connection.playbackStarter.isStarting)
    }

    @Test @MainActor func favoritesFollowActiveComputerThenPhoneWithoutAuthorizingOrTransferring() async throws {
        var saved = credential(expired: false)
        saved.scopes = ["user-read-playback-state", "user-modify-playback-state"]
        let store = MemorySessionStorage(value: saved)
        let authorizer = ReturningPlaybackAuthorizer()
        var active = "computer"
        var song = "first"
        var destinations: [String] = []
        var requestedPaths: [String] = []
        WidgetAuthProtocol.handler = { request in
            let path = request.url!.path
            requestedPaths.append(path)
            if path == "/v1/me/player/devices" {
                return (200, [:], Data("""
                    {"devices":[
                      {"id":"computer","name":"Mac","is_active":\(active == "computer"),"is_restricted":false},
                      {"id":"phone","name":"iPhone","is_active":\(active == "phone"),"is_restricted":false}]}
                    """.utf8))
            }
            if request.httpMethod == "PUT" {
                #expect(path == "/v1/me/player/play") // Never transfer playback or pause the other device.
                destinations.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "device_id" }!.value!)
                return (204, [:], Data())
            }
            return (200, [:], Data("""
                {"currently_playing_type":"track","is_playing":true,"progress_ms":0,
                 "device":{"id":"\(active)","name":"\(active == "computer" ? "Mac" : "iPhone")","is_active":true,"is_restricted":false},
                 "item":{"id":"\(song)","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}
                """.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
        await connection.playTrack(id: song)
        #expect(connection.playbackDeviceName == "Mac")
        active = "phone"
        song = "second"
        await connection.playTrack(id: song)
        #expect(connection.playbackDeviceName == "iPhone")
        #expect(connection.track?.id == "second")
        #expect(destinations == ["computer", "phone"])
        #expect(requestedPaths == Array(repeating: ["/v1/me/player/devices", "/v1/me/player/play", "/v1/me/player"], count: 2).flatMap { $0 })
        #expect(authorizer.calls == 0)
        #expect(!connection.requiresReauthorization)
        #expect(!connection.needsPlaybackDevicePermission)
    }

    @Test @MainActor func unavailableOrRestrictedActiveDeviceDoesNotStartAnotherDeviceOrAuthorization() async throws {
        for devices in [
            #"{"devices":[]}"#,
            #"{"devices":[{"id":"phone","name":"iPhone","is_active":false,"is_restricted":false}]}"#,
            #"{"devices":[{"id":"computer","name":"Mac","is_active":true,"is_restricted":true},{"id":"phone","name":"iPhone","is_active":false,"is_restricted":false}]}"#
        ] {
            var saved = credential(expired: false)
            saved.scopes = ["user-read-playback-state"]
            let store = MemorySessionStorage(value: saved)
            let authorizer = ReturningPlaybackAuthorizer()
            var puts = 0
            WidgetAuthProtocol.handler = { request in
                if request.httpMethod == "PUT" { puts += 1 }
                return (200, [:], Data(devices.utf8))
            }
            let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
                playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
            await connection.playTrack(id: "chosen")
            #expect(puts == 0)
            #expect(authorizer.calls == 0)
            #expect(!connection.playbackStarter.isStarting)
            #expect(!connection.requiresReauthorization)
            #expect(connection.status.contains("裝置"))
        }
    }

    @Test @MainActor func legacyFavoriteNoDeviceDoesNotAuthorizeOnEverySelection() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let authorizer = ReturningPlaybackAuthorizer()
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            #expect(request.httpMethod == "PUT")
            commands += 1
            return (404, [:], Data())
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
        await connection.playTrack(id: "first")
        await connection.playTrack(id: "second")
        #expect(commands == 2)
        #expect(authorizer.calls == 0)
        #expect(connection.needsPlaybackDevicePermission)
        #expect(!connection.requiresReauthorization)
        #expect(connection.status.contains("播放裝置"))
    }

    @Test @MainActor func missingDeviceScopeOffersUpgradeWithoutOpeningAuthorizationOrSendingPlayback() async throws {
        var saved = credential(expired: false)
        saved.scopes = ["user-read-playback-state"]
        let store = MemorySessionStorage(value: saved)
        let authorizer = ReturningPlaybackAuthorizer()
        WidgetAuthProtocol.handler = { request in
            #expect(request.url?.path == "/v1/me/player/devices")
            return (403, [:], Data(#"{"error":{"message":"Insufficient client scope"}}"#.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
        await connection.playTrack(id: "chosen")
        #expect(connection.needsPlaybackDevicePermission)
        #expect(!connection.requiresReauthorization)
        #expect(authorizer.calls == 0)
        #expect(try store.read() == saved)
    }

    @Test func playbackScopesSurviveTokenRefreshWithoutAnotherConsent() async throws {
        let store = MemorySessionStorage(value: nil)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var exchanges = 0
        WidgetAuthProtocol.handler = { _ in
            exchanges += 1
            return (200, [:], Data(#"{"access_token":"saved","refresh_token":"refresh","expires_in":3600}"#.utf8))
        }
        let authorization = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        try await authorization.exchange(code: "code", verifier: "verifier", clientID: "client", redirectURI: SpotifyConnection.redirectURI)
        let original = try await authorization.validSession()
        #expect(original.scopes?.contains("user-read-playback-state") == true)
        try await authorization.invalidate(original)
        let refreshed = try await authorization.validSession()
        #expect(refreshed.scopes == original.scopes)
        #expect(exchanges == 2)
    }

    @Test @MainActor func activeDeviceLookupRefreshesExpiredAccessWithoutSDKAuthorization() async throws {
        var saved = credential(expired: false)
        saved.scopes = ["user-read-playback-state"]
        let store = MemorySessionStorage(value: saved)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = mockSession()
        let authorizer = ReturningPlaybackAuthorizer()
        var lookups = 0
        var refreshes = 0
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.url?.host == "accounts.spotify.com" {
                refreshes += 1
                return (200, [:], Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            if request.url?.path == "/v1/me/player/devices" {
                lookups += 1
                if lookups == 1 { return (401, [:], Data()) }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
                return (200, [:], Data(#"{"devices":[{"id":"mac","name":"Mac","is_active":true,"is_restricted":false}]}"#.utf8))
            }
            if request.httpMethod == "PUT" {
                commands += 1
                #expect(request.url?.query == "device_id=mac")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
                return (204, [:], Data())
            }
            return (200, [:], Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":0,"item":{"id":"chosen","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store,
            authorization: SpotifyAuthorization(store: store, session: session, lockDirectory: directory),
            playbackSession: session, playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer))
        await connection.playTrack(id: "chosen")
        #expect(lookups == 2)
        #expect(refreshes == 1)
        #expect(commands == 1)
        #expect(authorizer.calls == 0)
        #expect(connection.isPlaying)
    }

    @Test @MainActor func repeatedUnauthorizedSelectionStopsAfterOneRetry() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = mockSession()
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.url?.host == "accounts.spotify.com" {
                return (200, [:], Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            }
            commands += 1
            return (401, [:], Data())
        }
        let connection = SpotifyConnection(sessionStorage: store,
            authorization: SpotifyAuthorization(store: store, session: session, lockDirectory: directory), playbackSession: session)
        await connection.playTrack(id: "chosen-song")
        #expect(commands == 2)
        #expect(connection.requiresReauthorization)
        #expect(!connection.busy)
        #expect(!connection.playbackStarter.isStarting)
    }

    @Test @MainActor func acceptedFavoriteWaitsForSelectedPlayingTrack() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        var id = "old-song"
        var playing = true
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" { commands += 1; return (204, [:], Data()) }
            return (200, [:], Data("""
                {"currently_playing_type":"track","is_playing":\(playing),"progress_ms":0,
                 "item":{"id":"\(id)","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}
                """.utf8))
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store), playbackSession: mockSession())
        await connection.playTrack(id: "chosen-song")
        #expect(connection.playbackStarter.isConfirmingPlayback)
        id = "chosen-song"
        playing = false
        await connection.refresh(showActivity: false)
        #expect(connection.playbackStarter.isConfirmingPlayback)
        playing = true
        await connection.refresh(showActivity: false)
        #expect(!connection.playbackStarter.isStarting)
        #expect(commands == 1)
    }

    @Test @MainActor func acceptedFavoriteWithEmptyPlayerRetriesWithoutSDKAuthorization() async throws {
        for emptyCode in [204, 200] {
            let store = MemorySessionStorage(value: credential(expired: false))
            let authorizer = ReturningPlaybackAuthorizer()
            let starter = SpotifyPlaybackStarter(authorizer: authorizer)
            var commands = 0
            WidgetAuthProtocol.handler = { request in
                if request.httpMethod == "PUT" { commands += 1; return (204, [:], Data()) }
                if commands == 1 {
                    return (emptyCode, [:], Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":0,"item":null}"#.utf8))
                }
                let id = commands == 0 ? "old-song" : "chosen-song"
                return (200, [:], Data("""
                    {"currently_playing_type":"track","is_playing":true,"progress_ms":0,
                     "item":{"id":"\(id)","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}
                    """.utf8))
            }
            let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
                playbackSession: mockSession(), playbackStarter: starter)
            await connection.refresh(showActivity: false)
            #expect(connection.isPlaying)
            await connection.playTrack(id: "chosen-song")
            #expect(connection.track == nil)
            #expect(authorizer.calls == 0) // Allow the first transitional empty response.
            await connection.refresh(showActivity: false)
            #expect(authorizer.calls == 0)
            #expect(commands == 2)
            #expect(connection.track?.id == "chosen-song")
            #expect(connection.isPlaying)
            #expect(!starter.isStarting)
            #expect(starter.message == nil)
        }
    }

    @Test @MainActor func acceptedFavoriteRecoveryDoesNotKeepWakingSpotifyWhenPlayerStaysEmpty() async throws {
        let store = MemorySessionStorage(value: credential(expired: false))
        let authorizer = ReturningPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" { commands += 1 }
            return (204, [:], Data())
        }
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: starter)
        await connection.playTrack(id: "chosen-song")
        await connection.refresh(showActivity: false)
        for _ in 0..<4 { await connection.refresh(showActivity: false) }
        #expect(authorizer.calls == 0)
        #expect(commands == 2)
        #expect(starter.isConfirmingPlayback)
        starter.reset()
    }

    @Test @MainActor func pausedWidgetEntryClearsLaunchErrorAndPreservesSongOnEmptyResponse() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: store)
        let authorizer = ReturningPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: starter, widgetStorage: storage)
        let paused = Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":2000,"item":{"id":"paused","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8)
        try connection.applyPlaybackResponse(data: paused, response: HTTPURLResponse(
            url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!)
        starter.start(clientID: "test-client")
        authorizer.callbackResult = false
        #expect(starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        #expect(starter.message?.contains("授權未完成") == true)
        var requests = 0
        WidgetAuthProtocol.handler = { request in
            requests += 1
            #expect(request.httpMethod == "GET")
            return (204, [:], Data())
        }
        await connection.openFromWidget()
        #expect(connection.connected)
        #expect(!connection.requiresReauthorization)
        #expect(connection.track?.id == "paused")
        #expect(connection.progressMS == 2000)
        #expect(!connection.isPlaying)
        #expect(connection.playbackPosition(at: Date().addingTimeInterval(20)) == 2000)
        #expect(starter.message == nil)
        #expect(authorizer.calls == 1)
        #expect(requests == 1)
        #expect(try store.read() == credential)
    }

    @Test @MainActor func coldWidgetEntryRestoresOnlySameAccountsRecentPausedSnapshot() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: store)
        var snapshot = WidgetSongSnapshot(trackID: "paused", title: "Paused song", artist: "Artist", updatedAt: Date(),
            authorizationID: credential.id, isPlaying: false, durationMS: 10000, positionMS: 2000)
        try storage.write(snapshot)
        WidgetAuthProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            return (204, [:], Data())
        }
        let authorizer = ReturningPlaybackAuthorizer()
        let connection = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
            playbackSession: mockSession(), playbackStarter: SpotifyPlaybackStarter(authorizer: authorizer), widgetStorage: storage)
        #expect(connection.track == nil)
        await connection.openFromWidget()
        #expect(connection.track?.id == "paused")
        #expect(connection.progressMS == 2000)
        #expect(!connection.isPlaying)
        #expect(connection.connected)
        #expect(authorizer.calls == 0)
        snapshot.authorizationID = UUID()
        snapshot.updatedAt = Date()
        try storage.write(snapshot)
        let other = SpotifyConnection(sessionStorage: store, authorization: SpotifyAuthorization(store: store),
                                      playbackSession: mockSession(), widgetStorage: storage)
        await other.openFromWidget()
        #expect(other.track == nil)
    }

    @Test func widgetCommandRejectsStaleLoginAndExplainsUnavailableDevice() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let client = WidgetSpotifyClient(authorization: SpotifyAuthorization(store: store), session: mockSession())
        var requests = 0
        WidgetAuthProtocol.handler = { _ in
            requests += 1
            return (404, [:], Data())
        }
        await #expect(throws: AuthorizationError.self) { try await client.command(.next, sessionID: UUID()) }
        #expect(requests == 0)
        do {
            try await client.command(.pause, sessionID: credential.id)
            Issue.record("Missing device must fail")
        } catch {
            #expect(WidgetPlaybackControlError.message(for: error) == "請先在 Spotify 開始播放，再試一次。")
        }
        #expect(requests == 1)
    }

    @Test func widgetTogglePausesThenResumesThroughSpotifyAndRestoresLyricTimeline() async throws {
        let credential = credential(expired: false)
        let sessionStore = MemorySessionStorage(value: credential)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: sessionStore)
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", original: "line",
            updatedAt: Date(), authorizationID: credential.id, isPlaying: true))
        var playing = true
        var commands: [String] = []
        WidgetAuthProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                let path = request.url!.lastPathComponent
                commands.append(path)
                playing = path == "play"
                return (204, [:], Data())
            }
            #expect(request.httpMethod == "GET")
            return (200, [:], Data("""
                {"currently_playing_type":"track","is_playing":\(playing),"progress_ms":2000,
                 "item":{"id":"song","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}
                """.utf8))
        }
        let client = WidgetSpotifyClient(authorization: SpotifyAuthorization(store: sessionStore), session: mockSession())
        var displayedStates: [Bool] = []
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory,
            command: { try await client.command($0, sessionID: $1) }, playback: { try await client.playback() },
            stateChanged: { displayedStates.append(storage.read()!.playbackIsPlaying) }, confirmationDelay: .zero)
        let loader = WidgetPlaybackRefresh(playback: { try await client.playback() }, lyrics: { _ in document })
        try await controller.perform(.toggle, sessionID: credential.id)
        let paused = try #require(try await loader.load(previous: storage.read()))
        #expect(!paused.playbackIsPlaying)
        #expect(paused.playback == nil)
        #expect(paused.lyrics(at: Date().addingTimeInterval(5)).original == "こんにちは")
        try await controller.perform(.toggle, sessionID: credential.id)
        let resumed = try #require(try await loader.load(previous: storage.read()))
        #expect(resumed.playbackIsPlaying)
        #expect(resumed.playback?.isValid == true)
        #expect(resumed.lyrics(at: resumed.updatedAt.addingTimeInterval(2)).original == "世界")
        #expect(commands == ["pause", "play"])
        #expect(displayedStates == [false, false, true, true])
        #expect(try sessionStore.read() == credential)
    }

    @Test func rapidSecondToggleResumesInsteadOfRepeatingStalePauseAction() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", updatedAt: Date(),
                                             authorizationID: credential.id, isPlaying: true))
        var resumePause: CheckedContinuation<Void, Never>?
        var actions: [WidgetPlaybackAction] = []
        var playing = true
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { action, _ in
            actions.append(action)
            #expect(storage.read()?.playbackIsPlaying == (action == .play))
            if action == .pause { await withCheckedContinuation { resumePause = $0 } }
            playing = action == .play
        }, playback: { try state(id: "song", playing: playing) }, confirmationDelay: .zero)
        let first = Task { try await controller.perform(.toggle, sessionID: credential.id) }
        while resumePause == nil { await Task.yield() }
        #expect(storage.read()?.playbackIsPlaying == false)
        #expect(storage.read()?.isControlInFlight == true)
        let second = Task { try await controller.perform(.toggle, sessionID: credential.id) }
        for _ in 0..<5 { await Task.yield() }
        #expect(actions == [.pause])
        resumePause?.resume()
        try await first.value
        try await second.value
        #expect(actions == [.pause, .play])
        #expect(storage.read()?.playbackIsPlaying == true)
        #expect(storage.read()?.controlError == nil)
    }

    @Test func failedToggleCorrectsOptimisticStateWithAndWithoutPlaybackResponse() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", updatedAt: Date(),
                                             authorizationID: credential.id, isPlaying: true))
        for canReadPlayback in [true, false] {
            let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { action, _ in
                #expect(action == .pause)
                #expect(storage.read()?.playbackIsPlaying == false)
                throw WidgetPlaybackControlError.restricted
            }, playback: {
                if !canReadPlayback { throw URLError(.notConnectedToInternet) }
                return try state(id: "song", playing: true)
            }, confirmationDelay: .zero)
            await #expect(throws: WidgetPlaybackControlError.self) {
                try await controller.perform(.toggle, sessionID: credential.id)
            }
            #expect(storage.read()?.playbackIsPlaying == true)
            #expect(storage.read()?.pendingPlaybackAction == nil)
            #expect(storage.read()?.playback == nil)
            #expect(storage.read()?.controlError != nil)
        }
    }

    @Test func widgetCommandRetriesUnauthorizedButNotSkipServerFailures() async throws {
        let credential = credential(expired: false)
        let store = MemorySessionStorage(value: credential)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = mockSession()
        let auth = SpotifyAuthorization(store: store, session: session, lockDirectory: directory)
        let client = WidgetSpotifyClient(authorization: auth, session: session)
        var commands = 0
        WidgetAuthProtocol.handler = { request in
            if request.url?.host == "accounts.spotify.com" {
                return (200, [:], Data(#"{"access_token":"new-access","expires_in":3600}"#.utf8))
            }
            commands += 1
            return (commands == 1 ? 401 : 204, [:], Data())
        }
        try await client.command(.next, sessionID: credential.id)
        #expect(commands == 2)
        commands = 0
        WidgetAuthProtocol.handler = { _ in
            commands += 1
            return (503, [:], Data())
        }
        await #expect(throws: WidgetPlaybackControlError.self) { try await client.command(.next, sessionID: credential.id) }
        #expect(commands == 1)
    }

    @Test func widgetPauseFreezesLyricsAndSkipClearsOldLyrics() throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        var song = WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", updatedAt: now,
                                      authorizationID: credential.id, isPlaying: true)
        song.playback = .init(sampledAt: now, positionMS: 0, durationMS: 10000, lines: [
            .init(startMS: 0, original: "first", romanization: nil),
            .init(startMS: 1000, original: "second", romanization: nil)
        ])
        try storage.write(song)
        try storage.updateAfterControl(.pause, at: now.addingTimeInterval(2), sessionID: credential.id)
        let paused = try #require(storage.read())
        #expect(!paused.playbackIsPlaying)
        #expect(paused.playback == nil)
        #expect(paused.lyrics(at: now.addingTimeInterval(5)).original == "second")
        try storage.updateAfterControl(.play, at: now.addingTimeInterval(3), sessionID: credential.id)
        #expect(storage.read()?.playbackIsPlaying == true)
        try storage.updateAfterControl(.next, at: now.addingTimeInterval(4), sessionID: credential.id)
        #expect(storage.read()?.original == nil)
        #expect(storage.read()?.isExpired(at: now.addingTimeInterval(4)) == true)
        let before = storage.read()
        try storage.updateAfterControl(.pause, at: now.addingTimeInterval(5), sessionID: UUID())
        #expect(storage.read() == before)
    }

    @Test func controlSequenceUpdatesStateAndReleasesLockWithoutFetchingLyrics() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", original: "line", updatedAt: now,
                                              authorizationID: credential.id, isPlaying: true))
        var actions: [WidgetPlaybackAction] = []
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { action, id in
            #expect(id == credential.id)
            actions.append(action)
        })
        try await controller.perform(.pause, sessionID: credential.id)
        #expect(storage.read()?.isPlaying == false)
        let first = try #require(try storage.consumeControlPresentation(sessionID: credential.id))
        #expect(first.playback == nil)
        #expect(first.isPlaying == false)
        #expect(first.needsPlaybackRefresh == true)
        #expect(try storage.consumeControlPresentation(sessionID: credential.id) == nil)
        try await controller.perform(.next, sessionID: credential.id)
        #expect(storage.read()?.original == nil)
        try await controller.perform(.previous, sessionID: credential.id)
        #expect(actions == [.pause, .next, .previous])
        #expect(storage.read()?.pendingPlaybackAction == "previous")
        #expect(storage.read()?.needsControlPresentation == true)
    }

    @Test func commandFailureStopsOldLyricsAndPublishesVisibleError() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", original: "line", updatedAt: now,
                                              authorizationID: credential.id, isPlaying: true))
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { _, _ in
            throw WidgetPlaybackControlError.restricted
        })
        await #expect(throws: WidgetPlaybackControlError.self) { try await controller.perform(.next, sessionID: credential.id) }
        let errorState = try #require(try storage.consumeControlPresentation(sessionID: credential.id))
        #expect(errorState.isPlaying == true)
        #expect(errorState.original == nil)
        #expect(errorState.playback == nil)
        #expect(errorState.needsPlaybackRefresh == true)
        #expect(errorState.controlInFlight == false)
        #expect(errorState.controlError == "Spotify 目前不允許此播放操作。")
        let lock = try SharedFileLock(name: "widget-playback-control.lock", directory: directory)
        #expect(try lock.tryAcquire())
    }

    @Test func failedHTTPCommandStillConfirmsActualSkipWithoutSendingItTwice() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", original: "old lyrics",
                                             updatedAt: now, authorizationID: credential.id, isPlaying: true))
        var commands = 0
        var reads = 0
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { _, _ in
            commands += 1
            #expect(storage.read()?.original == nil)
            #expect(storage.read()?.isControlInFlight == true)
            throw URLError(.timedOut)
        }, playback: {
            reads += 1
            return try state(id: reads == 1 ? "old" : "new")
        }, confirmationDelay: .zero)
        try await controller.perform(.next, sessionID: credential.id)
        #expect(commands == 1)
        #expect(reads == 2)
        #expect(storage.read()?.trackID == "new")
        #expect(storage.read()?.controlError == nil)
        #expect(storage.read()?.controlInFlight == false)
    }

    @Test func slowLyricsCannotReplaceASecondConfirmedSkipEvenWithLaterTimestamp() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "a", title: "A", artist: "", updatedAt: now,
                                             authorizationID: credential.id, isPlaying: true))
        var currentTrack = "b"
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { _, _ in },
            playback: { try state(id: currentTrack) }, confirmationDelay: .zero)
        try await controller.perform(.next, sessionID: credential.id)
        let first = try #require(storage.read())
        var resumeLyrics: CheckedContinuation<LyricsDocument, Never>?
        let loader = WidgetPlaybackRefresh(playback: { try state(id: "b") }, lyrics: { _ in
            await withCheckedContinuation { resumeLyrics = $0 }
        })
        let slowLoad = Task { try await loader.load(previous: first) }
        while resumeLyrics == nil { await Task.yield() }
        currentTrack = "c"
        try await controller.perform(.next, sessionID: credential.id)
        let second = try #require(storage.read())
        #expect(second.trackID == "c")
        #expect(second.pendingPlaybackAction == nil)
        #expect(second.controlID != first.controlID)
        resumeLyrics?.resume(returning: document)
        var late = try #require(try await slowLoad.value)
        late.authorizationID = credential.id
        late.updatedAt = Date().addingTimeInterval(1)
        _ = try storage.updateFromWidget(late, observedAt: first.updatedAt, sessionID: credential.id,
                                         controlID: first.controlID)
        #expect(storage.read()?.trackID == "c")
        // A foreground poll or delayed cover captured before the new command
        // must obey the same revision check as the widget's lyrics fetch.
        try storage.write(late)
        #expect(storage.read()?.trackID == "c")
        #expect(try storage.clearPlayback(controlID: first.controlID) == false)
        #expect(storage.read()?.trackID == "c")
        var fresh = second
        fresh.updatedAt = Date().addingTimeInterval(2)
        fresh.original = "current lyrics"
        try storage.write(fresh)
        #expect(storage.read()?.original == "current lyrics")
        // Also reject an older no-playback response, even after confirmation.
        _ = try storage.updateFromWidget(nil, observedAt: late.updatedAt, sessionID: credential.id,
                                         controlID: first.controlID)
        #expect(storage.read()?.trackID == "c")
    }

    @Test func publishesNewTitleBeforeSlowLyricsAndAcceptsEnrichmentForSameOperation() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", updatedAt: now,
                                             authorizationID: credential.id, isPlaying: true))
        let startedAt = now.addingTimeInterval(-1)
        let loader = WidgetPlaybackRefresh(playback: { try state(id: "new") }, lyrics: { _ in
            #expect(storage.read()?.trackID == "new")
            #expect(storage.read()?.original == nil)
            return document
        }, onPlayback: { metadata in
            var metadata = metadata
            metadata.authorizationID = credential.id
            _ = try storage.updateFromWidget(metadata, observedAt: startedAt, sessionID: credential.id)
        })
        var complete = try #require(try await loader.load(previous: storage.read()))
        complete.authorizationID = credential.id
        _ = try storage.updateFromWidget(complete, observedAt: startedAt, sessionID: credential.id)
        #expect(storage.read()?.original == "こんにちは")
        #expect(storage.read()?.needsPlaybackRefresh != true)
    }

    @Test func forbiddenPlaybackDoesNotAutomaticallyBlamePremium() async throws {
        let credential = credential(expired: false)
        let client = WidgetSpotifyClient(authorization: SpotifyAuthorization(store: MemorySessionStorage(value: credential)),
                                        session: mockSession())
        for (reason, expected) in [("RESTRICTION_VIOLATED", "Spotify 目前不允許此播放操作。"),
                                  ("PREMIUM_REQUIRED", "此操作需要 Spotify Premium。")] {
            WidgetAuthProtocol.handler = { _ in
                (403, [:], Data("{\"error\":{\"reason\":\"\(reason)\"}}".utf8))
            }
            do { try await client.command(.next, sessionID: credential.id); Issue.record("Expected rejection") }
            catch { #expect(WidgetPlaybackControlError.message(for: error) == expected) }
        }
    }

    @Test func stalePlaybackCannotRestartLyricsAfterPauseOrRestoreSkippedSong() async throws {
        let playing = try state(id: "song")
        var song = WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", original: "frozen", updatedAt: Date(),
                                      isPlaying: false, needsPlaybackRefresh: true, pendingPlaybackAction: "pause")
        var lyricRequests = 0
        let stale = WidgetPlaybackRefresh(playback: { playing }, lyrics: { _ in
            lyricRequests += 1
            return document
        })
        await #expect(throws: WidgetPlaybackRefresh.AwaitingCommandState.self) { try await stale.load(previous: song) }
        #expect(lyricRequests == 0)
        #expect(!song.acceptsPlayback(nil, at: Date()))
        let paused = try state(id: "song", playing: false)
        #expect(song.acceptsPlayback(paused, at: Date()))
        song.pendingPlaybackAction = "next"
        #expect(!song.acceptsPlayback(playing, at: Date()))
        #expect(song.acceptsPlayback(try state(id: "next"), at: Date()))
        song.pendingPlaybackAction = "previous"
        #expect(!song.acceptsPlayback(playing, at: Date()))
        #expect(song.acceptsPlayback(try state(id: "song", position: 0), at: Date()))
        #expect(song.acceptsPlayback(playing, at: song.updatedAt.addingTimeInterval(11)))
    }

    @Test func skippingWaitsForNewSongThenRefreshesTitleAndLyrics() async throws {
        let old = try state(id: "old")
        let next = try state(id: "next")
        let previous = WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", updatedAt: Date(),
                                           needsPlaybackRefresh: true, pendingPlaybackAction: "next")
        var reads = 0
        let loader = WidgetPlaybackRefresh(playback: {
            reads += 1
            return reads == 1 ? old : next
        }, lyrics: { id in
            #expect(id == "next")
            return document
        }, confirmationDelay: .zero)
        let result = try #require(try await loader.load(previous: previous))
        #expect(reads == 2)
        #expect(result.trackID == "next")
        #expect(result.title == "next")
        #expect(result.original == "こんにちは")
        #expect(result.romanization != nil)
        #expect(result.pendingPlaybackAction == nil)
        #expect(result.needsPlaybackRefresh == nil)
    }

    @Test func olderRefreshCannotUndoAnotherControlCommand() throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        var old = WidgetSongSnapshot(trackID: "old", title: "Old", artist: "", updatedAt: now,
                                     authorizationID: credential.id, isPlaying: true)
        try storage.write(old)
        try storage.updateAfterControl(.pause, at: now.addingTimeInterval(2), sessionID: credential.id)
        old.updatedAt = now.addingTimeInterval(3)
        let resolved = try storage.updateFromWidget(old, observedAt: now.addingTimeInterval(1), sessionID: credential.id)
        #expect(resolved?.isPlaying == false)
        #expect(resolved?.pendingPlaybackAction == "pause")
    }

    @Test func concurrentButtonCommandsExecuteInOrder() async throws {
        let credential = credential(expired: false)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WidgetSnapshotStorage(directory: directory, sessionStorage: MemorySessionStorage(value: credential))
        try storage.write(WidgetSongSnapshot(trackID: "song", title: "Song", artist: "", updatedAt: now,
                                              authorizationID: credential.id, isPlaying: true))
        var resume: CheckedContinuation<Void, Never>?
        var actions: [WidgetPlaybackAction] = []
        let controller = WidgetPlaybackController(storage: storage, lockDirectory: directory, command: { action, _ in
            actions.append(action)
            if action == .pause { await withCheckedContinuation { resume = $0 } }
        })
        let pause = Task { try await controller.perform(.pause, sessionID: credential.id) }
        while resume == nil { await Task.yield() }
        let skip = Task { try await controller.perform(.next, sessionID: credential.id) }
        for _ in 0..<5 { await Task.yield() }
        #expect(actions == [.pause])
        resume?.resume()
        try await pause.value
        try await skip.value
        #expect(actions == [.pause, .next])
        #expect(storage.read()?.pendingPlaybackAction == "next")
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
    @Test @MainActor func expiredRefreshTokenRequiresAuthorizationWithoutRepeatedRequests() async throws {
        let original = credential(expired: true)
        let store = MemorySessionStorage(value: original)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests = 0
        WidgetAuthProtocol.handler = { _ in
            requests += 1
            return (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let auth = SpotifyAuthorization(store: store, session: mockSession(), lockDirectory: directory)
        let connection = SpotifyConnection(sessionStorage: store, authorization: auth)
        await connection.refresh()
        #expect(connection.requiresReauthorization)
        #expect(connection.connected)
        #expect(try store.read()?.refreshToken == original.refreshToken)
        #expect(try store.read()?.needsAuthorization == true)
        await connection.refresh()
        await #expect(throws: AuthorizationError.self) { try await auth.validSession() }
        #expect(requests == 1)
        #expect(SpotifyConnection(sessionStorage: store).requiresReauthorization)
    }

    @Test func legacySavedSessionRemainsDecodable() throws {
        let original = credential(expired: false)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "needsAuthorization")
        let decoded = try JSONDecoder().decode(SpotifySession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)
        #expect(decoded.needsAuthorization != true)
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
        #expect(connection.status.contains("不允許此播放操作"))
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

@MainActor
private final class ReturningPlaybackAuthorizer: SpotifyPlaybackAuthorizing {
    var calls = 0
    var callbackResult: Bool?
    var trackURI: String?
    func authorize(clientID: String, redirectURL: URL, trackURI: String, completion: @escaping @Sendable (Bool) -> Void) {
        calls += 1
        self.trackURI = trackURI
        completion(true)
    }
    func result(from url: URL) -> Bool? { callbackResult }
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

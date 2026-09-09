import Foundation
import Testing
@testable import SpotifyTrans

@Suite(.serialized)
struct SpotifyTransTests {
    static let synced = Data(#"{"error":false,"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"こんにちは"},{"startTimeMs":"3000","words":"ありがとう"}]}"#.utf8)
    static let trackID = "5f8eCNwTlr0RJopE9vQ6mB"

    @Test func spotifyArtworkDecodesAndAllowsMissingCover() throws {
        let data = Data(#"{"id":"track","duration_ms":10000,"name":"Song","artists":[{"name":"Artist"}],"external_urls":{},"album":{"images":[{"url":"https://i.scdn.co/image/example"}]}}"#.utf8)
        let track = try JSONDecoder().decode(SpotifyConnection.Track.self, from: data)
        #expect(track.artworkURL?.absoluteString == "https://i.scdn.co/image/example")
        let withoutCover = Data(#"{"id":"track","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}"#.utf8)
        #expect(try JSONDecoder().decode(SpotifyConnection.Track.self, from: withoutCover).artworkURL == nil)
    }

    @Test func lyricBoundariesAndBackwardSeek() throws {
        let document = try LyricsDocument.decode(Self.synced)
        #expect(document.isSynced)
        #expect(document.activeLine(at: 999) == nil)
        #expect(document.activeLine(at: 1000) == 0)
        #expect(document.activeLine(at: 3000) == 1)
        #expect(document.activeLine(at: 1200) == 0)
    }

    @Test func unsyncedAndInvalidTimesDoNotHighlight() throws {
        for body in [
            #"{"error":false,"syncType":"UNSYNCED","lines":[{"words":"hello"}]}"#,
            #"{"error":false,"syncType":"LINE_SYNCED","lines":[{"words":"hello","startTimeMs":"bad"}]}"#,
            #"{"error":false,"syncType":"LINE_SYNCED","lines":[{"words":"a","startTimeMs":"10"},{"words":"b","startTimeMs":"1"}]}"#
        ] {
            let document = try LyricsDocument.decode(Data(body.utf8))
            #expect(!document.isSynced)
            #expect(document.activeLine(at: 10000) == nil)
        }
    }

    @Test func emptyOrErrorResponseRejected() {
        for body in [#"{"error":true}"#, #"{"error":false,"lines":[]}"#] {
            #expect(throws: LyricsError.self) { try LyricsDocument.decode(Data(body.utf8)) }
        }
    }

    @Test func originalLanguagesAndJapaneseReading() {
        let engine = LyricsRomanizer()
        let lines = engine.convert("Hello world\n一起唱歌\n", language: .automatic)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.romanization == nil })
        #expect(engine.convert("明日も一緒に歌おう", language: .japanese)[0].romanization == "asu mo issho ni utaou")
        #expect(engine.convert("Hello world", language: .japanese)[0].romanization == nil)
    }

    @MainActor @Test func repeatSongFetchesAndConvertsAgain() async throws {
        let counter = WorkCounter()
        let store = PhoneLyricsStore(fetch: { _ in
            await counter.fetch()
            return try LyricsDocument.decode(Self.synced)
        }, convert: { _, _ in
            await counter.convert()
            return [0: "konnichiwa"]
        })
        await store.load(trackID: Self.trackID, language: .automatic)
        await store.load(trackID: nil, language: .automatic)
        await store.load(trackID: Self.trackID, language: .automatic)
        #expect(await counter.fetches == 2)
        #expect(await counter.conversions == 2)
        #expect(store.readings[0] == "konnichiwa")
        await store.load(trackID: Self.trackID, language: .japanese)
        #expect(await counter.fetches == 3)
        #expect(await counter.conversions == 3)
    }

    @MainActor @Test func olderSongResponseCannotOverwriteNewSong() async throws {
        let store = PhoneLyricsStore(fetch: { id in
            if id == "old" { try await Task.sleep(for: .milliseconds(150)) }
            return LyricsDocument(lines: [.init(id: 0, words: id, startTimeMS: nil)], isSynced: false)
        })
        let old = Task { await store.load(trackID: "old", language: .automatic) }
        try await Task.sleep(for: .milliseconds(30))
        await store.load(trackID: "new", language: .automatic)
        await old.value
        #expect(store.document?.lines.first?.words == "new")
        #expect(!store.loading)
    }

    @Test func oneTimeCodeMatchesStandardVector() {
        #expect(DirectLyricsClient.oneTimeCode(key: Data("12345678901234567890".utf8), seconds: 59) == "287082")
    }

    @MainActor @Test func playbackControlRequests() {
        let play = SpotifyConnection.PlaybackCommand.play.request(token: "test-token")
        #expect(play.httpMethod == "PUT")
        #expect(play.url?.absoluteString == "https://api.spotify.com/v1/me/player/play")
        #expect(play.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(SpotifyConnection.PlaybackCommand.pause.request(token: "").httpMethod == "PUT")
        #expect(SpotifyConnection.PlaybackCommand.next.request(token: "").httpMethod == "POST")
        #expect(SpotifyConnection.PlaybackCommand.previous.request(token: "").url?.path == "/v1/me/player/previous")
    }

    @Test func directLyricsFlowKeepsCookieOffOtherHosts() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMockProtocol.self]
        LyricsMockProtocol.handler = { request in
            let host = request.url!.host!
            let path = request.url!.path
            if path == "/api/token" {
                #expect(host == "open.spotify.com")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "sp_dc=test-cookie")
                return (200, Data("{\"accessToken\":\"web-token\",\"accessTokenExpirationTimestampMs\":\(Date().addingTimeInterval(600).timeIntervalSince1970 * 1000),\"isAnonymous\":false}".utf8))
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            if host == "raw.githubusercontent.com" { return (200, Data(#"{"1":[1,2,3]}"#.utf8)) }
            if path == "/api/server-time" { return (200, Data(#"{"serverTime":1700000000}"#.utf8)) }
            #expect(host == "spclient.wg.spotify.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer web-token")
            return (200, Data(#"{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"hello"}]}}"#.utf8))
        }
        let client = DirectLyricsClient(session: URLSession(configuration: config), cookie: { "test-cookie" })
        let document = try await client.fetch(trackID: Self.trackID)
        #expect(document.isSynced)
        #expect(document.lines.first?.words == "hello")
    }

    @Test func directSourceHTTPFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMockProtocol.self]
        for (status, fragment) in [(401, "授權被拒絕"), (404, "找不到"), (429, "限制請求")] {
            LyricsMockProtocol.handler = { _ in (status, Data()) }
            let client = DirectLyricsClient(session: URLSession(configuration: config), cookie: { "test-cookie" })
            do {
                _ = try await client.fetch(trackID: Self.trackID)
                Issue.record("Expected HTTP failure")
            } catch { #expect(error.localizedDescription.contains(fragment)) }
        }
    }

    @MainActor @Test func measureWholeSongConversion() async throws {
        let lines = (0..<180).map { LyricsDocument.Line(id: $0, words: ["明日も一緒に歌おう", "안녕하세요", "Hello world", "一起唱歌"][$0 % 4], startTimeMS: nil) }
        let store = PhoneLyricsStore(fetch: { _ in LyricsDocument(lines: lines, isSynced: false) })
        await store.load(trackID: Self.trackID, language: .automatic)
        #expect(store.document?.lines.count == 180)
        print("180-line simulator conversion: \(store.conversionMilliseconds ?? -1) ms")
    }
}

private actor WorkCounter {
    var fetches = 0
    var conversions = 0
    func fetch() { fetches += 1 }
    func convert() { conversions += 1 }
}

private final class LyricsMockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

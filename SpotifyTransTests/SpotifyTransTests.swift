import Combine
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

    @Test func smallTsuJoinsConsonantsAcrossTokenizerBoundaries() {
        let engine = LyricsRomanizer()
        for (source, expected) in [
            ("しまった", "shimatta"), ("まって", "matte"), ("きっぷ", "kippu"),
            ("がっこう", "gakkou"), ("マッチ", "matchi"), ("つき", "tsuki"),
            ("ｼﾏｯﾀ", "shimatta"), ("あっ", "a’"), ("っ", "’"),
            ("まっ、て", "ma’、te"), ("Hello しまった WORLD", "Hello shimatta WORLD"),
            ("~tsu しまった", "~tsu shimatta"), ("エキを", "eki o")
        ] {
            #expect(engine.convert(source, language: .japanese)[0].romanization == expected)
        }
        let source = "使いすぎってしまったエキを"
        let result = engine.convert(source, language: .japanese)[0]
        #expect(result.original == source)
        #expect(result.romanization == "tsukai sugi tte shimatta eki o")
    }

    @Test func unresolvedSmallTsuUsesFollowingConsonantWithoutRemovingFullTsu() {
        for (source, expected) in [
            ("shima~tsu ta", "shimatta"), ("ma ~tsu te", "matte"),
            ("ma~tsu chi", "matchi"), ("a~tsu shuku", "asshuku"),
            ("yo~tsu tsu", "yottsu"), ("tsu", "tsu"), ("a~tsu", "a’")
        ] {
            #expect(LyricsRomanizer.normalizeSokuon(source) == expected)
        }
    }

    @MainActor @Test func smallTsuCorrectionReachesPhoneLyricsWithoutChangingSource() async {
        let store = PhoneLyricsStore(fetch: { _ in
            LyricsDocument(lines: [.init(id: 42, words: "しまったエキを", startTimeMS: 1000)], isSynced: true)
        })
        await store.load(trackID: Self.trackID, language: .japanese)
        #expect(store.readings[42] == "shimatta eki o")
        #expect(store.document?.lines.first?.words == "しまったエキを")
    }

    @Test func mixedLanguageLinesKeepEnglishAndConvertJapanese() {
        let cases = [
            ("I just want to stay with you forever ありがとう", "I just want to stay with you forever arigatou"),
            ("Don't stop, 明日も一緒に歌おう!", "Don't stop, asu mo issho ni utaou!"),
            ("helloカタカナworld", "hello katakana world"),
            ("君と Dream 一緒に", "kimi to Dream issho ni"),
            ("Hello 안녕하세요 WORLD", "Hello annyeonghaseyo WORLD"),
            ("ありがとう 一起唱歌", "arigatou 一起唱歌"),
            ("Hello ｶﾀｶﾅ WORLD", "Hello katakana WORLD"),
            ("Hello か\u{3099} WORLD", "Hello ga WORLD"),
            ("🎵 Don't  ありがとう, WORLD!", "🎵 Don't  arigatou, WORLD!")
        ]
        let engine = LyricsRomanizer()
        for (original, expected) in cases {
            #expect(engine.convert(original, language: .automatic)[0].romanization == expected)
        }
        #expect(engine.convert("Don't stop, 明日も一緒に歌おう!", language: .japanese)[0].romanization == "Don't stop, asu mo issho ni utaou!")
        #expect(engine.convert("一起唱歌 Hello", language: .automatic)[0].romanization == nil)
    }

    @Test func japaneseSongContextReadsKanjiOnlyWordsWithoutChangingChineseSentences() {
        let engine = LyricsRomanizer()
        let lines = engine.convert(["君と歌う", "世界", "未来", "夢", "Hello 世界", "一起唱歌", "我愛你", ""], language: .automatic)
        #expect(lines.map(\.romanization) == ["kimi to utau", "sekai", "mirai", "yume", "Hello sekai", nil, nil, nil])
        #expect(engine.convert("世界、君と", language: .automatic)[0].romanization == "sekai、kimi to")
        // Shared kanji alone are not sufficient evidence to romanize Chinese lyrics.
        #expect(engine.convert("Hello\n世界\n未来\n我愛你", language: .automatic).allSatisfy { $0.romanization == nil })
    }

    @Test func manualJapaneseReadsAmbiguousKanjiAndKeepsUnknownCharacters() {
        let engine = LyricsRomanizer()
        let lines = engine.convert("世界\n未来\n夢\nHello 希望\nHello 𠮷 WORLD", language: .japanese)
        #expect(lines.map(\.romanization) == ["sekai", "mirai", "yume", "Hello kibou", nil])
        #expect(lines.last?.original == "Hello 𠮷 WORLD")
        // The tokenizer reports an empty transcription for this unfamiliar character.
        #expect(engine.convert("我愛你", language: .japanese)[0].romanization?.contains("你") == true)
    }

    @MainActor @Test func songContextReachesKanjiLyricsWithOriginalLineIDs() async {
        let store = PhoneLyricsStore(fetch: { _ in
            LyricsDocument(lines: [
                .init(id: 12, words: "君と歌う", startTimeMS: 1000),
                .init(id: 24, words: "世界", startTimeMS: 2000),
                .init(id: 36, words: "Hello 未来", startTimeMS: 3000),
                .init(id: 48, words: "一起唱歌", startTimeMS: 4000),
                .init(id: 60, words: "", startTimeMS: 5000)
            ], isSynced: true)
        })
        await store.load(trackID: Self.trackID, language: .automatic)
        #expect(store.readings[24] == "sekai")
        #expect(store.readings[36] == "Hello mirai")
        #expect(store.readings[48] == nil)
        #expect(store.readings[60] == nil)
        #expect(store.document?.lines.map(\.id) == [12, 24, 36, 48, 60])
        #expect(store.document?.activeLine(at: 2000) == 24)
    }

    @MainActor @Test func mixedSongReachesDisplayedReadingsWithoutTranslatingEnglishLines() async {
        let store = PhoneLyricsStore(fetch: { _ in
            LyricsDocument(lines: [
                .init(id: 12, words: "I just want to stay with you forever ありがとう", startTimeMS: 1000),
                .init(id: 24, words: "English ONLY", startTimeMS: 2000),
                .init(id: 36, words: "一起唱歌 Hello", startTimeMS: 3000)
            ], isSynced: true)
        })
        await store.load(trackID: Self.trackID, language: .automatic)
        #expect(store.readings[12] == "I just want to stay with you forever arigatou")
        #expect(store.readings[24] == nil)
        #expect(store.readings[36] == nil)
        #expect(store.document?.lines.map(\.id) == [12, 24, 36])
        #expect(store.document?.activeLine(at: 1000) == 12)
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

    @MainActor @Test func sameSongUpdatesDoNotReloadUnlessRequested() async throws {
        let counter = WorkCounter()
        let store = PhoneLyricsStore(fetch: { _ in
            await counter.fetch()
            return try LyricsDocument.decode(Self.synced)
        })
        await store.load(trackID: Self.trackID, language: .automatic)
        for _ in 0..<5 { await store.load(trackID: Self.trackID, language: .automatic) }
        #expect(await counter.fetches == 1)
        await store.load(trackID: Self.trackID, language: .automatic, revision: 1)
        #expect(await counter.fetches == 2)
        await store.load(trackID: Self.trackID, language: .automatic, revision: 1, loginRevision: 1)
        #expect(await counter.fetches == 3)
    }

    @MainActor @Test func sameSongRefreshKeepsLyricsDuringLoadingAndFailure() async throws {
        let counter = WorkCounter()
        let store = PhoneLyricsStore(fetch: { _ in
            await counter.fetch()
            if await counter.fetches > 2 { throw URLError(.timedOut) }
            return try LyricsDocument.decode(Self.synced)
        })
        await store.load(trackID: Self.trackID, language: .automatic)
        var clearedDocument = false
        let observation = store.$document.dropFirst().sink { if $0 == nil { clearedDocument = true } }
        await store.load(trackID: Self.trackID, language: .automatic, revision: 1)
        await store.load(trackID: Self.trackID, language: .automatic, revision: 2)
        #expect(!clearedDocument)
        #expect(store.document?.lines.first?.words == "こんにちは")
        #expect(store.readings[0] != nil)
        #expect(!store.loading)
        #expect(store.message.contains("暫時無法"))
        await store.load(trackID: "different-song", language: .automatic)
        #expect(clearedDocument)
        #expect(store.document == nil)
        #expect(store.readings.isEmpty)
        observation.cancel()
    }

    private static var playbackData: Data {
        Data(#"{"currently_playing_type":"track","is_playing":true,"progress_ms":1000,"item":{"id":"song-a","duration_ms":10000,"name":"Song","artists":[],"external_urls":{}}}"#.utf8)
    }
    private static func playbackResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @MainActor @Test func pollingFailuresPreserveSongAndResumeOnRecovery() throws {
        let spotify = SpotifyConnection(restoreSession: false)
        try spotify.applyPlaybackResponse(data: Self.playbackData, response: Self.playbackResponse(200))
        let lastSuccessfulSync = spotify.lastPlaybackSync
        for status in [500, 429, 401, 200] {
            do {
                try spotify.applyPlaybackResponse(data: Data("invalid".utf8), response: Self.playbackResponse(status))
                Issue.record("Expected a failed playback response")
            } catch { spotify.preservePlaybackAfterRefreshFailure(error) }
            #expect(spotify.track?.id == "song-a")
            #expect(spotify.lastPlaybackSync == lastSuccessfulSync)
            #expect(spotify.isPlaying)
            #expect(!spotify.canPredictPlayback)
            #expect(spotify.playbackPosition(at: Date()) == spotify.playbackPosition(at: Date().addingTimeInterval(10)))
        }
        spotify.preservePlaybackAfterRefreshFailure(URLError(.notConnectedToInternet))
        #expect(spotify.track?.id == "song-a")
        try spotify.applyPlaybackResponse(data: Self.playbackData, response: Self.playbackResponse(200))
        #expect(spotify.track?.id == "song-a")
        #expect(spotify.playbackPosition(at: Date().addingTimeInterval(1))! > 1900)
        #expect(spotify.status == "播放中")
    }

    @MainActor @Test func confirmedNoPlaybackStillClearsSong() throws {
        let spotify = SpotifyConnection(restoreSession: false)
        for status in [204] {
            try spotify.applyPlaybackResponse(data: Self.playbackData, response: Self.playbackResponse(200))
            try spotify.applyPlaybackResponse(data: Data(), response: Self.playbackResponse(status))
            #expect(spotify.track == nil)
            #expect(spotify.progressMS == nil)
        }
        try spotify.applyPlaybackResponse(data: Self.playbackData, response: Self.playbackResponse(200))
        try spotify.applyPlaybackResponse(data: Data(#"{"currently_playing_type":"episode"}"#.utf8), response: Self.playbackResponse(200))
        #expect(spotify.track == nil)
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

    @Test func expiredLyricsAccessTokenRefreshesUsingSavedCookie() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMockProtocol.self]
        var tokenRequests = 0
        var lyricRequests = 0
        LyricsMockProtocol.handler = { request in
            if request.url?.host == "raw.githubusercontent.com" { return (200, Data(#"{"1":[1,2,3]}"#.utf8)) }
            if request.url?.path == "/api/server-time" { return (200, Data(#"{"serverTime":1700000000}"#.utf8)) }
            if request.url?.path == "/api/token" {
                tokenRequests += 1
                #expect(request.value(forHTTPHeaderField: "Cookie") == "sp_dc=saved-cookie")
                return (200, try! JSONSerialization.data(withJSONObject: [
                    "accessToken": "token-\(tokenRequests)",
                    "accessTokenExpirationTimestampMs": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000,
                    "isAnonymous": false
                ]))
            }
            lyricRequests += 1
            if lyricRequests == 1 { return (401, Data()) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
            return (200, Data(#"{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"1000","words":"hello"}]}}"#.utf8))
        }
        let client = DirectLyricsClient(session: URLSession(configuration: config), cookie: { "saved-cookie" })
        #expect(try await client.fetch(trackID: Self.trackID).lines.first?.words == "hello")
        #expect(tokenRequests == 2)
        #expect(lyricRequests == 2)
    }

    @Test @MainActor func onlyConfirmedLyricsAuthenticationFailureRequestsLogin() async {
        let store = PhoneLyricsStore(fetch: { id in
            if id == "expired" { throw LyricsError.authenticationRequired }
            throw URLError(.notConnectedToInternet)
        })
        await store.load(trackID: "offline", language: .automatic)
        #expect(!store.needsLogin)
        await store.load(trackID: "expired", language: .automatic)
        #expect(store.needsLogin)
        store.loginDidChange()
        #expect(!store.needsLogin)
        #expect(store.document == nil)
    }

    @Test func directSourceHTTPFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsMockProtocol.self]
        for (status, fragment) in [(404, "尚無歌詞"), (429, "過於頻繁")] {
            LyricsMockProtocol.handler = { _ in (status, Data()) }
            let client = DirectLyricsClient(session: URLSession(configuration: config), cookie: { "test-cookie" })
            do {
                _ = try await client.fetch(trackID: Self.trackID)
                Issue.record("Expected HTTP failure")
            } catch { #expect(error.localizedDescription.contains(fragment)) }
        }
    }

    @MainActor @Test func convertsWholeSongWithoutDroppingLines() async throws {
        let lines = (0..<180).map { LyricsDocument.Line(id: $0, words: ["明日も一緒に歌おう", "안녕하세요", "Hello world", "一起唱歌"][$0 % 4], startTimeMS: nil) }
        let store = PhoneLyricsStore(fetch: { _ in LyricsDocument(lines: lines, isSynced: false) })
        await store.load(trackID: Self.trackID, language: .automatic)
        #expect(store.document?.lines.count == 180)
        #expect(store.readings.count == 90)
        #expect(store.document?.lines.map(\.id) == Array(0..<180))
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

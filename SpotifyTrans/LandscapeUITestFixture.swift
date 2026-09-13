#if DEBUG
import Foundation

// Opt-in, local-only UI test data. All playback requests are intercepted and the
// ContentView fixture disables publishing to the user's widget.
enum LandscapeUITestFixture {
    static let document = LyricsDocument(lines: [
        .init(id: 0, words: "君と歌う", startTimeMS: 0),
        .init(id: 1, words: "明日も一緒に", startTimeMS: 10000),
        .init(id: 2, words: "新しい世界へ", startTimeMS: 20000),
        .init(id: 3, words: "一歩ずつ歩こう", startTimeMS: 30000),
        .init(id: 4, words: "Hello ありがとう", startTimeMS: 40000)
    ], isSynced: true)

    static func translation(_ text: String) -> String {
        ["君と歌う": "與你歌唱", "明日も一緒に": "明天也要在一起", "新しい世界へ": "走向嶄新的世界",
         "一歩ずつ歩こう": "一步一步向前走", "Hello": "你好", "ありがとう": "謝謝你"][text] ?? text
    }

    @MainActor static func connection() -> SpotifyConnection {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LandscapePlaybackProtocol.self]
        let session = URLSession(configuration: config)
        let storage = FixtureSessionStorage()
        return SpotifyConnection(sessionStorage: storage,
                                 authorization: SpotifyAuthorization(store: storage, session: session),
                                 playbackSession: session)
    }
}

private struct FixtureSessionStorage: SpotifySessionStorage {
    private let value = SpotifySession(id: UUID(), clientID: "ui-fixture", accessToken: "local-only",
                                      refreshToken: "local-only", expiresAt: .distantFuture)
    func read() -> SpotifySession? { value }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws {
        var copy: SpotifySession? = value
        try mutation(&copy)
    }
}

private final class LandscapePlaybackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isPlayback = request.url?.path == "/v1/me/player/currently-playing"
        let body = Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":22000,"item":{"id":"landscape-fixture-song","duration_ms":180000,"name":"Landscape Session","artists":[{"name":"Lyriva Studio"}],"external_urls":{}}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: isPlayback ? 200 : 204,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isPlayback { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

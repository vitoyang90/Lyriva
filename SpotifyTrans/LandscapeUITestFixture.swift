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

    static func document(for trackID: String) -> LyricsDocument {
        let followsPlayback = ProcessInfo.processInfo.arguments.contains("--autofollow-ui-fixture")
        if followsPlayback || ProcessInfo.processInfo.arguments.contains("--long-lyrics-ui-fixture") {
            return LyricsDocument(lines: (0..<80).map {
                .init(id: $0, words: "閱讀第 \($0 + 1) 行歌詞", startTimeMS: Double($0 * (followsPlayback ? 3000 : 10000)))
            }, isSynced: true)
        }
        guard trackID == "queue-two" else { return document }
        return LyricsDocument(lines: [.init(id: 0, words: "次の歌も一緒に", startTimeMS: 0)], isSynced: true)
    }

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
        refreshToken: "local-only", expiresAt: .distantFuture,
        scopes: ProcessInfo.processInfo.arguments.contains("--favorite-playback-ui-fixture")
            ? ["user-read-playback-state", "user-modify-playback-state"] : nil)
    func read() -> SpotifySession? { value }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws {
        var copy: SpotifySession? = value
        try mutation(&copy)
    }
}

private final class LandscapePlaybackProtocol: URLProtocol, @unchecked Sendable {
    private static let favoritePlayback = FavoriteFixturePlayback()
    private static let spotifyQueue = SpotifyQueueFixturePlayback()
    private static let automaticPlaybackStartedAt = Date()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isPlayback = request.httpMethod == "GET" &&
            ["/v1/me/player/currently-playing", "/v1/me/player"].contains(request.url?.path ?? "")
        let isDevices = request.url?.path == "/v1/me/player/devices"
        let body: Data
        if isDevices {
            body = Data(#"{"devices":[{"id":"fixture-phone","name":"iPhone","is_active":false,"is_restricted":false},{"id":"fixture-computer","name":"Mac","is_active":true,"is_restricted":false}]}"#.utf8)
        } else if ProcessInfo.processInfo.arguments.contains("--autofollow-ui-fixture") {
            let position = 30000 + Int(Date().timeIntervalSince(Self.automaticPlaybackStartedAt) * 1000)
            body = Data("""
                {"currently_playing_type":"track","is_playing":true,"progress_ms":\(position),
                 "item":{"id":"landscape-fixture-song","duration_ms":240000,"name":"Automatic Follow Session",
                 "artists":[{"name":"Lyriva Studio"}],"external_urls":{}}}
                """.utf8)
        } else if ProcessInfo.processInfo.arguments.contains("--spotify-queue-ui-fixture") {
            body = Self.spotifyQueue.response(to: request)
        } else if ProcessInfo.processInfo.arguments.contains("--favorite-playback-ui-fixture") {
            body = Self.favoritePlayback.response(to: request)
        } else {
            body = Data(#"{"currently_playing_type":"track","is_playing":false,"progress_ms":22000,"item":{"id":"landscape-fixture-song","duration_ms":180000,"name":"Landscape Session","artists":[{"name":"Lyriva Studio"}],"external_urls":{}}}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: isPlayback || isDevices ? 200 : 204,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isPlayback || isDevices { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SpotifyQueueFixturePlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private var playing = false
    private var queueReplaced = false

    func response(to request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        switch (request.httpMethod, request.url?.lastPathComponent) {
        case ("POST", "next"): index = 1
        case ("POST", "previous"): index = 0
        case ("PUT", "pause"): playing = false
        case ("PUT", "play"):
            // A body would replace the queue. Plain resume preserves it.
            queueReplaced = request.httpBody != nil || request.httpBodyStream != nil
            playing = true
        case ("GET", "currently-playing"): break
        default: queueReplaced = true
        }
        let id = index == 0 ? "queue-one" : "queue-two"
        let title = queueReplaced ? "Unexpected Queue Replacement" : "Spotify Queue \(index + 1)"
        return Data("""
            {"currently_playing_type":"track","is_playing":\(playing),"progress_ms":22000,
             "item":{"id":"\(id)","duration_ms":180000,"name":"\(title)","artists":[{"name":"Lyriva Studio"}],"external_urls":{}}}
            """.utf8)
    }
}

// This scenario changes its playback response only after receiving a real
// selected-track request, so the UI test cannot pass just by changing modes.
private final class FavoriteFixturePlayback: @unchecked Sendable {
    private let lock = NSLock()
    private var selected = false

    func response(to request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if request.httpMethod == "PUT", request.url?.path == "/v1/me/player/play" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            selected = json?["uris"] as? [String] == ["spotify:track:favorite-fixture-song"]
                && json?["position_ms"] as? Int == 0
                && URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "device_id" })?.value == "fixture-computer"
        }
        let id = selected ? "favorite-fixture-song" : "landscape-fixture-song"
        let title = selected ? "Favorite Session" : "Landscape Session"
        return Data("""
            {"currently_playing_type":"track","is_playing":\(selected),"progress_ms":\(selected ? 0 : 22000),
             "device":{"id":"fixture-computer","name":"Mac","is_active":true,"is_restricted":false},
             "item":{"id":"\(id)","duration_ms":180000,"name":"\(title)","artists":[{"name":"Lyriva Studio"}],"external_urls":{}}}
            """.utf8)
    }
}
#endif

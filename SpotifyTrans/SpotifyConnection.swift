import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
final class SpotifyConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var showingActivity = false
    @Published private(set) var track: Track?
    @Published private(set) var status = "連接 Spotify，查看目前播放的歌曲。"
    @Published private(set) var progressMS: Double?
    @Published private(set) var isPlaying = false
    private(set) var lastPlaybackSync: Date?
    private var sampledAt = Date()
    private var playbackStale = false
    var canPredictPlayback: Bool { isPlaying && !playbackStale }

    func playbackPosition(at date: Date) -> Double? {
        guard let progressMS else { return nil }
        return min(Double(track?.duration_ms ?? Int.max), max(0, progressMS + (isPlaying && !playbackStale ? max(0, date.timeIntervalSince(sampledAt)) * 1000 : 0)))
    }

    let playbackStarter = SpotifyPlaybackStarter()
    private var session: ASWebAuthenticationSession?
    private var clientID = ""
    private var retryAfter = Date.distantPast
    static let redirectURI = "spotifytrans://callback"

    typealias Track = SpotifyTrack
    private struct Playback: Decodable {
        let item: Track?
        let progress_ms: Double?
        let is_playing: Bool
        let currently_playing_type: String
    }
    private struct ConnectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let restoreSession: Bool
    private let sessionStorage: any SpotifySessionStorage
    private let authorization: SpotifyAuthorization
    private let playbackSession: URLSession
    init(restoreSession: Bool = true, sessionStorage: any SpotifySessionStorage = KeychainSessionStorage(),
         authorization: SpotifyAuthorization = .shared, playbackSession: URLSession = .shared) {
        self.restoreSession = restoreSession
        self.sessionStorage = sessionStorage
        self.authorization = authorization
        self.playbackSession = playbackSession
        super.init()
        restoreSavedSession()
        if restoreSession { _ = try? LyricsCredential.read() }
    }

    func restoreSavedSession() {
        guard restoreSession, !connected, !busy else { return }
        do {
            guard let saved = try sessionStorage.read() else { return }
            clientID = saved.clientID
            connected = true
            status = "已恢復 Spotify 登入，正在同步…"
        } catch {
            // A temporarily unavailable Keychain must not be mistaken for logout.
            // Retry when the app becomes active again, without deleting the session.
            status = "暫時無法讀取已保存的 Spotify 登入，回到 App 時會自動重試。"
        }
    }

    func connect(clientID input: String) {
        guard !busy else { return }
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { status = "請先輸入 Spotify Developer App 的 Client ID。"; return }
        clientID = id
        busy = true
        showingActivity = true
        status = "等待 Spotify 登入授權…"
        let verifier = UUID().uuidString + UUID().uuidString
        let state = UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = ["client_id": id, "response_type": "code", "redirect_uri": Self.redirectURI,
                          "scope": "user-read-currently-playing user-modify-playback-state", "state": state,
                          "code_challenge_method": "S256", "code_challenge": challenge]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "spotifytrans") { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false; self.showingActivity = false; self.session = nil }
                guard error == nil, let callback else {
                    self.status = "登入已取消或無法完成，請重試。"
                    return
                }
                let parameters = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard callback.scheme == "spotifytrans", callback.host == "callback",
                      parameters.first(where: { $0.name == "state" })?.value == state,
                      let code = parameters.first(where: { $0.name == "code" })?.value else {
                    self.status = "未取得有效授權，請重新連接 Spotify。"
                    return
                }
                do {
                    try await self.authorization.exchange(code: code, verifier: verifier, clientID: id, redirectURI: Self.redirectURI)
                    self.connected = true
                    self.status = "已連接 Spotify，可在主畫面按播放開始。"
                } catch { self.status = error.localizedDescription }
            }
        }
        session?.presentationContextProvider = self
        if session?.start() != true {
            busy = false
            showingActivity = false
            session = nil
            status = "無法開啟登入畫面，請重試。"
        }
    }

    func refresh(showActivity: Bool = true) async {
        guard connected, !busy, !playbackStarter.isStarting else { return }
        guard Date() >= retryAfter else { return }
        busy = true
        showingActivity = showActivity
        defer { busy = false; showingActivity = false }
        do {
            let authorization = try await self.authorization.validSession()
            let accessToken = authorization.accessToken
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await playbackSession.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConnectionError(message: "無法讀取 Spotify 回應。") }
            if response.statusCode == 401 {
                try await self.authorization.invalidate(authorization)
                throw AuthorizationError.signedOut
            }
            try applyPlaybackResponse(data: data, response: response)
        } catch {
            if Task.isCancelled { return }
            preservePlaybackAfterRefreshFailure(error)
        }
    }

    func applyPlaybackResponse(data: Data, response: HTTPURLResponse) throws {
        if response.statusCode == 204 {
            progressMS = nil
            isPlaying = false
            track = nil
            status = "目前沒有可讀取的歌曲，按播放即可啟動 Spotify。"
            return
        }
        if response.statusCode == 401 {
            disconnect()
            status = "Spotify 授權已失效，請重新連接。"
            return
        }
        if response.statusCode == 429 {
            retryAfter = Date().addingTimeInterval(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30)
            throw ConnectionError(message: "Spotify 暫時限制請求頻率，請稍後再更新。")
        }
        guard response.statusCode == 200 else {
            throw ConnectionError(message: "Spotify 回應 \(response.statusCode)，請確認開發者設定與帳號存取資格。")
        }
        // Episodes do not have the same schema as music tracks.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["currently_playing_type"] as? String == "track" else {
            progressMS = nil
            isPlaying = false
            track = nil
            status = "目前播放的內容不是歌曲。"
            return
        }
        let playback = try JSONDecoder().decode(Playback.self, from: data)
        progressMS = playback.progress_ms
        isPlaying = playback.is_playing
        sampledAt = Date()
        lastPlaybackSync = sampledAt
        playbackStale = false
        track = playback.item
        status = track == nil ? "目前沒有可讀取的歌曲。" : (playback.is_playing ? "正在 Spotify 播放" : "Spotify 已暫停")
    }

    func preservePlaybackAfterRefreshFailure(_ error: Error) {
        // A failed poll does not mean playback has ended. Keep the current song and lyrics,
        // but freeze the estimated position until a successful response resynchronizes it.
        progressMS = playbackPosition(at: Date())
        sampledAt = Date()
        playbackStale = true
        status = "同步暫時中斷，稍後會重試。\(error.localizedDescription)"
    }

    enum PlaybackCommand: Equatable {
        case play, pause, previous, next
        case seek(positionMS: Int)
        var path: String {
            switch self {
            case .play: return "play"
            case .pause: return "pause"
            case .previous: return "previous"
            case .next: return "next"
            case .seek: return "seek"
            }
        }
        var method: String {
            switch self {
            case .play, .pause, .seek: return "PUT"
            case .previous, .next: return "POST"
            }
        }
        func request(token: String) -> URLRequest {
            var url = URLComponents(string: "https://api.spotify.com/v1/me/player/\(path)")!
            if case .seek(let position) = self {
                url.queryItems = [URLQueryItem(name: "position_ms", value: String(max(0, position)))]
            }
            var request = URLRequest(url: url.url!, timeoutInterval: 15)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    func seek(to position: Double, trackID: String) async {
        guard position.isFinite else { return }
        // A drag can finish while a silent poll is in flight. Wait for it instead
        // of silently dropping the user's seek or racing its stale response.
        let deadline = Date().addingTimeInterval(15)
        while busy && Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled, connected, track?.id == trackID,
              let duration = track?.duration_ms, duration > 0 else { return }
        guard !busy else {
            status = "同步尚未完成，請稍後再拖曳時間軸。"
            return
        }
        // Seeking beyond the end starts the next song on Spotify.
        let target = Int(min(Double(duration - 1), max(0, position)))
        await control(.seek(positionMS: target))
    }

    func control(_ command: PlaybackCommand) async {
        guard connected, !busy, !playbackStarter.isStarting else { return }
        playbackStarter.reset()
        if command == .play, track == nil {
            playbackStarter.start(clientID: clientID)
            return
        }
        guard Date() >= retryAfter else {
            status = "Spotify 暫時限制請求，請稍後重試。"
            return
        }
        let commandTrackID = track?.id
        busy = true
        showingActivity = true
        defer { busy = false; showingActivity = false }
        do {
            let authorization = try await self.authorization.validSession()
            let accessToken = authorization.accessToken
            if case .seek = command {
                guard connected, track?.id == commandTrackID, !Task.isCancelled else { return }
            }
            let (_, rawResponse) = try await playbackSession.data(for: command.request(token: accessToken))
            let response = rawResponse as? HTTPURLResponse
            switch response?.statusCode {
            case 200, 204:
                if case .seek(let position) = command {
                    guard connected, track?.id == commandTrackID else { return }
                    progressMS = Double(position)
                    sampledAt = Date()
                    lastPlaybackSync = sampledAt
                    playbackStale = false
                    status = isPlaying ? "正在 Spotify 播放" : "Spotify 已暫停"
                    return
                }
                busy = false
                await refresh()
                return
            case 401:
                try await self.authorization.invalidate(authorization)
                status = "播放授權需要更新，請稍後重試。"
            case 403:
                status = "無法控制播放。請確認 Premium 資格，並重新連接 Spotify 授予播放控制權限。"
            case 404:
                if command == .play { playbackStarter.start(clientID: clientID) }
                else { status = "目前沒有播放裝置，請按播放以啟動手機 Spotify。" }
            case 429:
                let delay = Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30
                retryAfter = Date().addingTimeInterval(delay.isFinite ? max(1, delay) : 30)
                status = "Spotify 暫時限制請求，請稍後重試。"
            default: status = "Spotify 無法完成播放操作，請稍後重試。"
            }
        } catch { status = "播放操作失敗，請檢查網路並重試。" }
    }

    func disconnect() {
        if restoreSession {
            do { try sessionStorage.update { $0 = nil } }
            catch { status = error.localizedDescription; return }
        }
        playbackStarter.reset()
        lastPlaybackSync = nil
        retryAfter = .distantPast
        connected = false
        progressMS = nil
        isPlaying = false
        track = nil
        status = "已中斷連線。"
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

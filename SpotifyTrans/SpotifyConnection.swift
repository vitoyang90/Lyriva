import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
final class SpotifyConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var track: Track?
    @Published private(set) var status = "連接 Spotify，查看目前播放的歌曲。"
    @Published private(set) var progressMS: Double?
    @Published private(set) var isPlaying = false
    private var sampledAt = Date()

    func playbackPosition(at date: Date) -> Double? {
        guard let progressMS else { return nil }
        return min(Double(track?.duration_ms ?? Int.max), max(0, progressMS + (isPlaying ? max(0, date.timeIntervalSince(sampledAt)) * 1000 : 0)))
    }

    private var session: ASWebAuthenticationSession?
    // Tokens live only in memory for this prototype. No client secret is used.
    private var accessToken = ""
    private var refreshToken = ""
    private var clientID = ""
    private var expiresAt = Date.distantPast
    private var retryAfter = Date.distantPast
    static let redirectURI = "spotifytrans://callback"

    struct Track: Decodable {
        let id: String?
        let duration_ms: Int
        let name: String
        let artists: [Artist]
        let external_urls: Links
        let album: Album?
        struct Album: Decodable {
            let images: [Artwork]
            struct Artwork: Decodable { let url: URL }
        }
        var artworkURL: URL? { album?.images.first?.url }
        struct Artist: Decodable { let name: String }
        struct Links: Decodable { let spotify: URL? }
    }
    private struct Playback: Decodable {
        let item: Track?
        let progress_ms: Double?
        let is_playing: Bool
        let currently_playing_type: String
    }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    private struct ConnectionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func connect(clientID input: String) {
        guard !busy else { return }
        let id = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { status = "請先輸入 Spotify Developer App 的 Client ID。"; return }
        clientID = id
        busy = true
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
                defer { self.busy = false; self.session = nil }
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
                    try await self.requestTokens(["grant_type": "authorization_code", "code": code,
                                                  "redirect_uri": Self.redirectURI, "code_verifier": verifier])
                    self.connected = true
                    self.status = "已連接 Spotify，按下更新查看目前歌曲。"
                } catch { self.status = error.localizedDescription }
            }
        }
        session?.presentationContextProvider = self
        if session?.start() != true {
            busy = false
            session = nil
            status = "無法開啟登入畫面，請重試。"
        }
    }

    func refresh() async {
        guard connected, !busy else { return }
        guard Date() >= retryAfter else { return }
        busy = true
        defer { busy = false }
        do {
            if Date() >= expiresAt {
                try await requestTokens(["grant_type": "refresh_token", "refresh_token": refreshToken])
            }
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConnectionError(message: "無法讀取 Spotify 回應。") }
            if response.statusCode == 204 {
                progressMS = nil
                isPlaying = false
                track = nil
                status = "目前沒有可讀取的歌曲，請先在 Spotify 播放音樂。"
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
            track = playback.item
            status = track == nil ? "目前沒有可讀取的歌曲。" : (playback.is_playing ? "正在 Spotify 播放" : "Spotify 已暫停")
        } catch {
            if Task.isCancelled { return }
            progressMS = nil
            isPlaying = false
            track = nil
            status = error.localizedDescription
        }
    }

    enum PlaybackCommand {
        case play, pause, previous, next
        var path: String {
            switch self {
            case .play: return "play"
            case .pause: return "pause"
            case .previous: return "previous"
            case .next: return "next"
            }
        }
        var method: String {
            switch self {
            case .play, .pause: return "PUT"
            case .previous, .next: return "POST"
            }
        }
        func request(token: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(path)")!, timeoutInterval: 15)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    func control(_ command: PlaybackCommand) async {
        guard connected, !busy else { return }
        guard Date() >= retryAfter else {
            status = "Spotify 暫時限制請求，請稍後重試。"
            return
        }
        busy = true
        do {
            if Date() >= expiresAt {
                try await requestTokens(["grant_type": "refresh_token", "refresh_token": refreshToken])
            }
            let (_, rawResponse) = try await URLSession.shared.data(for: command.request(token: accessToken))
            let response = rawResponse as? HTTPURLResponse
            switch response?.statusCode {
            case 200, 204:
                busy = false
                await refresh()
                return
            case 401:
                disconnect()
                status = "播放授權已失效，請重新連接 Spotify。"
            case 403:
                status = "無法控制播放。請確認 Premium 資格，並重新連接 Spotify 授予播放控制權限。"
            case 404:
                status = "沒有可用的播放裝置，請先在手機 Spotify 播放一首歌。"
            case 429:
                let delay = Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30
                retryAfter = Date().addingTimeInterval(delay.isFinite ? max(1, delay) : 30)
                status = "Spotify 暫時限制請求，請稍後重試。"
            default: status = "Spotify 無法完成播放操作，請稍後重試。"
            }
        } catch { status = "播放操作失敗，請檢查網路並重試。" }
        busy = false
    }

    func disconnect() {
        accessToken = ""
        refreshToken = ""
        expiresAt = .distantPast
        retryAfter = .distantPast
        connected = false
        progressMS = nil
        isPlaying = false
        track = nil
        status = "已中斷連線。"
    }

    private func requestTokens(_ parameters: [String: String]) async throws {
        var fields = parameters
        fields["client_id"] = clientID
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            disconnect()
            throw ConnectionError(message: "Spotify 授權失敗，請確認 Client ID 與 Redirect URI，並重新登入。")
        }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        accessToken = tokens.access_token
        refreshToken = tokens.refresh_token ?? refreshToken
        expiresAt = Date().addingTimeInterval(tokens.expires_in - 60)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}


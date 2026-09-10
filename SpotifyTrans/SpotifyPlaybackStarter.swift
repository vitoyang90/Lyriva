import SpotifyiOS
import SwiftUI

@MainActor
protocol SpotifyPlaybackAuthorizing {
    func authorize(clientID: String, redirectURL: URL, completion: @escaping @Sendable (Bool) -> Void)
    /// Authorization succeeded, failed, or the URL is unrelated. This does not confirm playback.
    func result(from url: URL) -> Bool?
}

@MainActor
private final class SpotifySDKPlaybackAuthorizer: SpotifyPlaybackAuthorizing {
    private var remote: SPTAppRemote?

    func authorize(clientID: String, redirectURL: URL, completion: @escaping @Sendable (Bool) -> Void) {
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .none)
        self.remote = remote
        // The official SDK wakes Spotify and attempts to resume the user's last song.
        // Existing PKCE credentials remain responsible for Web API playback and polling.
        remote.authorizeAndPlayURI("", completionHandler: completion)
    }

    func result(from url: URL) -> Bool? {
        guard let parameters = remote?.authorizationParameters(from: url) else { return nil }
        if let token = parameters[SPTAppRemoteAccessTokenKey], !token.isEmpty { return true }
        if parameters[SPTAppRemoteErrorKey] != nil || parameters[SPTAppRemoteErrorDescriptionKey] != nil { return false }
        return nil
    }
}

@MainActor
final class SpotifyPlaybackStarter: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var message: String?
    private let authorizer: any SpotifyPlaybackAuthorizing
    private var attempt: UUID?
    private var leftApp = false
    private var timeout: Task<Void, Never>?

    init(authorizer: (any SpotifyPlaybackAuthorizing)? = nil) {
        self.authorizer = authorizer ?? SpotifySDKPlaybackAuthorizer()
    }

    func start(clientID: String) {
        guard !isStarting else { return }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "請先在設定中連接 Spotify。"
            return
        }
        let id = UUID()
        attempt = id
        leftApp = false
        isStarting = true
        message = "正在開啟 Spotify，接續上次播放…"
        authorizer.authorize(clientID: clientID, redirectURL: URL(string: SpotifyConnection.redirectURI)!) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.attempt == id else { return }
                // SDK completion only confirms that Spotify can handle the request.
                if !opened { self.finish(message: "無法開啟 Spotify，請確認手機已安裝並登入 Spotify。") }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.attempt == id else { return }
            self.finish(message: "尚未完成 Spotify 啟動，請再次按播放重試。")
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard isStarting, url.scheme == "spotifytrans", url.host == "callback",
              url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil,
              let authorized = authorizer.result(from: url) else { return false }
        finish(message: authorized ? nil : "Spotify 播放授權未完成，請再次按播放重試。")
        // Refresh real playback state instead of assuming that authorization started music.
        return authorized
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background, isStarting { leftApp = true }
        guard phase == .active, isStarting, leftApp else { return }
        let id = attempt
        Task { [weak self] in
            // Allow the URL callback to arrive after the foreground scene notification.
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.attempt == id else { return }
            self.returnedWithoutCallback()
        }
    }

    func returnedWithoutCallback() {
        guard isStarting else { return }
        finish(message: "未收到 Spotify 的播放確認，請再次按播放重試。")
    }

    func reset() { finish(message: nil) }

    private func finish(message: String?) {
        timeout?.cancel()
        timeout = nil
        attempt = nil
        leftApp = false
        isStarting = false
        self.message = message
    }
}

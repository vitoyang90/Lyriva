import SpotifyiOS
import SwiftUI

@MainActor
protocol SpotifyPlaybackAuthorizing {
    func authorize(clientID: String, redirectURL: URL, trackURI: String, completion: @escaping @Sendable (Bool) -> Void)
    /// Authorization succeeded, failed, or the URL is unrelated. This does not confirm playback.
    func result(from url: URL) -> Bool?
    func failureMessage(from url: URL) -> String?
}

extension SpotifyPlaybackAuthorizing {
    func failureMessage(from url: URL) -> String? { nil }
}

@MainActor
private final class SpotifySDKPlaybackAuthorizer: SpotifyPlaybackAuthorizing {
    private var remote: SPTAppRemote?

    func authorize(clientID: String, redirectURL: URL, trackURI: String, completion: @escaping @Sendable (Bool) -> Void) {
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirectURL)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .none)
        self.remote = remote
        // The official SDK wakes Spotify and attempts to resume the user's last song.
        // Existing PKCE credentials remain responsible for Web API playback and polling.
        remote.authorizeAndPlayURI(trackURI, completionHandler: completion)
    }

    func result(from url: URL) -> Bool? {
        guard let parameters = remote?.authorizationParameters(from: url) else { return nil }
        if let token = parameters[SPTAppRemoteAccessTokenKey], !token.isEmpty { return true }
        if parameters[SPTAppRemoteErrorKey] != nil || parameters[SPTAppRemoteErrorDescriptionKey] != nil { return false }
        return nil
    }

    func failureMessage(from url: URL) -> String? {
        guard let parameters = remote?.authorizationParameters(from: url) else { return nil }
        // Show actionable categories, never callback URLs or access tokens.
        let detail = [parameters[SPTAppRemoteErrorKey], parameters[SPTAppRemoteErrorDescriptionKey]]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if detail.contains("redirect") {
            return "Spotify 回呼網址設定不符，請確認 Developer Dashboard 已登記 spotifytrans://callback。"
        }
        if detail.contains("invalid_client") || detail.contains("bundle") {
            return "Spotify 未接受此 App，請確認 Client ID、iOS SDK 設定與 Bundle ID order.SpotifyTrans。"
        }
        return "Spotify 未完成啟動授權，請確認 Spotify App 與 Lyriva 使用同一帳號，並允許播放授權。"
    }
}

@MainActor
final class SpotifyPlaybackStarter: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var isConfirmingPlayback = false
    @Published private(set) var message: String?
    private let authorizer: any SpotifyPlaybackAuthorizing
    private var attempt: UUID?
    private var leftApp = false
    private var timeout: Task<Void, Never>?
    private var returnCheck: Task<Void, Never>?
    private var awaitingPlayback = false
    private var requestedTrackID: String?
    private var commandAfterWake: SpotifyConnection.PlaybackCommand?
    private var startupFailureMessage: String?
    private let confirmationTimeout: Duration

    init(authorizer: (any SpotifyPlaybackAuthorizing)? = nil, confirmationTimeout: Duration = .seconds(15)) {
        self.authorizer = authorizer ?? SpotifySDKPlaybackAuthorizer()
        self.confirmationTimeout = confirmationTimeout
    }

    func start(clientID: String, trackID: String? = nil) {
        guard !isStarting else { return }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "請先連接 Spotify。"
            return
        }
        let id = UUID()
        attempt = id
        leftApp = false
        isStarting = true
        awaitingPlayback = true
        requestedTrackID = trackID
        commandAfterWake = trackID.map { .track($0) } ?? .play
        startupFailureMessage = nil
        message = "正在開啟 Spotify…"
        authorizer.authorize(clientID: clientID, redirectURL: URL(string: SpotifyConnection.redirectURI)!,
                             trackURI: trackID.map { "spotify:track:\($0)" } ?? "") { [weak self] opened in
            Task { @MainActor in
                guard let self, self.attempt == id else { return }
                // SDK completion only confirms that Spotify can handle the request.
                if !opened, !self.isConfirmingPlayback {
                    self.finish(message: "無法開啟 Spotify，請確認已安裝並登入。")
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.attempt == id else { return }
            self.finish(message: "Spotify 啟動逾時，請再按一次播放。")
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard isStarting, url.scheme == "spotifytrans", url.host == "callback",
              url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil,
              let authorized = authorizer.result(from: url) else { return false }
        if !authorized { startupFailureMessage = authorizer.failureMessage(from: url) }
        // App Remote authorization is separate from our saved Web API login.
        // Even a denied SDK callback must poll and try the saved playback grant.
        beginPlaybackConfirmation()
        if !authorized { message = "Spotify 啟動授權未完成，正在嘗試已保存的播放連線…" }
        return true
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .background, isStarting { leftApp = true }
        guard phase == .active, isStarting, leftApp else { return }
        let id = attempt
        returnCheck?.cancel()
        returnCheck = Task { [weak self] in
            // Allow the URL callback to arrive after the foreground scene notification.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.attempt == id else { return }
            self.returnedWithoutCallback()
        }
    }

    func returnedWithoutCallback() {
        guard isStarting else { return }
        beginPlaybackConfirmation()
    }

    // authorizeAndPlayURI can keep the old song playing. After the first
    // successful poll on return, send the selected URI through the Web API once.
    func takePlaybackCommandAfterWake() -> SpotifyConnection.PlaybackCommand? {
        guard isConfirmingPlayback else { return nil }
        defer { commandAfterWake = nil }
        return commandAfterWake
    }

    func confirmPlayback(trackID: String? = nil) {
        reset()
        attempt = UUID()
        isStarting = true
        awaitingPlayback = true
        requestedTrackID = trackID
        beginPlaybackConfirmation()
    }

    private func beginPlaybackConfirmation() {
        guard isStarting, !isConfirmingPlayback else { return }
        timeout?.cancel()
        returnCheck?.cancel()
        isConfirmingPlayback = true
        message = "正在同步 Spotify 播放狀態…"
        let id = attempt
        timeout = Task { [weak self, confirmationTimeout] in
            do { try await Task.sleep(for: confirmationTimeout) } catch { return }
            guard let self, self.attempt == id else { return }
            self.finish(message: self.startupFailureMessage ?? "暫時無法取得播放狀態，將自動重試。", awaitingPlayback: true)
        }
    }

    func playbackObserved(isPlaying: Bool, hasTrack: Bool = false, trackID: String? = nil) {
        // A known paused track is also a valid connection. An SDK launch error
        // must not remain above a successful Web API response indefinitely.
        guard isPlaying || hasTrack, awaitingPlayback || isStarting || message != nil else { return }
        if isStarting, !isPlaying { return }
        if let requestedTrackID, requestedTrackID != trackID || !isPlaying { return }
        finish(message: nil)
    }

    func reset() { finish(message: nil) }

    private func finish(message: String?, awaitingPlayback: Bool = false) {
        timeout?.cancel()
        timeout = nil
        returnCheck?.cancel()
        returnCheck = nil
        attempt = nil
        leftApp = false
        isStarting = false
        isConfirmingPlayback = false
        commandAfterWake = nil
        startupFailureMessage = nil
        self.awaitingPlayback = awaitingPlayback
        if !awaitingPlayback { requestedTrackID = nil }
        self.message = message
    }
}

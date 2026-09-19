import Foundation
import Testing
@testable import SpotifyTrans

@MainActor
struct SpotifyPlaybackStarterTests {
    @Test func launchWaitsForCallbackAndIgnoresDuplicateTaps() async {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        starter.start(clientID: "test-client")
        #expect(authorizer.calls == 1)
        #expect(authorizer.redirectURL?.absoluteString == SpotifyConnection.redirectURI)
        authorizer.completion?(true)
        await Task.yield()
        #expect(starter.isStarting)
        #expect(!starter.handleCallback(URL(string: "spotifytrans://wrong-host#access_token=test")!))
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback/unexpected#access_token=test")!))
        #expect(starter.isStarting)
        authorizer.callbackResult = true
        #expect(starter.handleCallback(URL(string: "spotifytrans://callback#access_token=test")!))
        #expect(starter.isStarting)
        #expect(starter.isConfirmingPlayback)
        starter.playbackObserved(isPlaying: false)
        #expect(starter.isStarting)
        starter.playbackObserved(isPlaying: true)
        #expect(!starter.isStarting)
        #expect(starter.message == nil)
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback#access_token=test")!))
    }

    @Test func missingSpotifyAndMissingClientIDLeavePlaybackRetryable() async {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: " ")
        #expect(authorizer.calls == 0)
        #expect(!starter.isStarting)
        starter.start(clientID: "test-client")
        authorizer.completion?(false)
        for _ in 0..<5 { await Task.yield() }
        #expect(!starter.isStarting)
        #expect(starter.message?.contains("安裝") == true)
        starter.start(clientID: "test-client")
        #expect(starter.isStarting)
        starter.reset()
    }

    @Test func deniedSDKAuthorizationKeepsSavedPlaybackRecoveryAvailable() {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        authorizer.callbackResult = false
        #expect(starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        #expect(starter.isConfirmingPlayback)
        #expect(starter.takePlaybackCommandAfterWake() == .play)
        #expect(starter.takePlaybackCommandAfterWake() == nil)
        starter.playbackObserved(isPlaying: false, hasTrack: true)
        #expect(starter.isConfirmingPlayback)
        starter.playbackObserved(isPlaying: true, hasTrack: true)
        #expect(starter.message == nil)
        #expect(!starter.isStarting)
        #expect(authorizer.calls == 1)
    }

    @Test func widgetNavigationResetIgnoresLateAuthorizationCallback() async {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        starter.sceneChanged(.background)
        starter.sceneChanged(.active)
        let completion = authorizer.completion
        starter.reset()
        authorizer.callbackResult = false
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        completion?(false)
        for _ in 0..<5 { await Task.yield() }
        #expect(starter.message == nil)
        #expect(!starter.isStarting)
    }

    @Test func deniedAuthorizationAllowsRetryAndMissingCallbackWaitsForPlayback() {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback?code=web-oauth-code")!))
        #expect(starter.isStarting)
        authorizer.callbackResult = false
        #expect(starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        #expect(starter.isConfirmingPlayback)
        #expect(starter.message?.contains("授權未完成") == true)
        starter.reset()
        starter.start(clientID: "test-client")
        starter.returnedWithoutCallback()
        #expect(starter.isStarting)
        #expect(starter.isConfirmingPlayback)
        #expect(starter.message?.contains("正在同步") == true)
        starter.playbackObserved(isPlaying: true)
        #expect(!starter.isStarting)
        #expect(starter.message == nil)
    }

    @Test func playbackAfterConfirmationTimeoutClearsOldMessage() async {
        let starter = SpotifyPlaybackStarter(authorizer: MockPlaybackAuthorizer(), confirmationTimeout: .zero)
        starter.start(clientID: "test-client")
        starter.returnedWithoutCallback()
        while starter.isStarting { await Task.yield() }
        #expect(starter.message?.contains("自動重試") == true)
        #expect(!starter.isConfirmingPlayback)
        starter.playbackObserved(isPlaying: true)
        #expect(starter.message == nil)
    }

    @Test func resetCancelsOldConfirmationTimeout() async {
        let starter = SpotifyPlaybackStarter(authorizer: MockPlaybackAuthorizer(), confirmationTimeout: .zero)
        starter.start(clientID: "test-client")
        starter.returnedWithoutCallback()
        starter.reset()
        starter.start(clientID: "test-client")
        for _ in 0..<10 { await Task.yield() }
        #expect(starter.isStarting)
        #expect(!starter.isConfirmingPlayback)
        #expect(starter.message == "正在開啟 Spotify…")
        starter.reset()
    }

    @Test func failedLaunchCompletionAfterReturnDoesNotOverrideConfirmation() async {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        starter.returnedWithoutCallback()
        authorizer.completion?(false)
        for _ in 0..<5 { await Task.yield() }
        #expect(starter.isConfirmingPlayback)
        starter.reset()
    }

    @Test func lateLaunchCompletionCannotOverwriteNewAttempt() async {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        let oldCompletion = authorizer.completion
        starter.reset()
        starter.start(clientID: "test-client")
        oldCompletion?(false)
        for _ in 0..<5 { await Task.yield() }
        #expect(starter.isStarting)
        #expect(starter.message?.contains("正在開啟") == true)
        starter.reset()
    }
}

@MainActor
private final class MockPlaybackAuthorizer: SpotifyPlaybackAuthorizing {
    var calls = 0
    var redirectURL: URL?
    var completion: (@Sendable (Bool) -> Void)?
    var callbackResult: Bool?
    func authorize(clientID: String, redirectURL: URL, trackURI: String, completion: @escaping @Sendable (Bool) -> Void) {
        calls += 1
        self.redirectURL = redirectURL
        self.completion = completion
    }
    func result(from url: URL) -> Bool? { callbackResult }
}

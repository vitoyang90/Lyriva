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

    @Test func deniedAuthorizationOrReturningWithoutCallbackAllowsRetry() {
        let authorizer = MockPlaybackAuthorizer()
        let starter = SpotifyPlaybackStarter(authorizer: authorizer)
        starter.start(clientID: "test-client")
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback?code=web-oauth-code")!))
        #expect(starter.isStarting)
        authorizer.callbackResult = false
        #expect(!starter.handleCallback(URL(string: "spotifytrans://callback#error=access_denied")!))
        #expect(!starter.isStarting)
        #expect(starter.message?.contains("授權未完成") == true)
        starter.start(clientID: "test-client")
        starter.returnedWithoutCallback()
        #expect(!starter.isStarting)
        #expect(starter.message?.contains("未收到") == true)
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
    func authorize(clientID: String, redirectURL: URL, completion: @escaping @Sendable (Bool) -> Void) {
        calls += 1
        self.redirectURL = redirectURL
        self.completion = completion
    }
    func result(from url: URL) -> Bool? { callbackResult }
}

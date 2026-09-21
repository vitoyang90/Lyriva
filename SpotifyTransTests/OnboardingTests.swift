import Foundation
import AuthenticationServices
import Testing
@testable import SpotifyTrans

@MainActor
struct OnboardingTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "onboarding-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func interruptedFlowResumesAndSkippedLyricsDoNotRepeatAfterCompletion() {
        withDefaults { defaults in
            let first = OnboardingStore(defaults: defaults)
            first.reconcile(playback: .missing, lyrics: .missing)
            #expect(first.step == .welcome)
            first.begin()
            // Cancelled/failed OAuth leaves no saved session and must stay on this step.
            first.reconcile(playback: .missing, lyrics: .missing)
            let resumed = OnboardingStore(defaults: defaults)
            resumed.reconcile(playback: .missing, lyrics: .missing)
            #expect(resumed.step == .spotify)
            resumed.reconcile(playback: .authorized, lyrics: .missing)
            #expect(resumed.step == .lyrics)
            // Closing the lyrics sheet without saving does not advance.
            resumed.reconcile(playback: .authorized, lyrics: .missing)
            #expect(resumed.step == .lyrics)
            resumed.deferLyrics()
            #expect(resumed.step == .ready)
            #expect(!resumed.isComplete)
            let ready = OnboardingStore(defaults: defaults)
            ready.reconcile(playback: .authorized, lyrics: .missing)
            #expect(ready.step == .ready)
            #expect(ready.lyricsChoice == .deferred)
            ready.finish()
            let nextLaunch = OnboardingStore(defaults: defaults)
            nextLaunch.reconcile(playback: .missing, lyrics: .missing)
            #expect(nextLaunch.isComplete) // Signing out must not replay the tour.
            nextLaunch.reconcile(playback: .reauthorizationRequired, lyrics: .missing)
            #expect(nextLaunch.isComplete)
        }
    }

    @Test func authorizationSavedBeforeTerminationResumesAtLyricsRatherThanMigrating() {
        withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.reconcile(playback: .missing, lyrics: .missing)
            store.begin()
            let relaunched = OnboardingStore(defaults: defaults)
            relaunched.reconcile(playback: .authorized, lyrics: .missing)
            #expect(relaunched.step == .lyrics)
            #expect(!relaunched.isComplete)
            relaunched.reconcile(playback: .authorized, lyrics: .saved)
            #expect(relaunched.step == .ready)
            #expect(relaunched.lyricsChoice == .enabled)
            #expect(!relaunched.isComplete)
            relaunched.finish()
            #expect(relaunched.isComplete)
        }
    }

    @Test func unavailableKeychainDelaysMigrationAndExistingSessionsSkipTour() {
        for playback in [OnboardingStore.PlaybackAccess.authorized, .reauthorizationRequired] {
            withDefaults { defaults in
                let store = OnboardingStore(defaults: defaults)
                store.reconcile(playback: .unavailable, lyrics: .unavailable)
                #expect(!store.launchResolved)
                #expect(defaults.data(forKey: OnboardingStore.storageKey) == nil)
                store.reconcile(playback: playback, lyrics: .missing)
                #expect(store.launchResolved)
                #expect(store.isComplete)
            }
        }
    }

    @Test func unavailableCredentialsNeverEraseProgressOrAllowPrematureCompletion() {
        withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.reconcile(playback: .missing, lyrics: .missing)
            store.begin()
            store.finish()
            #expect(!store.isComplete)
            store.reconcile(playback: .authorized, lyrics: .saved)
            #expect(store.step == .ready)
            store.reconcile(playback: .unavailable, lyrics: .unavailable)
            store.finish()
            #expect(store.step == .ready)
            #expect(!store.isComplete)
            store.reconcile(playback: .authorized, lyrics: .saved)
            store.finish()
            store.reconcile(playback: .unavailable, lyrics: .unavailable)
            #expect(store.isComplete)
        }
    }

    @Test func revokedCredentialsReturnToRelevantStepAndPreserveSkipChoice() {
        withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.reconcile(playback: .missing, lyrics: .missing)
            store.begin()
            store.reconcile(playback: .authorized, lyrics: .saved)
            store.reconcile(playback: .authorized, lyrics: .missing)
            #expect(store.step == .lyrics)
            store.deferLyrics()
            store.reconcile(playback: .reauthorizationRequired, lyrics: .missing)
            #expect(store.step == .spotify)
            store.finish()
            #expect(!store.isComplete)
            store.reconcile(playback: .authorized, lyrics: .missing)
            #expect(store.step == .ready)
            #expect(store.lyricsChoice == .deferred)
        }
    }

    @Test func unavailableLyricsCanBeDeferredWithoutClaimingTheyAreEnabled() {
        withDefaults { defaults in
            let store = OnboardingStore(defaults: defaults)
            store.reconcile(playback: .missing, lyrics: .unavailable)
            store.begin()
            store.reconcile(playback: .authorized, lyrics: .unavailable)
            #expect(store.step == .lyrics)
            store.deferLyrics()
            #expect(store.lyricsChoice == .deferred)
            store.finish()
            #expect(store.isComplete)
        }
    }

    @Test func clientConfigurationResolvesAndKeepsExistingAuthorizationIdentity() {
        #expect(SpotifyAppConfiguration.resolveClientID(configured: " bundled ", debugOverride: nil) == "bundled")
        #expect(SpotifyAppConfiguration.resolveClientID(configured: "bundled", debugOverride: " local ") == "local")
        #expect(SpotifyAppConfiguration.resolveClientID(configured: "bundled", debugOverride: " ") == "bundled")
        #expect(SpotifyAppConfiguration.resolveClientID(configured: "$(SPOTIFY_CLIENT_ID)", debugOverride: nil).isEmpty)
        #expect(SpotifyAppConfiguration.authorizationClientID(saved: "old-app", configured: "new-app") == "old-app")
        #expect(SpotifyAppConfiguration.authorizationClientID(saved: "", configured: "new-app") == "new-app")
    }

    @Test func cancelledReauthorizationPreservesOriginalClientAndAllowsRetry() async {
        let storage = OnboardingMemorySessionStorage(SpotifySession(id: UUID(), clientID: "original-client",
            accessToken: "test", refreshToken: "test", expiresAt: .distantFuture, needsAuthorization: true))
        var latest: CapturedAuthentication?
        let connection = SpotifyConnection(sessionStorage: storage, makeAuthenticationSession: { url, _, callback in
            let session = CapturedAuthentication(url: url, callback: callback)
            latest = session
            return session
        })
        connection.connect(clientID: "replacement-client")
        #expect(connection.busy)
        latest?.callback(nil, ASWebAuthenticationSessionError(.canceledLogin))
        for _ in 0..<20 { await Task.yield() }
        #expect(!connection.busy)
        #expect(connection.connected)
        #expect(connection.requiresReauthorization)
        #expect(connection.savedClientID == "original-client")
        connection.connect()
        let items = latest.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(items?.first(where: { $0.name == "client_id" })?.value == "original-client")
        #expect(items?.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        latest?.callback(nil, ASWebAuthenticationSessionError(.canceledLogin))
        for _ in 0..<20 { await Task.yield() }
        #expect(!connection.busy)
    }

    @Test func failedAuthenticationLaunchAndInvalidCallbackNeverAdvanceLogin() async {
        var latest: CapturedAuthentication?
        var canStart = false
        let connection = SpotifyConnection(restoreSession: false, makeAuthenticationSession: { url, _, callback in
            let session = CapturedAuthentication(url: url, callback: callback, canStart: canStart)
            latest = session
            return session
        })
        connection.connect(clientID: "test-client")
        #expect(!connection.busy)
        #expect(!connection.connected)
        #expect(connection.status == "無法開啟登入畫面，請重試。")
        canStart = true
        connection.connect(clientID: "test-client")
        latest?.callback(URL(string: "spotifytrans://callback?code=test&state=wrong"), nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(!connection.connected)
        #expect(!connection.busy)
        #expect(connection.savedClientID.isEmpty)
        #expect(connection.status == "連線失敗，請重新連接 Spotify。")
    }
}

private final class CapturedAuthentication: SpotifyAuthenticatingSession {
    weak var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    let url: URL
    let callback: (URL?, Error?) -> Void
    let canStart: Bool
    init(url: URL, callback: @escaping (URL?, Error?) -> Void, canStart: Bool = true) {
        self.url = url
        self.callback = callback
        self.canStart = canStart
    }
    func start() -> Bool { canStart }
}

private final class OnboardingMemorySessionStorage: SpotifySessionStorage, @unchecked Sendable {
    private var value: SpotifySession?
    private let lock = NSLock()
    init(_ value: SpotifySession?) { self.value = value }
    func read() -> SpotifySession? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try mutation(&value)
    }
}

#if DEBUG
import AuthenticationServices
import Foundation

/// Explicitly opted-in, local-only login simulation. Never touches real credentials.
@MainActor
final class OnboardingUITestFixture {
    static let current: OnboardingUITestFixture? = {
        guard ProcessInfo.processInfo.arguments.contains("--onboarding-ui-fixture"),
              let name = ProcessInfo.processInfo.environment["ONBOARDING_TEST_SUITE"],
              name.hasPrefix("lyriva.onboarding-ui.") else { return nil }
        return OnboardingUITestFixture(defaults: UserDefaults(suiteName: name)!)
    }()

    let defaults: UserDefaults
    var lyricsSaved: Bool { defaults.bool(forKey: "fixture.lyrics") }
    init(defaults: UserDefaults) { self.defaults = defaults }

    func saveLyrics() { defaults.set(true, forKey: "fixture.lyrics") }

    func connection() -> SpotifyConnection {
        let storage = OnboardingFixtureStorage(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingFixtureHTTP.self]
        let session = URLSession(configuration: configuration)
        return SpotifyConnection(sessionStorage: storage,
            authorization: SpotifyAuthorization(store: storage, session: session,
                lockDirectory: FileManager.default.temporaryDirectory),
            playbackSession: session,
            widgetStorage: WidgetSnapshotStorage(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("onboarding-widget-\(UUID().uuidString)")),
            makeAuthenticationSession: { [defaults] url, _, completion in
                let cancel = ProcessInfo.processInfo.arguments.contains("--onboarding-cancel-first")
                    && !defaults.bool(forKey: "fixture.attempted")
                defaults.set(true, forKey: "fixture.attempted")
                return OnboardingFixtureAuthentication(url: url, cancel: cancel, completion: completion)
            })
    }
}

private struct OnboardingFixtureStorage: SpotifySessionStorage, @unchecked Sendable {
    let defaults: UserDefaults
    func read() throws -> SpotifySession? {
        guard let data = defaults.data(forKey: "fixture.session") else { return nil }
        return try JSONDecoder().decode(SpotifySession.self, from: data)
    }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws {
        var value = try read()
        try mutation(&value)
        if let value { defaults.set(try JSONEncoder().encode(value), forKey: "fixture.session") }
        else { defaults.removeObject(forKey: "fixture.session") }
    }
}

private final class OnboardingFixtureAuthentication: SpotifyAuthenticatingSession {
    weak var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    let url: URL
    let cancel: Bool
    let completion: (URL?, Error?) -> Void
    init(url: URL, cancel: Bool, completion: @escaping (URL?, Error?) -> Void) {
        self.url = url
        self.cancel = cancel
        self.completion = completion
    }
    func start() -> Bool {
        if cancel {
            completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
        } else {
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "state" })?.value ?? ""
            completion(URL(string: "spotifytrans://callback?code=fixture&state=\(state)"), nil)
        }
        return true
    }
}

private final class OnboardingFixtureHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.url?.path == "/api/token"
        let data = Data(#"{"access_token":"fixture-only","refresh_token":"fixture-only","expires_in":3600}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: token ? 200 : 204,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if token { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif

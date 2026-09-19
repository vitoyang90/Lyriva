import Foundation
import Security
import Darwin

// The existing App Group also grants Keychain access to the app and its widget.
// No credentials are written to the shared JSON file or to UserDefaults.
struct SharedKeychain {
    let account: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "order.SpotifyTrans.shared",
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: WidgetSongSnapshot.appGroup]
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AuthorizationError.storage }
        return data
    }
    func write(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthorizationError.storage }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw AuthorizationError.storage
            }
        } else if status != errSecSuccess { throw AuthorizationError.storage }
    }
}

enum AuthorizationError: LocalizedError {
    case storage, signedOut, reauthorizationRequired, busy, response(Int)
    var errorDescription: String? {
        switch self {
        case .storage: return "無法存取登入資料，請重新開啟 App 後再試。"
        case .signedOut: return "請重新連接 Spotify。"
        case .reauthorizationRequired: return "Spotify 授權已到期，請至設定重新授權。"
        case .busy: return "正在更新連線，請稍後再試。"
        case .response: return "暫時無法更新連線，請稍後再試。"
        }
    }
}

// An OS file lock is released even if iOS terminates the extension. The lock file
// contains no data. Short mutations and network refreshes use separate locks so
// signing out never waits for a network request.
final class SharedFileLock {
    private let descriptor: Int32
    init(name: String, directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSongSnapshot.appGroup)) throws {
        guard let directory else { throw AuthorizationError.storage }
        descriptor = open(directory.appendingPathComponent(name).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AuthorizationError.storage }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    func tryAcquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK else { throw AuthorizationError.storage }
        return false
    }
    func acquire(attempts: Int = 40) async throws {
        // Never block the main thread or exhaust an extension's execution time.
        for _ in 0..<attempts {
            try Task.checkCancellation()
            if try tryAcquire() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AuthorizationError.busy
    }
}

struct SpotifySession: Codable, Equatable, Sendable {
    let id: UUID
    let clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var needsAuthorization: Bool? = nil
}

protocol SpotifySessionStorage: Sendable {
    func read() throws -> SpotifySession?
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws
}

struct KeychainSessionStorage: SpotifySessionStorage {
    private let keychain = SharedKeychain(account: "playback")
    func read() throws -> SpotifySession? {
        try keychain.read().map { try JSONDecoder().decode(SpotifySession.self, from: $0) }
    }
    func update(_ mutation: (inout SpotifySession?) throws -> Void) throws {
        let lock = try SharedFileLock(name: "authorization-store.lock")
        guard try lock.tryAcquire() else { throw AuthorizationError.busy }
        defer { withExtendedLifetime(lock) {} }
        var value = try read()
        try mutation(&value)
        try keychain.write(value.map { try JSONEncoder().encode($0) })
    }
}

actor SpotifyAuthorization {
    static let shared = SpotifyAuthorization()
    private let store: any SpotifySessionStorage
    private let session: URLSession
    private let lockDirectory: URL?
    init(store: any SpotifySessionStorage = KeychainSessionStorage(), session: URLSession? = nil,
         lockDirectory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSongSnapshot.appGroup)) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoSpotifyRedirects(), delegateQueue: nil)
        self.lockDirectory = lockDirectory
    }
    func exchange(code: String, verifier: String, clientID: String, redirectURI: String) async throws {
        let tokens = try await request(["grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "client_id": clientID, "redirect_uri": redirectURI])
        guard let refresh = tokens.refresh_token, !refresh.isEmpty else { throw AuthorizationError.signedOut }
        let value = SpotifySession(id: UUID(), clientID: clientID, accessToken: tokens.access_token,
            refreshToken: refresh, expiresAt: Date().addingTimeInterval(tokens.expires_in - 60))
        try store.update { $0 = value }
    }
    func validSession() async throws -> SpotifySession {
        guard let saved = try store.read() else { throw AuthorizationError.signedOut }
        guard saved.needsAuthorization != true else { throw AuthorizationError.reauthorizationRequired }
        if saved.expiresAt > Date() { return saved }
        let lock = try SharedFileLock(name: "authorization-refresh.lock", directory: lockDirectory)
        try await lock.acquire()
        defer { withExtendedLifetime(lock) {} }
        // Re-read after waiting: the other process may have rotated the refresh token.
        guard var current = try store.read(), current.id == saved.id else { throw AuthorizationError.signedOut }
        guard current.needsAuthorization != true else { throw AuthorizationError.reauthorizationRequired }
        if current.expiresAt > Date() { return current }
        let tokens: Tokens
        do {
            tokens = try await request(["grant_type": "refresh_token", "refresh_token": current.refreshToken,
                                       "client_id": current.clientID])
        } catch AuthorizationError.reauthorizationRequired {
            try store.update { value in
                guard value?.id == current.id, value?.refreshToken == current.refreshToken else { return }
                value?.needsAuthorization = true
            }
            throw AuthorizationError.reauthorizationRequired
        }
        current.accessToken = tokens.access_token
        current.refreshToken = tokens.refresh_token ?? current.refreshToken
        current.expiresAt = Date().addingTimeInterval(tokens.expires_in - 60)
        try store.update { value in
            // A response arriving after logout/relogin must never restore old credentials.
            guard value?.id == current.id else { throw AuthorizationError.signedOut }
            value = current
        }
        return current
    }
    func invalidate(_ rejected: SpotifySession) throws {
        try store.update { current in
            // A concurrent successful refresh should not be invalidated by an old 401.
            guard current?.id == rejected.id, current?.accessToken == rejected.accessToken else { return }
            current?.expiresAt = .distantPast
        }
    }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    private func request(_ fields: [String: String]) async throws -> Tokens {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 400, fields["grant_type"] == "refresh_token",
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               body["error"] as? String == "invalid_grant" {
                throw AuthorizationError.reauthorizationRequired
            }
            throw AuthorizationError.response(code)
        }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard !tokens.access_token.isEmpty, tokens.expires_in.isFinite, tokens.expires_in > 0 else {
            throw AuthorizationError.signedOut
        }
        return tokens
    }
}

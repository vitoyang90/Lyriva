import Foundation
import CryptoKit
import Security

/// Spotify's undocumented Web Player protocol. This may change independently of the public API.
actor DirectLyricsClient {
    static let shared = DirectLyricsClient()
    private let session: URLSession
    private let cookie: @Sendable () throws -> String
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var cookieFingerprint: SHA256.Digest?
    private var nextAllowedRequest = Date.distantPast

    init(session: URLSession? = nil, cookie: @escaping @Sendable () throws -> String = { try LyricsCredential.read() }) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: NoLyricsRedirects(), delegateQueue: nil)
        self.cookie = cookie
    }

    func fetch(trackID: String) async throws -> LyricsDocument {
        guard trackID.count == 22, trackID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw LyricsError.message("這首歌沒有可用的 Spotify ID。")
        }
        guard Date() >= nextAllowedRequest else { throw LyricsError.message("Spotify 暫時限制請求，請稍後重試。") }
        let credential = try cookie()
        guard !credential.isEmpty, credential.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ";" }) else {
            throw LyricsError.message("請先登入歌詞來源。")
        }
        let fingerprint = SHA256.hash(data: Data(credential.utf8))
        if fingerprint != cookieFingerprint {
            token = nil
            cookieFingerprint = fingerprint
        }
        if token == nil || tokenExpiry <= Date() { try await authenticate(cookie: credential) }
        var request = URLRequest(url: URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)?format=json&market=from_token")!, timeoutInterval: 20)
        request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-platform")
        let data = try await get(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = root["lyrics"] as? [String: Any] else {
            throw LyricsError.message("Spotify 歌詞格式已變更，暫時無法讀取。")
        }
        payload["error"] = false
        return try LyricsDocument.decode(JSONSerialization.data(withJSONObject: payload))
    }

    private func authenticate(cookie: String) async throws {
        // Public protocol constants only: no cookie or user information goes to GitHub.
        let constantsData = try await get(URLRequest(url: URL(string: "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json")!, timeoutInterval: 15))
        let constants = try JSONDecoder().decode([String: [Int]].self, from: constantsData)
        guard let version = constants.keys.compactMap(Int.init).max(),
              let values = constants[String(version)], !values.isEmpty, values.count < 1024,
              values.allSatisfy({ (0...255).contains($0) }) else {
            throw LyricsError.message("無法取得網頁歌詞協定資訊，請稍後重試。")
        }
        let key = values.enumerated().map { String($0.element ^ (($0.offset % 33) + 9)) }.joined()
        let timeData = try await get(URLRequest(url: URL(string: "https://open.spotify.com/api/server-time")!, timeoutInterval: 15))
        struct ServerTime: Decodable { let serverTime: Double }
        let time = try JSONDecoder().decode(ServerTime.self, from: timeData).serverTime
        guard time.isFinite, time > 0, time < 100_000_000_000 else { throw LyricsError.message("Spotify 伺服器時間無效。") }
        var endpoint = URLComponents(string: "https://open.spotify.com/api/token")!
        endpoint.queryItems = ["reason": "transport", "productType": "web-player",
                               "totp": Self.oneTimeCode(key: Data(key.utf8), seconds: time),
                               "totpVer": String(version), "ts": String(Int(Date().timeIntervalSince1970))]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: endpoint.url!, timeoutInterval: 20)
        request.setValue("sp_dc=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data = try await get(request)
        struct WebToken: Decodable {
            let accessToken: String?
            let accessTokenExpirationTimestampMs: Double?
            let isAnonymous: Bool?
        }
        let response = try JSONDecoder().decode(WebToken.self, from: data)
        guard response.isAnonymous != true, let accessToken = response.accessToken, !accessToken.isEmpty,
              let expiry = response.accessTokenExpirationTimestampMs, expiry.isFinite,
              expiry > Date().timeIntervalSince1970 * 1000 else {
            throw LyricsError.message("歌詞登入已失效，請重新登入歌詞來源。")
        }
        token = accessToken
        tokenExpiry = Date(timeIntervalSince1970: expiry / 1000 - 30)
    }

    nonisolated static func oneTimeCode(key: Data, seconds: Double) -> String {
        var counter = UInt64(seconds / 30).bigEndian
        let bytes = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = Array(HMAC<Insecure.SHA1>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
        let offset = Int(digest.last! & 15)
        let value = (UInt32(digest[offset] & 127) << 24) | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8) | UInt32(digest[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    private func get(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LyricsError.message("無法讀取歌詞來源回應。") }
        switch response.statusCode {
        case 200: break
        case 401, 403:
            token = nil
            throw LyricsError.message("歌詞授權被拒絕，請重新登入歌詞來源；若仍失敗，可能是非官方介面已變更。")
        case 404: throw LyricsError.message("找不到這首歌的歌詞，請稍後重試。")
        case 429:
            let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30
            nextAllowedRequest = Date().addingTimeInterval(delay.isFinite ? max(1, delay) : 30)
            throw LyricsError.message("Spotify 暫時限制請求，請稍後重試。")
        default: throw LyricsError.message("歌詞來源暫時無法使用（\(response.statusCode)）。")
        }
        guard data.count < 2_000_000 else { throw LyricsError.message("歌詞來源回應過大。") }
        return data
    }
}

private final class NoLyricsRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum LyricsCredential {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "order.SpotifyTrans.lyrics", kSecAttrAccount as String: "web-session"]
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw LyricsError.message("請先登入歌詞來源。")
        }
        return value
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(attributes) { _, new in new }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw LyricsError.message("無法保存歌詞登入。") }
        } else if status != errSecSuccess { throw LyricsError.message("無法更新歌詞登入。") }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LyricsError.message("無法清除歌詞登入。") }
    }
}

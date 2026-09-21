import SwiftUI

enum SpotifyAppConfiguration {
    static var clientID: String {
        resolveClientID(configured: Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
                        debugOverride: debugClientID)
    }

    private static var debugClientID: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "spotifyClientID")
        #else
        return nil
        #endif
    }

    static func resolveClientID(configured: String?, debugOverride: String?) -> String {
        for candidate in [debugOverride, configured] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty, !value.contains("$(") { return value }
        }
        return ""
    }

    static func authorizationClientID(saved: String, configured: String) -> String {
        // Refreshing or extending an existing session must use its original app ID.
        saved.isEmpty ? configured : saved
    }
}

#if DEBUG
struct SpotifyDeveloperSettings: View {
    @AppStorage("spotifyClientID") private var clientID = ""

    var body: some View {
        DisclosureGroup("開發者設定") {
            VStack(alignment: .leading, spacing: 12) {
                Text("僅供開發測試。留白時使用 App 的 Client ID。")
                TextField("Spotify Client ID", text: $clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(16).background(Studio.background, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Spotify Client ID")
                Text(SpotifyConnection.redirectURI).textSelection(.enabled)
                Link("開啟 Developer Dashboard ↗", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            }
            .font(.caption).foregroundStyle(Studio.muted).padding(.top, 12)
        }
    }
}
#endif

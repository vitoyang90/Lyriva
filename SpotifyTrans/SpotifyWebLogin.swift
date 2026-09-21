import SwiftUI
import WebKit

struct SpotifyWebLogin: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void
    @State private var notice = "登入 Spotify 後，點選「完成」。"
    @State private var checking = false
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    var body: some View {
        NavigationStack {
            VStack {
                Text(notice).font(.footnote).padding()
                #if DEBUG
                if OnboardingUITestFixture.current != nil {
                    Text("本機歌詞登入測試").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WebLoginContent(webView: webView)
                }
                #else
                WebLoginContent(webView: webView)
                #endif
            }
            .navigationTitle("啟用歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { saveSession() }.disabled(checking)
                }
            }
        }
    }

    private func saveSession() {
        #if DEBUG
        if let fixture = OnboardingUITestFixture.current {
            fixture.saveLyrics()
            onComplete()
            dismiss()
            return
        }
        #endif
        checking = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            Task { @MainActor in
                defer { checking = false }
                guard let cookie = cookies.first(where: {
                    $0.name == "sp_dc" && [".spotify.com", "spotify.com", "open.spotify.com", ".open.spotify.com"].contains($0.domain)
                        && ($0.expiresDate ?? .distantFuture) > Date()
                }) else {
                    notice = "請先登入並開啟 Spotify 網頁播放器，再點選「完成」。"
                    return
                }
                do {
                    try LyricsCredential.save(cookie.value)
                    onComplete()
                    dismiss()
                } catch { notice = error.localizedDescription }
            }
        }
    }
}

private struct WebLoginContent: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

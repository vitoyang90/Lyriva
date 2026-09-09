import SwiftUI
import WebKit

struct SpotifyWebLogin: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: () -> Void
    @State private var notice = "請登入 Spotify 網頁，完成後按「使用此登入」。登入憑證只保存在此手機。"
    @State private var checking = false
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    var body: some View {
        NavigationStack {
            VStack {
                Text(notice).font(.footnote).padding()
                WebLoginContent(webView: webView)
            }
            .navigationTitle("Spotify 歌詞登入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用此登入") { saveSession() }.disabled(checking)
                }
            }
        }
    }

    private func saveSession() {
        checking = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            Task { @MainActor in
                defer { checking = false }
                guard let cookie = cookies.first(where: {
                    $0.name == "sp_dc" && [".spotify.com", "spotify.com", "open.spotify.com", ".open.spotify.com"].contains($0.domain)
                        && ($0.expiresDate ?? .distantFuture) > Date()
                }) else {
                    notice = "尚未取得歌詞登入。請先完成登入並進入 Spotify 網頁播放器，再試一次。"
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

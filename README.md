# SpotifyTrans

iOS 18.4+ 的 Spotify 跟唱 App。手機直接取得歌曲狀態與歌詞，在裝置上產生羅馬字，依播放進度反白與捲動。日常使用不需要電腦、Docker 或自架後端。

## 介面

採用墨綠深色背景、萊姆綠重點色、自訂播放器卡片與歌詞排版。播放器顯示 Spotify 回傳的專輯封面，缺少封面或載入失敗時顯示唱片圖案。主畫面僅提供 Spotify 播放控制及同步原文／羅馬字，連線與歌詞登入集中於設定面板。沒有手動貼上、範例或練習模式。

## 手機使用流程

1. 在 Spotify Developer Dashboard 建立 App，設定 bundle ID `order.SpotifyTrans`、Redirect URI `spotifytrans://callback`。Spotify 帳號需要符合開發模式資格。
2. 用 Xcode 安裝 App，點選右上角設定，在「Spotify 播放控制」填入 Client ID，再按「連接 Spotify」。OAuth 只使用 PKCE，不需要 Client Secret。
3. 此版增加 `user-modify-playback-state` 權限。若用過舊版請重新登入授權。先在手機 Spotify 播放一首歌，再回到本 App，即可播放／暫停、上一首、下一首。控制的是 Spotify 目前的活動裝置；官方 Web API 播放控制需要 Premium。
4. 在設定面板的「手機歌詞來源」按「登入／更新歌詞來源」。在內嵌的 Spotify 網頁登入並進入播放器，再按「使用此登入」。這是歌詞用的獨立登入，與第 2 步的官方播放控制授權不同。
5. App 取得目前歌曲的歌詞並轉寫。歌詞缺少時間標記時顯示一般閱讀模式；取詞失敗可重新登入來源或重試；App 僅提供自動同步歌詞。

Spotify 官方 Web API 不提供歌詞。本機歌詞請求依據 spotify-lyrics-api 使用的非官方 Web Player 協定實作，不能直接讀取 Spotify App 的沙盒或 Cookie。若 Spotify 阻擋 WebView 登入、變更端點或協定，可能無法取得歌詞；目前尚未用使用者的真實帳號驗證。

## 轉寫與資料保存

- 使用 Foundation / NaturalLanguage 的裝置內建能力，不呼叫 LLM，不上傳歌詞作翻譯。
- 日文漢字用日文斷詞讀音，其他文字使用系統拉丁字母轉寫；英文／中文在自動模式保留原文。短句、混合語言與歌曲特殊讀音仍需人工確認，並不保證跟歌手唱法相同。
- 轉寫在背景工作執行，UI 顯示本次耗時。
- 不快取歷史歌曲。只保留目前畫面使用的歌詞；換歌、切換語言或按「重新取得」時重新抓詞與轉寫。
- 依目前需求，不建立 Excel、CSV 或資料庫。取得歌詞需要網路；關閉程序後目前歌詞消失。
- 前景每 5 秒校正 Spotify 歌曲與進度，暫停／跳播狀態最多約有 5 秒偵測延遲；網路延遲會增加時間。播放進度在兩次回應之間本機估算。App 進入背景停止輪詢。

## 登入資料

- 歌詞登入由使用者在 App 的獨立 WebView 完成，只擷取該 WebView 中 Spotify 網域的 `sp_dc` Cookie。只在按下「使用此登入」後保存。
- Cookie 使用 Keychain 的 `WhenUnlockedThisDeviceOnly`，不寫入偏好設定、歌詞、檔案、日誌或 Git；清除歌詞登入可移除。
- Cookie 僅送至 `open.spotify.com/api/token`；短期 Web Token 僅送至 Spotify 歌詞端點。拒絕 HTTP 重新導向，保留系統 TLS 憑證驗證。
- 歌詞協定需從公開 GitHub 來源下載協定常數，該請求不附 Cookie／Token。這代表仍依賴外部網站，但不需要自己維護後端。
- 官方 OAuth Token 目前只保存在記憶體，重開程序仍需重新連接 Spotify；Client ID 是公開識別碼，可保存在本機偏好設定。

## 驗證

已通過 iPhone 16 Pro／iOS 18.4 模擬器建置與 12 項自動測試，包含重播重新取詞、封面資料解析與缺少封面的檢查。

- Mac 初步量測：180 行混合語言文字首次約 177 ms，後續約 88–89 ms；不是實機 iPhone 的效能保證。
- 單元測試使用模擬 HTTP 回應，涵蓋非官方歌詞請求、憑證傳送範圍、一次性代碼、HTTP 錯誤、轉寫、重播重新取詞與換歌競態。
- 真實帳號登入、Premium 播放控制與歌詞可用性仍待實機驗證。

`backend/` 保留先前實驗部署檔供參考；目前 App 不再連接該後端。

自訂 callback scheme 依 Spotify iOS 文件設定；若 Dashboard 對你的 App 要求 HTTPS，需改用自有網域 Universal Link 並設定 Associated Domains。

## 參考

- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback
- https://github.com/spotify/ios-sdk/blob/master/docs/auth.md
- https://github.com/akashrchandran/spotify-lyrics-api
- https://github.com/xyloflake/spot-secrets-go

非官方歌詞來源可能隨時變更；原始專案也提醒可能違反 Spotify 使用條款，不能把此實驗當作穩定的官方歌詞服務。

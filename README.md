# SpotifyTrans

iOS 18.4+ 的 Spotify 跟唱 App。手機直接取得歌曲狀態與歌詞，在裝置上產生羅馬字，依播放進度反白與捲動。日常使用不需要電腦、Docker 或自架後端。

## 介面

採用墨綠深色背景、萊姆綠重點色、自訂播放器卡片與歌詞排版。播放器顯示 Spotify 回傳的專輯封面，缺少封面或載入失敗時顯示唱片圖案。主畫面僅提供 Spotify 播放控制及同步原文／羅馬字，連線與歌詞登入集中於設定面板。沒有手動貼上、範例或練習模式。

## 手機使用流程

1. 在 Spotify Developer Dashboard 建立 App，設定 bundle ID `order.SpotifyTrans`、Redirect URI `spotifytrans://callback`。在 API/SDK 選項中勾選 iOS。Spotify 帳號需要符合開發模式資格。
2. 用 Xcode 安裝 App，點選右上角設定，在「Spotify 播放控制」填入 Client ID，再按「連接 Spotify」。OAuth 只使用 PKCE，不需要 Client Secret。
3. 手機安裝並登入 Spotify 後，回到主畫面按播放。沒有目前歌曲或 Web API 回報沒有可用裝置時，App 透過官方 Spotify iOS SDK 喚起手機 Spotify，嘗試接續上次播放，再用相同 Redirect URI 返回。首次可能需要同意 App Remote 授權；未安裝、取消或未完成授權時會顯示重試提示。已有活動裝置時仍透過 Web API 控制播放／暫停、上一首、下一首，需要 Premium 與 `user-modify-playback-state` 權限。
4. 在設定面板的「手機歌詞來源」按「登入／更新歌詞來源」。在內嵌的 Spotify 網頁登入並進入播放器，再按「使用此登入」。這是歌詞用的獨立登入，與第 2 步的官方播放控制授權不同。
5. App 取得目前歌曲的歌詞並轉寫。歌詞缺少時間標記時顯示一般閱讀模式；取詞失敗可重新登入來源或重試；App 僅提供自動同步歌詞。

Spotify 官方 Web API 不提供歌詞。本機歌詞請求依據 spotify-lyrics-api 使用的非官方 Web Player 協定實作，不能直接讀取 Spotify App 的沙盒或 Cookie。若 Spotify 阻擋 WebView 登入、變更端點或協定，可能無法取得歌詞；目前尚未用使用者的真實帳號驗證。

## 轉寫與資料保存

- 使用 Foundation / NaturalLanguage 的裝置內建能力，不呼叫 LLM，不上傳歌詞作翻譯。
- 混合歌詞依文字片段轉寫，英文大小寫、標點與既有空白保留；日文使用日文斷詞讀音，其他文字使用系統拉丁字母轉寫。自動模式會參考整首歌的假名線索，改善「世界」「未来」「夢」等獨立漢字詞的日文判斷，同時保留仍辨識為中文的片段。只有漢字或中日混合的歌詞仍可能有歧義，可從語言選單選「日文（含漢字讀音）」；未知字保留原文，歌曲特殊讀音不保證與歌手唱法相同。
- 轉寫在背景工作執行，避免阻塞介面。
- 不快取歷史歌曲。只保留目前畫面使用的歌詞；換歌、切換語言或按「重新取得」時重新抓詞與轉寫。同一首歌的重複同步不重載；手動重新取得期間保留目前歌詞，成功後才替換。
- 依目前需求，不建立 Excel、CSV 或資料庫。取得歌詞需要網路；App 關閉後不保留完整歌詞，小工具只保留目前歌曲的顯示資料。
- 前景每 5 秒校正 Spotify 歌曲與進度，暫停／跳播狀態最多約有 5 秒偵測延遲；網路延遲會增加時間。播放進度在兩次回應之間本機估算。App 進入背景停止輪詢。定期同步不顯示讀取動畫；暫時失敗時保留目前歌曲與歌詞，凍結進度直到同步恢復。

## 主畫面歌詞快照小工具

- 用 Xcode 安裝此版並開啟 App 同步一首歌後，長按 iPhone 主畫面 → 加入小工具 → 搜尋「SpotifyTrans」。提供小、中、大三種尺寸；大尺寸另外顯示下一句。點擊小工具可返回 App。
- 顯示專輯封面、歌曲資訊、最近同步的歌詞原文／羅馬拼音與同步時間。這是最近一次的畫面快照，離開 App 後會停留在最近同步的句子，不會自動換下一句；iOS 限制小工具更新頻率，App 進入背景後也會停止歌曲輪詢。即時跟唱仍需在 App 內使用。
- 快照超過 15 分鐘時，時間軸會改顯示更新提示；實際畫面刷新時機由 iOS 決定。未取得歌詞時顯示開啟 App 提示，斷開 Spotify 連線時清除共享資料。
- App 和 `SpotifyTransWidgets` 透過 App Group `group.order.SpotifyTrans` 共用一份 `current-song.json`，只包含目前歌曲、目前／下一句與縮小封面，換歌覆蓋，不建立歷史歌詞庫、不共享 Token 或 Cookie、不需要後端。
- 兩個 target 已設定相同的 App Groups entitlement。實機安裝時，簽署用的 Apple Developer 團隊與 provisioning profiles 必須支援此 App Group；若改 bundle ID，也需一併調整兩份 entitlement 與共享模型中的群組名稱。

## 登入資料

- 歌詞登入由使用者在 App 的獨立 WebView 完成，只擷取該 WebView 中 Spotify 網域的 `sp_dc` Cookie。只在按下「使用此登入」後保存。
- Cookie 使用 Keychain 的 `WhenUnlockedThisDeviceOnly`，不寫入偏好設定、歌詞、檔案、日誌或 Git；清除歌詞登入可移除。
- Cookie 僅送至 `open.spotify.com/api/token`；短期 Web Token 僅送至 Spotify 歌詞端點。拒絕 HTTP 重新導向，保留系統 TLS 憑證驗證。
- 歌詞協定需從公開 GitHub 來源下載協定常數，該請求不附 Cookie／Token。這代表仍依賴外部網站，但不需要自己維護後端。
- 啟動播放使用官方 `SpotifyiOS` Swift Package（固定 5.0.1），不需要後端。SDK 回傳授權成功後，會重新查詢實際播放狀態；不把「已開啟 Spotify」當作已播放成功，也不將 App Remote 回傳的 Token 用於 Web API。
- 官方 OAuth Token 目前只保存在記憶體，重開程序仍需重新連接 Spotify；Client ID 是公開識別碼，可保存在本機偏好設定。

## 驗證

已通過 iPhone 16 Pro／iOS 18.4 模擬器建置與 29 項自動測試，包含小工具資料覆蓋／過期／三種尺寸渲染、日文漢字上下文轉寫、首次播放啟動回呼、取消／重試、日英文混合歌詞轉寫、同曲更新保留歌詞、同步失敗與恢復、重播重新取詞，以及封面資料解析。

- 單元測試使用模擬 HTTP 回應，涵蓋非官方歌詞請求、憑證傳送範圍、一次性代碼、HTTP 錯誤、轉寫、重播重新取詞與換歌競態。
- 真實帳號登入、首次喚起 Spotify／返回 App、Premium 播放控制與歌詞可用性仍待實機驗證。

自訂 callback scheme 依 Spotify iOS 文件設定；若 Dashboard 對你的 App 要求 HTTPS，需改用自有網域 Universal Link 並設定 Associated Domains。

## 參考

- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback
- https://github.com/spotify/ios-sdk/blob/master/docs/auth.md
- https://github.com/akashrchandran/spotify-lyrics-api
- https://github.com/xyloflake/spot-secrets-go

非官方歌詞來源可能隨時變更；原始專案也提醒可能違反 Spotify 使用條款，不能把此實驗當作穩定的官方歌詞服務。

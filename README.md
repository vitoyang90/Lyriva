# Lyriva

App 與小工具對外名稱已更新為 Lyriva。為沿用既有安裝、登入與 Spotify 回呼設定，Xcode 專案／target、Bundle ID、App Group、Keychain 識別與 URL scheme 保留原值。圖示來源與生成提示見 [設計紀錄](design/lyriva-icon-prompt.md)。

iOS 18.4+ 的 Spotify 跟唱 App。手機直接取得歌曲狀態與歌詞，在裝置上產生羅馬字，依播放進度反白與捲動。日常使用不需要電腦、Docker 或自架後端。

## 介面

採用墨綠深色背景、萊姆綠重點色、自訂播放器卡片與歌詞排版。播放器顯示 Spotify 回傳的專輯封面，缺少封面或載入失敗時顯示唱片圖案。主畫面僅提供 Spotify 播放控制及同步原文／羅馬字／繁體中文，首次啟動顯示獨立登入頁；已有登入資料時直接進入播放器，設定使用獨立頁面與原生返回導覽，保留帳號管理入口。沒有手動貼上、範例或練習模式。

## 橫向跟唱版面

[橫向三層字幕預覽：小](design/lyriva-landscape-subtitles-small.png) · [中](design/lyriva-landscape-subtitles-medium.png) · [大](design/lyriva-landscape-subtitles-large.png)（使用測試歌曲與注入譯文，不代表實機翻譯品質）

- 手機旋轉為橫向且可用寬度足夠時，自動切換為左右兩欄：左側約三分之一放精簡播放器，右側放大歌詞。直向沿用原本的上下排列。
- 左側縮小封面與歌名區塊，保留播放／暫停、切歌、更新、可拖曳進度條及設定入口；空間不足時播放器可獨立捲動。歌詞區使用剩餘高度獨立捲動，原文、羅馬字與繁體中文選項沿用原本設定。
- 橫直切換保留歌詞檢視的狀態與目前歌曲，自動捲動開啟時重新對齊目前句。橫向小／中／大字級為 18／22／26 pt，直向為 20／24／30 pt，兩種方向各自保存選擇並支援系統文字縮放。橫向減少字幕間距與歌詞行內留白。設定與登入沿用原本的頁面。
- 橫向 UI 測試以本機模擬播放與歌詞驗證排版、控制項可點擊、左右橫向／直向旋轉與設定返回；測試資料僅在 Debug 指定啟動參數時啟用，不發布小工具資料。

## 手機使用流程

1. 在 Spotify Developer Dashboard 建立 App，設定 bundle ID `order.SpotifyTrans`、Redirect URI `spotifytrans://callback`。在 API/SDK 選項中勾選 iOS。Spotify 帳號需要符合開發模式資格。
2. 用 Xcode 安裝 App，首次啟動會顯示登入頁，填入 Client ID 再按「連接 Spotify」。OAuth 只使用 PKCE，不需要 Client Secret。
3. 手機安裝並登入 Spotify 後，回到主畫面按播放。沒有目前歌曲或 Web API 回報沒有可用裝置時，App 透過官方 Spotify iOS SDK 喚起手機 Spotify，嘗試接續上次播放，再用相同 Redirect URI 返回。首次可能需要同意 App Remote 授權；未安裝、取消或未完成授權時會顯示重試提示。已有活動裝置時仍透過 Web API 控制播放／暫停、上一首、下一首，需要 Premium 與 `user-modify-playback-state` 權限。
4. 在同一個登入頁接著按「啟用歌詞」，在 Spotify 網頁登入並進入播放器，再按「完成」。完成後按「開始使用」進入播放器，也可先略過歌詞設定。播放與歌詞首次仍需各完成一次授權，已有歌詞憑證時不再顯示登入按鈕。之後可由設定 → 管理 Spotify 帳號開啟此頁。
5. App 取得目前歌曲的歌詞並轉寫。歌詞缺少時間標記時顯示一般閱讀模式；取詞失敗可重新登入來源或重試；App 僅提供自動同步歌詞。

Spotify 官方 Web API 不提供歌詞。本機歌詞請求依據 spotify-lyrics-api 使用的非官方 Web Player 協定實作，不能直接讀取 Spotify App 的沙盒或 Cookie。若 Spotify 阻擋 WebView 登入、變更端點或協定，可能無法取得歌詞；目前尚未用使用者的真實帳號驗證。

## 本機中文翻譯

- 在歌詞工具列開啟「中文」，可同時顯示原文、羅馬字與繁體中文；三項可各自開關，至少保留一項。選擇會保存在本機。翻譯尚未完成或無譯文時，保留原文作為後備顯示。
- 使用 Apple Translation 裝置端翻譯，不設定雲端 API Key、不將歌詞傳送至自架後端。播放頁先檢查模型，尚未安裝只提示「前往設定」，不主動要求下載。設定的「翻譯語言」頁動態列出系統支援的來源語言，逐一檢查至繁體中文的支援狀態，提供搜尋、手動下載、取消要求與重試；從歌詞提示進入時優先列出缺少的語言。中文直接轉繁體字，不列為模型下載項目。模型下載後可離線處理已取得的歌詞，取得 Spotify 歌詞仍需要網路。
- 模型由 Apple 系統管理。刪除需前往 iPhone「設定 → App → 翻譯 → 已下載的語言」（需安裝 Apple 翻譯），App 內提供路徑說明。取消會結束 App 的下載要求；系統已開始的共用模型下載不保證立即停止。iOS 26 使用禁止請求下載的 installedSource session；iOS 18 在建立工作及執行前檢查模型是否安裝。
- 按歌詞行 ID 對應譯文，共用原本的時間標記與自動捲動。日文、英文等來源語言各自分批並依序使用 Translation Session，遵守 [Apple 單一來源語言批次要求](https://developer.apple.com/documentation/translation/translationsession/translate(batch:))。同一句日英混用時依文字片段分組，全部片段成功後依原順序組回該行；未完成的行保留原文。重複片段共用結果，失敗重試只請求尚未完成的部分。
- 播放進度更新不重新翻譯。譯文僅保留目前歌曲於記憶體，換歌或歌詞內容改變時捨棄舊結果；關閉中文後不再接受未完成工作的結果。
- 日文假名與韓文片段直接使用對應來源語言；語言選單可協助判斷漢字片段，不會把英文強制套用日文翻譯。在日文歌曲或手動選擇日文／韓文時，短英文字母片段優先按英文處理；較長片段可偵測為其他語言，不受三種語言限制。其他偵測需足夠長度與可信度，避免短句誤判後要求下載不相關模型。中文片段直接轉為繁體字。混合語言拆分後的語序、隱喻與跨行語意品質仍需實機驗證，不承諾逐句翻譯等同人工譯詞。
- 翻譯錯誤可重試，不阻擋播放或原文顯示。小工具目前仍顯示原文與羅馬字。
- Apple Translation 的模型執行需實機，模擬器顯示提示。已驗證模擬器與實機編譯，並以注入翻譯結果測試逐行對應、重複句、換歌、取消、錯誤重試與目前歌曲快取；尚未實機驗證模型下載及翻譯品質。

## 轉寫與資料保存

- 使用 Foundation / NaturalLanguage 的裝置內建能力，不呼叫 LLM，不上傳歌詞作翻譯。
- 混合歌詞依文字片段轉寫，英文大小寫、標點與既有空白保留；日文使用日文斷詞讀音，其他文字使用系統拉丁字母轉寫。自動模式會參考整首歌的假名線索，改善「世界」「未来」「夢」等獨立漢字詞的日文判斷，同時保留仍辨識為中文的片段。只有漢字或中日混合的歌詞仍可能有歧義，可從語言選單選「日文」；未知字保留原文，歌曲特殊讀音不保證與歌手唱法相同。
- 修正系統將促音拆成 `~tsu` 的輸出：例如 `しまっ` + `た` 組回 `shimatta`，不把小「っ」當作獨立的 `tsu`。句尾小「っ」用 `’` 表示截斷；正常「つ」仍保留 `tsu`，助詞「を」顯示為 `o`。規則只作用於日文片段，手機與小工具共用，原文及送交翻譯的文字維持來源內容。
- 轉寫在背景工作執行，避免阻塞介面。
- 不快取歷史歌曲。只保留目前畫面使用的歌詞；換歌、切換語言或按「重新取得」時重新抓詞與轉寫。同一首歌的重複同步不重載；手動重新取得期間保留目前歌詞，成功後才替換。
- 依目前需求，不建立 Excel、CSV 或資料庫。取得歌詞需要網路；小工具只保存目前歌曲的顯示資料與有限的預排歌詞，換歌覆蓋。
- 前景每 5 秒校正 Spotify 歌曲與進度，暫停／跳播狀態最多約有 5 秒偵測延遲；網路延遲會增加時間。播放進度在兩次回應之間本機估算。App 進入背景停止輪詢。定期同步不顯示讀取動畫；暫時失敗時保留目前歌曲與歌詞，凍結進度直到同步恢復。

## 主畫面歌詞小工具（預估進度）

- 用 Xcode 安裝此版並開啟 App 同步一首歌後，長按 iPhone 主畫面 → 加入小工具 → 搜尋「Lyriva」。提供小、中、大三種尺寸；大尺寸另外顯示下一句。點擊小工具可返回 App。
- 有時間標記且 Spotify 正在播放時，將目前歌曲的未來歌詞時間預先交給 WidgetKit，依最後取得的播放位置推算換句，畫面標示「預估進度」。沒有時間標記、暫停或同步失敗時，保留最近取得的那一句。
- iOS 可能延後或合併時間軸更新，Apple 建議時間軸項目至少相隔約 5 分鐘，因此每幾秒換詞屬於實驗性嘗試，不能保證即時同步。App 進入背景後停止輪詢，但 WidgetKit 允許執行小工具時，小工具會自行向 Spotify 查詢目前播放歌曲、讀取歌詞並在裝置上轉寫。自然接續下一首不再只重讀上一首的 JSON；仍不能保證在切歌瞬間或每句時間點執行。回 App 可立即校正。
- 預計歌曲結束後 2 秒請求下一次更新；每次請求至少相隔 60 秒，長歌、暫停或失敗時約 5 分鐘後請求重試。這些是希望執行的日期，並非背景定時器，iOS 可能延後很久。過期後顯示等待更新；無歌詞的新歌仍更新歌名，204／非歌曲清除舊歌，429 遵守 Retry-After。單次工作設 22 秒取消期限。手機主畫面的實際更新頻率尚待驗證。
- App 和 `SpotifyTransWidgets` 透過 App Group `group.order.SpotifyTrans` 共用一份 `current-song.json`，只含目前歌曲資訊、縮小封面，以及最多 256 句目前／未來歌詞與時間標記。換歌覆蓋，不建立歷史歌詞庫，不在 JSON 中存放 Token 或 Cookie、不需要後端；中斷 Spotify 連線時清除。App 與小工具透過共享 Keychain 取得登入，檔案鎖協調更新，較舊的歌曲回應與封面不覆蓋較新的資料。
- 兩個 target 已設定相同的 App Groups entitlement。實機安裝時，簽署用的 Apple Developer 團隊與 provisioning profiles 必須支援此 App Group；若改 bundle ID，也需一併調整兩份 entitlement 與共享模型中的群組名稱。

## 登入資料

- 歌詞登入由使用者在 App 的 WebView 完成，只擷取該 WebView 中 Spotify 網域的 `sp_dc` Cookie，按下「完成」後保存。WebView 使用持久化的 WebKit 資料存放區，在 App 沙盒保留網站登入狀態，重新開啟登入頁可沿用。
- 供 App 與小工具使用的 Cookie 與官方 OAuth 憑證保存在共享 Keychain，使用 `AfterFirstUnlockThisDeviceOnly`（重新開機後需先解鎖一次）；不寫入偏好設定、歌詞資料、日誌或 Git。WebKit 另外管理自己的網站資料。帳號頁的「管理帳號 → 登出 Spotify」一併清除播放憑證、歌詞憑證及 App 內的 WebKit 網站資料，不登出 Spotify 官方 App。
- Cookie 僅送至 `open.spotify.com/api/token`；短期 Web Token 僅送至 Spotify 歌詞端點。拒絕 HTTP 重新導向，保留系統 TLS 憑證驗證。
- 歌詞協定需從公開 GitHub 來源下載協定常數，該請求不附 Cookie／Token。這代表仍依賴外部網站，但不需要自己維護後端。
- 啟動播放使用官方 `SpotifyiOS` Swift Package（固定 5.0.1），不需要後端。SDK 回傳授權成功後，會重新查詢實際播放狀態；不把「已開啟 Spotify」當作已播放成功，也不將 App Remote 回傳的 Token 用於 Web API。
- 官方 OAuth Access／Refresh Token 與 Client ID 存在此裝置的共享 Keychain，App 重啟可恢復登入，小工具可自行更新過期 Token。跨程序的檔案鎖避免同時旋轉 Refresh Token；登出後不接受遲到的更新回應。Client ID 本身是公開識別碼，也可保存在本機偏好設定。
- 沿用已存在的共享登入與舊歌詞 Cookie 遷移，不因改名或此版登入頁變更要求重新登入。暫時無法讀取 Keychain 或網路錯誤不會清除憑證。兩個 target 使用既有 App Group 作為 Keychain access group，實機須有有效簽署與 App Groups 設定。
- Access Token 到期會自動使用 Refresh Token 更新；播放 API 的 401 不會直接登出，歌詞短期 Token 的 401 也會使用已保存的 Cookie 更新並重試一次。只有 Refresh Token 回報 `invalid_grant` 或歌詞登入確認失效時才提示更新授權，避免反覆要求登入。
- 無法保證永久免登入：[Spotify 2026 年 6 月公告](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration)將 Developer Dashboard 應用的 Refresh Token 壽命訂為授權後六個月，2026 年 7 月 20 日生效。使用者撤銷授權或網站 Cookie 失效也可能需要重新登入。

## 驗證

測試使用 iPhone 16 Pro／iOS 18.4 模擬器，包含小工具資料覆蓋／過期／三種尺寸渲染、日文漢字上下文轉寫、首次播放啟動回呼、取消／重試、日英文混合歌詞轉寫、同曲更新保留歌詞、同步失敗與恢復、重播重新取詞，以及封面資料解析。

- 單元測試使用模擬 HTTP 回應，涵蓋非官方歌詞請求、憑證傳送範圍、一次性代碼、HTTP 錯誤、轉寫、重播重新取詞與換歌競態。
- 新增測試涵蓋自然換歌後重新抓取歌詞、缺詞換歌、暫停／無播放、歌曲結束後持續請求、舊封面防覆寫、並行 Token 更新、登出競態、401 更新與 429 重試。
- 真實帳號登入、App／小工具共享 Keychain、背景自然接續歌曲的實際更新延遲、首次喚起 Spotify／返回 App、Premium 播放控制與歌詞可用性仍待實機驗證。

自訂 callback scheme 依 Spotify iOS 文件設定；若 Dashboard 對你的 App 要求 HTTPS，需改用自有網域 Universal Link 並設定 Associated Domains。

## 參考

- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/documentation/web-api/reference/start-a-users-playback
- https://github.com/spotify/ios-sdk/blob/master/docs/auth.md
- https://github.com/akashrchandran/spotify-lyrics-api
- https://github.com/xyloflake/spot-secrets-go

非官方歌詞來源可能隨時變更；原始專案也提醒可能違反 Spotify 使用條款，不能把此實驗當作穩定的官方歌詞服務。

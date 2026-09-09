# 實驗歌詞後端（舊架構）

目前 iOS App 已改成手機直連，不需要執行此後端。以下保留先前部署方式供參考。

以 akashrchandran/spotify-lyrics-api 的固定版本 e158b96b854778d8ff51a3c9544ebb4f68b64907 建置。映像內保留上游 GPL-3.0 授權檔。原始碼來源：https://github.com/akashrchandran/spotify-lyrics-api

## 啟動

需要先安裝可執行 Docker Compose 的環境。本機目前未安裝 Docker，因此尚未實測映像建置與真實抓詞。

1. 將 `.env.example` 複製為同目錄的 `.env`。
2. 在本機編輯 `.env`：`SP_DC` 填入你自己的 Spotify 網頁登入 Cookie；`LYRICS_API_KEY` 設定一組隨機長字串（可使用 `openssl rand -hex 32` 產生）。不要將 Cookie 貼進聊天、App 或 Git。
3. 在此目錄執行 `docker compose up --build -d`。
4. iOS 模擬器 App 的「歌詞來源設定」填 `http://localhost:8080`，API Key 填你設定的 `LYRICS_API_KEY`，按「套用設定」。
5. 真機請使用你控制的 HTTPS 入口反向代理至此服務；真機的 localhost 指的是手機本身。預設容器只開放電腦的 loopback，未直接公開網際網路。

App 的 Spotify Client ID／OAuth 負責讀取你目前播放的歌曲；這個後端的 SP_DC 負責歌詞，兩者不同。API Key 在 App 僅存於這次畫面的記憶體，重新開啟／切換手動模式返回後可能需要重填。

## 後端調整

- 恢復上游兩處 HTTPS 憑證與主機名稱驗證，若上游結構不符就讓建置失敗。
- 所有 cURL 請求設逾時，外部金鑰檔讀取也有 socket timeout。
- 所有路徑都經過同一個 router，必須有 Bearer API Key；不直接提供原始碼或未受保護的上游入口。
- 僅接受 22 碼 Spotify trackid。回傳統一錯誤，不把上游例外內容傳給 App。
- 非 root 使用者、唯讀根目錄，Token 暫存放在 tmpfs。

這是個人實驗用的 PHP 內建伺服器。對外部署前需要正式 Web server、HTTPS 與流量限制。第三方依賴未全部固定為映像 digest。此專案依賴 Spotify 內部介面與額外的上游金鑰來源，失效時需要更新；上游作者提醒可能違反 Spotify 條款。Cookie 過期請在本機更新 `.env` 並重新建立容器。程式碼授權不代表取得歌詞內容的使用授權。

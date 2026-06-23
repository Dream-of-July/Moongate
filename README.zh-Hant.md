# Moongate · 月之门

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文**

通向影片、字幕與本地收藏的入口。

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-1f1f1f?style=flat-square)
![version](https://img.shields.io/badge/version-0.8.0--rc.1-1f1f1f?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-1f1f1f?style=flat-square)

貼上影片連結，選好畫質和字幕，下載即可——可選在存入本地前用 AI 摘要、翻譯或燒錄字幕。macOS 與 Windows 原生 App。

> 本產品自 0.4 版正式定名為「月之門」（Moongate）。Bundle 標識 `com.moongate.app`，安裝為 `月之门.app`。

## 運作方式

1. **解析連結** — yt-dlp 原生支援的連結（YouTube、Vimeo、Bilibili、直連 mp4 等）直接解析；其他網頁會自動偵測內嵌影片（`og:video`、`<video>` 標籤、YouTube/Vimeo iframe、`data-videoid`），列出候選。
2. **選擇** — 畫質按檔位列出，附估算大小和 HDR 標記；字幕區分真實字幕與自動產生字幕。可保持來源容器或轉檔到 MP4/MKV。
3. **AI 摘要**（可選）— 下載前先讓 AI 概述影片內容，避免下錯。
4. **下載** — yt-dlp 與 ffmpeg 完成下載、合併、可選的字幕翻譯與燒錄，以及轉檔。

## 主要功能

- **AI 影片摘要** — 選片頁一鍵概述內容（優先字幕，無字幕時用簡介）。
- **HDR / 杜比視界** — 辨識 HDR 來源；可開 HDR 開關，預設 mkv 封裝保真。
- **轉檔** — 把結果 remux 或轉檔到 MP4（H.264/H.265）或 MKV。HDR→H.265 保留 10-bit HDR；HDR→H.264 會 tonemap 成 SDR 並提示。
- **HDR 保真燒字幕** — 在 HDR 畫面上燒錄字幕（libx265 10-bit + HDR10 中繼資料透傳）。
- **字幕翻譯** — Anthropic / OpenAI 相容 API，或本機 Apple 引擎。
- **統一 AI 設定** — 翻譯與摘要共用一份預設設定，各自可跟隨預設或單獨設定。
- **按需登入** — 站點需要登入時，失敗工作提供「去登入」，開啟站點儲存 cookies 後重試。
- **自助更新** — macOS 用 Sparkle（appcast + GitHub Releases）；Windows 走獨立安裝程式。

## 安裝

### macOS

```sh
./build.sh
```

建置產物放在 `~/Library/Caches/vdl-build`——本儲存庫位於 iCloud 同步的 `~/Documents` 下，產物留在專案內會破壞程式碼簽章。App 安裝到 `/Applications/月之门.app`。

執行時媒體工具來自 Homebrew：

- `yt-dlp`（建議 ≥ 2026.06.09，舊版會被 YouTube 風控攔截）
- `ffmpeg` / `ffprobe`

App 本身僅透過 SwiftPM 引入 Sparkle 2，用於 macOS 自更新。

發布 / 更新包和本機安裝建置分開：`./make-sparkle-zip.sh` 產生 Sparkle 使用的 `Moongate-macOS-v0.8.0-rc.1.zip`，上傳到對應 GitHub Release 後，再用 `./make-appcast.sh` 寫入簽名後的 `docs/appcast.xml`。`./make-dmg.sh` 仍保留為手動拖曳安裝包。

### Windows

```sh
./build-windows.sh
```

產出 `Moongate-Windows-Setup-v0.8.0-rc.1.exe`（附 `.sha256`）。雙擊安裝、無需系統管理員權限，首次啟動自動下載 yt-dlp / ffmpeg / deno。詳見 [docs/WINDOWS.zh-Hant.md](docs/WINDOWS.zh-Hant.md)。

## AI 設定

設定頁把翻譯與摘要統一為「AI 設定」：先設定一份預設引擎，兩者預設跟隨，也可各自單獨設定。

**雲端 API** — 模型名可先留空，填好位址和憑證後點「擷取模型」從伺服器 `/v1/models` 取得真實清單：

- **Anthropic 相容** — Anthropic 官方 API、公司 Claude 閘道，或把 Anthropic 協定對應到 DeepSeek 等模型的閘道。
- **OpenAI 相容** — OpenAI Responses API。位址填 `https://api.openai.com`，憑證填 OpenAI API key。

**Apple 引擎**（僅 macOS，執行時偵測，無需位址/憑證）：

- **Apple Translation** — 系統翻譯框架，僅翻譯。
- **Apple Intelligence** — 本機 Foundation 模型，可翻譯也可摘要。
- **Apple PCC / Cloud Pro** — 受系統版本與資格限制，不可用時如實說明原因，不假裝可用。

> 摘要需要「文字產生」能力：僅 Apple Translation 的引擎不能摘要，設定裡會提示而非靜默失敗。

## 命令列

發布命令名是 `moongate-cli`；SwiftPM target 原始碼位於 `Sources/moongate-cli/`。

不開 GUI 也能跑完整流程：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli resolve <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli analyze <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli download <url> \
    --video-id <id> --format <formatID> [--subs en] [--auto-subs zh-Hans] [--dest <路徑>]
```

## 效能與佇列

- 並行上限（設定 → 效能）：預設同時下載 3、同時燒錄 2。超出的工作顯示「排隊中」；**暫停一個會把空位讓給下一個**。
- 字幕翻譯單一工作內 3 路並行請求。
- 停滯看門狗會中止卡住的下載 / 燒錄 / HLS 字幕步驟（10 / 2 / 1 分鐘）並允許重試。

## 平台支援

macOS 與 Windows 是發行中的原生 App。iOS 與 Android 仍是開發中的面，**不**屬於目前發行矩陣——不要把原始碼邊界測試或本地煙霧測試當作行動端發行就緒。

## 已知限制

- macOS 首次寫入 `~/Downloads` 會彈一次系統授權，允許即可。
- 僅下載你有權存取的公開影片；不繞過任何 DRM 或付費牆。
- 建置為 ad-hoc 簽章（無 Apple Developer Program / 公證），首次啟動可能需要手動確認。

## 授權

MIT

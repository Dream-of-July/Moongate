# Windows 版說明

[English](WINDOWS.md) · [简体中文](WINDOWS.zh-Hans.md) · **繁體中文**

Windows 版是一個獨立的原生實作，位於 `windows/`：

- **MoongateCore**（C#，.NET 10）— 以 Swift 版 `MoongateCore` + `QueueManager` 逐行為基準移植的核心庫：yt-dlp 封裝、字幕解析/清洗/翻譯、ffmpeg 燒錄、佇列與並行槽位、暫停/取消、設定與 cookies。附完整鏡像單元測試套件，在 macOS/Windows 上均可全量執行。
- **MoongateApp**（WPF）— 與 macOS 版同結構、同文案的圖形介面：貼上解析（含多連結批次入佇）、畫質/字幕選擇、中文字幕翻譯+燒錄、佇列（每工作獨立暫停/取消/重試）、設定（協定選擇、擷取模型、並行數、燒錄上限）、WebView2 站點登入、首次啟動自動下載相依元件。
- **installer/installer.nsi**（NSIS）— 安裝程式：雙擊安裝、無需系統管理員權限（裝入 `%LOCALAPPDATA%\Programs\月之门`）、開始選單/桌面捷徑、控制台可解除安裝。

> **狀態：已在 Windows on ARM 虛擬機完成基礎驗證；一般 Windows x64 仍需跑一輪回歸。** 目前已涵蓋 WPF 設定視窗初始化、win-x64 自包含發行、NSIS 安裝程式暫存目錄安裝與啟動煙霧測試。站點解析受本機代理/根憑證狀態影響；若 HTTPS 憑證鏈不受信任，App 會給出系統時間、根憑證和代理/VPN 的針對性提示，而不是泛化成普通網路波動。

## 在 macOS 上建置安裝程式

相依（一次性）：`brew install dotnet makensis`

```bash
./build-windows.sh            # 輸出 ~/Downloads/Moongate-Windows-Setup-v0.8.2.exe 和 .sha256
```

指令碼流程：核心庫單元測試（必須全綠）→ `dotnet publish` win-x64 自包含（使用者機器無需裝 .NET）→ NSIS 打包。

## Windows 使用者體驗

1. 雙擊 `Moongate-Windows-Setup-v0.8.2.exe` → 安裝到預設使用者目錄（無 UAC 彈窗）。
2. 首次啟動自動從固定版本官方來源下載 yt-dlp / ffmpeg（GyanD full 建置，含 libass）/ deno 到 `%LOCALAPPDATA%\Moongate\bin`，並校驗 SHA-256（需連網；設定裡可重新下載、重新安裝 yt-dlp）。
3. 之後與 macOS 版一致：貼上連結 → 選畫質字幕 → 下載/翻譯/燒錄，多檔案工作自動建資料夾。
4. 站點登入走 WebView2（Windows 11 內建執行階段；缺失時 App 會引導安裝）。
5. 解除安裝：設定 → 應用程式 → 月之門，或執行安裝目錄下的 `Uninstall.exe`。解除安裝時會詢問是否一併刪除使用者資料：
   - 設定與登入資料：`%APPDATA%\Moongate`（settings.json、按站點隔離的 cookies、WebView2 登入工作階段）。
   - 相依快取：`%LOCALAPPDATA%\Moongate`（yt-dlp / ffmpeg / deno）。
   兩處都保留時，重裝無需重新下載相依元件、也不必重新登入；勾選刪除則徹底清理對應資料。注意：API Token、Cookie、WebView 登入態都在 `%APPDATA%\Moongate`，只刪 `%LOCALAPPDATA%` 並不會清掉登入與憑證。

## 已知平台差異

| 能力 | macOS | Windows |
|---|---|---|
| 工作暫停/恢復 | SIGSTOP/SIGCONT 行程樹 | NtSuspendProcess/NtResumeProcess 行程樹（未實機驗證） |
| 取消 | SIGINT → 3s SIGKILL | `Process.Kill` 整樹直接終止（無優雅中斷，靠 .part 清理兜底） |
| 相依來源 | Homebrew（手動） | 首啟自動下載官方建置 |
| 憑證檔案權限 | 0600 | 無 POSIX 權限位，依賴使用者目錄 ACL |
| 燒錄中文字型 | 蘋方 | 微軟雅黑 |
| 站點登入 | WKWebView | WebView2（需 Edge WebView2 執行階段） |

> 架構（REL-WIN-003）：目前僅發行 **win-x64**（相依 yt-dlp/ffmpeg/deno 也取 x64 建置）。Windows on ARM 透過系統 x64 模擬執行，**不是原生 ARM64**；發行說明裡不應寫成原生 ARM64 支援。後續如需原生 ARM64：增加 win-arm64 publish + ARM64 的 deno/ffmpeg 資產與雙架構安裝程式。

## 舊的 Swift 條件編譯適配

`Sources/MoongateCore` 裡的 `#if os(Windows)` 分支（taskkill、PATH 定位等）仍保留，理論上可在 Windows 上用 Swift 工具鏈建置 `moongate-cli` 命令列版，但 GUI 路線已由 `windows/` 的 C# 實作取代，Swift 分支不再繼續投入。

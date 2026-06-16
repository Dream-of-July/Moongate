# 月之门 · Moongate

**月之门**：通向视频、字幕与本地收藏的入口。

> 关于名称：本产品于 0.4 版本正式定名为「月之门」，英文标识 `Moongate`。
> Bundle 标识 `com.moongate.app`，应用安装为 `月之门.app`。

当前可说明的桌面版本是 macOS / Windows 原生 App：粘贴视频链接 → 解析清晰度与字幕 → 下载、（可选）AI 总结 / 翻译 / 烧录字幕 → 保存到本地。

## 工作方式

1. **解析链接**：yt-dlp 原生支持的链接（YouTube、Vimeo、B 站、直链 mp4 等）直接解析；不支持的网页会自动嗅探页面里内嵌的视频（og:video、`<video>` 标签、YouTube/Vimeo iframe、`data-videoid` 等），列出候选让你选。
2. **选择**：清晰度按档位列出（含估算大小、HDR 可用标记），字幕区分真实字幕与自动生成字幕；可选输出格式（保持源 / 转码到 MP4/MKV）。
3. **AI 总结（可选）**：下载前用 AI 概述视频内容（优先字幕、回退简介），避免下错视频。
4. **下载**：调用系统里的 yt-dlp + ffmpeg 完成下载、合并、（可选）字幕翻译与烧录、转码。

## 主要功能

- **AI 视频总结**：选片页一键生成中文内容概述，数据源优先字幕、无字幕时用视频简介。
- **HDR / 杜比视界下载**：识别 HDR 片源，选片页可开「HDR」开关；HDR 默认 mkv 封装保真。
- **格式转码**：可把下载结果转码 / remux 到 MP4(H.264/H.265) 或 MKV；HDR 转 H.265 用 10-bit 保留 HDR，转 H.264 会 tonemap 成 SDR 并提示。
- **HDR 保真烧字幕**：在 HDR 画面上烧录中文字幕（libx265 10-bit + HDR10 元数据透传），字幕本身为 SDR 颜色。
- **字幕翻译**：Anthropic / OpenAI 兼容 API，或 Apple 本地引擎（见下）。
- **统一 AI 设置**：翻译与总结共享一份默认 AI 配置，各自可「跟随默认」或单独配置。
- **未登录引导**：检测到 YouTube / B 站等需要登录时，失败页给「去登录」按钮，弹站点登录页保存 cookies 后重试。
- **远程更新**：设置 → 更新可检查新版，从 GitHub Releases 全自动下载安装并重启。

## 依赖

仅依赖已通过 Homebrew 安装的命令行工具，无任何第三方 Swift 包：

- `yt-dlp`（建议 ≥ 2026.06.09，旧版可能被 YouTube 风控拦截）
- `ffmpeg` / `ffprobe`

## 构建安装

macOS App：

```sh
./build.sh
```

编译产物放在 `~/Library/Caches/vdl-build`（本项目位于 iCloud 同步的 `~/Documents` 下，构建产物留在项目内会破坏 codesign），App 安装到 `/Applications/月之门.app`（系统级「应用程序」目录，访达侧边栏可直接看到）。

Windows 安装包：

```sh
./build-windows.sh
```

移动端脚本和工程只用于当前开发验证，不代表发布构建；状态见下方「移动端状态」。

## 命令行测试工具

不开 GUI 也能验证全流程：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli resolve <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli analyze <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli download <url> --video-id <id> --format <formatID> [--subs en] [--auto-subs zh-Hans] [--dest 路径]
```

## AI 设置（翻译与总结）

设置页把翻译与总结统一为「AI 设置」：先配置一份默认 AI 引擎，翻译和总结默认跟随，也可各自单独配置。

云端 API 引擎（模型名可先留空，填好地址和凭证后点「拉取模型」从服务端 `/v1/models` 取真实列表再选）：

- `Anthropic-compatible`：用于 Anthropic 官方 API、公司 Claude 网关，以及公司网关把 Anthropic 协议映射到 DeepSeek 等模型的场景。
- `OpenAI-compatible`：用于 OpenAI Responses API。服务地址填 `https://api.openai.com`，凭证填 OpenAI API key。

Apple 引擎（按系统能力运行前检测，不需要填地址/凭证）：

- Apple Translation（低延迟 / 高保真）：用系统翻译框架，仅翻译。
- Apple Intelligence（本地 Foundation 模型）：可翻译，也可做总结。
- Apple PCC / Cloud Pro：受系统版本与资格限制，当前展示为不可用并说明原因，不假装可用。

> 总结需要「文本生成」能力：仅 Apple Translation 的引擎不能做总结，会在设置里提示改用云端 API 或本地 Apple Intelligence。

CLI 也可以临时覆盖：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli ping-llm --provider anthropic --base "$ANTHROPIC_BASE_URL" --model claude-haiku-4-5 --token "$ANTHROPIC_AUTH_TOKEN"
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli ping-llm --provider openai --base https://api.openai.com --model gpt-5.4 --token "$OPENAI_API_KEY"
```

## 更新

设置 → 更新可检查并安装新版：

- 来源是本仓库的 GitHub Releases（公开，匿名访问）；选取含 macOS DMG 资产、版本号高于当前的最新发布。
- 全自动：App 下载 DMG → 校验（仅接受本仓库 release 下载地址、且 bundle 标识一致）→ 挂载 → 替换 `/Applications/月之门.app` → 自动重启。
- 自下载的 DMG 不带隔离属性，ad-hoc 签名也能替换；失败时提供「去 GitHub 下载」兜底。
- 检查更新对每个发布的资产命名有要求：macOS 安装包名需包含 `mac` 且以 `.dmg` 结尾（如 `Moongate-macOS-v0.6.0.dmg`）。

## 性能与队列

- 队列并发有上限（设置 → 性能）：同时下载数默认 3、同时压制数默认 2，超出的任务显示「排队中」自动等待；**暂停一个任务会把空位让给下一个**，恢复时重新排队领取。
- 字幕翻译分块并行（单任务内 3 路并发请求）。
- 防卡死：yt-dlp 带 `--socket-timeout/--retries` 与分片并发（`-N 4`）；下载/烧录/HLS 字幕均有「无输出停滞看门狗」（10 分钟 / 2 分钟 / 1 分钟），挂死自动中止并可重试续传。

## Windows

Windows 有独立的原生实现（`windows/`：C# 核心库 + WPF 图形界面 + NSIS 安装器），
在 macOS 上执行 `./build-windows.sh` 即可产出 `月之门-Windows-Setup-v0.6.0.exe`
（同时生成 `.sha256` 校验文件；
双击安装、免管理员权限、首次启动自动下载 yt-dlp/ffmpeg/deno）。
详见 [docs/WINDOWS.md](docs/WINDOWS.md)。**GUI 尚未在真实 Windows 上运行验证。**

## 移动端状态

iOS 和 Android 仍是 **no-ship** 的开发面，不属于当前可发布支持矩阵。

- iOS WIP 位于 `Sources/MoongateMobileCore/`、`Sources/MoongateiOS/`、`Sources/MoongateiOSApp/` 和 `ios/`。`Scripts/build-ios-swiftpm.sh` 只验证 SwiftPM host/shared code，不等于真实 Xcode iOS app host；`Scripts/build-ios-xcode.sh` 与 `Scripts/run-ios-simulator-smoke.sh` 只能证明本地源码、无签名 bundle 或模拟器 smoke 的一部分。涉及 iOS 26 SDK 的 adapter 需要 Xcode/iPhoneOS 26 SDK 或真实 Xcode/device gate；这些脚本都不等于签名安装、TestFlight/App Store、真机后台下载/渲染、Apple Translation/Apple Intelligence 真实执行或完整视觉/无障碍 QA。
- Android WIP 位于 `android/`。`Scripts/build-android-local.sh` 只使用现有 `android/gradlew` 或 PATH 中已有的 `Gradle`，并强制以 `--offline` 执行；当前没有 wrapper/本机 Gradle，或离线缓存/Android SDK 组件缺失时会安全退出，不下载依赖、安装工具或访问外部服务。因此 Android APK、Gradle 单测、Compose runtime、WorkManager/通知、后台下载/渲染和真机 QA 仍未证明。
- 详细移动端门槛见 `docs/exec-plans/2026-06-12-mobile-native.md`、`docs/exec-plans/2026-06-13-ios-native-architecture.md` 和 `docs/exec-plans/2026-06-13-android-native-architecture.md`。

## 目录结构

- `Sources/MoongateCore/` — 核心：契约类型（`Models.swift`）、yt-dlp 封装（`Engine.swift`）、页面嗅探（`PageSniffer.swift`）、翻译/总结（`Translator.swift`）、字幕烧录（`Burner.swift`）、转码（`Transcoder.swift`）、更新检查（`UpdateChecker.swift`）
- `Sources/Moongate/` — SwiftUI 界面（含 `SummaryView.swift` AI 总结卡片、`UpdateService.swift` 远程更新）
- `Sources/moongate-cli/` — 命令行测试工具
- `Sources/MoongateMobileCore/` — 移动端纯契约，不依赖桌面 yt-dlp/ffmpeg/Process 实现
- `Sources/MoongateiOS/`、`Sources/MoongateiOSApp/`、`ios/` — iOS WIP shell、SwiftPM host 与本地 Xcode wrapper
- `android/` — Android WIP Gradle/Kotlin/Compose 工程
- `windows/` — Windows 版（C# 核心库 + 单测、WPF 界面、NSIS 安装脚本）

## 已知限制

- 首次写入 `~/Downloads` 时 macOS 会弹一次系统授权询问，允许即可。
- 仅下载你有权访问的公开视频；不绕过任何 DRM 或付费墙。
- 任天堂 `assets.nintendo.com` 直链视频只有原画一档（其 CDN 已禁用转码变体）。
- 移动端仍未完成发布级验证；不要把源码边界测试或本地 bundle/smoke 结果解读为移动端发布就绪。

## License

MIT

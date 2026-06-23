# Moongate · 月之门

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

通向视频、字幕与本地收藏的入口。

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-1f1f1f?style=flat-square)
![version](https://img.shields.io/badge/version-0.8.0--rc.1-1f1f1f?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-1f1f1f?style=flat-square)

粘贴视频链接，选好清晰度和字幕，下载即可——可选在存入本地前用 AI 总结、翻译或烧录字幕。macOS 与 Windows 原生 App。

> 本产品自 0.4 版正式定名为「月之门」（Moongate）。Bundle 标识 `com.moongate.app`，安装为 `月之门.app`。

## 工作方式

1. **解析链接** — yt-dlp 原生支持的链接（YouTube、Vimeo、B 站、直链 mp4 等）直接解析；其他网页会自动嗅探内嵌视频（`og:video`、`<video>` 标签、YouTube/Vimeo iframe、`data-videoid`），列出候选。
2. **选择** — 清晰度按档位列出，带估算大小和 HDR 标记；字幕区分真实字幕与自动生成字幕。可保持源容器或转码到 MP4/MKV。
3. **AI 总结**（可选）— 下载前先让 AI 概述视频内容，避免下错。
4. **下载** — yt-dlp 与 ffmpeg 完成下载、合并、可选的字幕翻译与烧录，以及转码。

## 主要功能

- **AI 视频总结** — 选片页一键概述内容（优先字幕，无字幕时用简介）。
- **HDR / 杜比视界** — 识别 HDR 片源；可开 HDR 开关，默认 mkv 封装保真。
- **转码** — 把结果 remux 或转码到 MP4（H.264/H.265）或 MKV。HDR→H.265 保留 10-bit HDR；HDR→H.264 会 tonemap 成 SDR 并提示。
- **HDR 保真烧字幕** — 在 HDR 画面上烧录字幕（libx265 10-bit + HDR10 元数据透传）。
- **字幕翻译** — Anthropic / OpenAI 兼容 API，或本地 Apple 引擎。
- **统一 AI 设置** — 翻译与总结共享一份默认配置，各自可跟随默认或单独配置。
- **按需登录** — 站点需要登录时，失败任务提供「去登录」，打开站点保存 cookies 后重试。
- **自助更新** — macOS 用 Sparkle（appcast + GitHub Releases）；Windows 走独立安装器。

## 安装

### macOS

```sh
./build.sh
```

构建产物放在 `~/Library/Caches/vdl-build`——本仓库位于 iCloud 同步的 `~/Documents` 下，产物留在项目内会破坏代码签名。App 安装到 `/Applications/月之门.app`。

运行时媒体工具来自 Homebrew：

- `yt-dlp`（建议 ≥ 2026.06.09，旧版会被 YouTube 风控拦截）
- `ffmpeg` / `ffprobe`

App 自身仅通过 SwiftPM 引入 Sparkle 2，用于 macOS 自更新。

发布 / 更新包和本地安装构建分开：`./make-sparkle-zip.sh` 生成 Sparkle 使用的 `Moongate-macOS-v0.8.0-rc.1.zip`，上传到对应 GitHub Release 后，再用 `./make-appcast.sh` 写入签名后的 `docs/appcast.xml`。`./make-dmg.sh` 仍保留为手动拖拽安装包。

### Windows

```sh
./build-windows.sh
```

产出 `Moongate-Windows-Setup-v0.8.0-rc.1.exe`（附 `.sha256`）。双击安装、无需管理员权限，首次启动自动下载 yt-dlp / ffmpeg / deno。详见 [docs/WINDOWS.zh-Hans.md](docs/WINDOWS.zh-Hans.md)。

## AI 设置

设置页把翻译与总结统一为「AI 设置」：先配置一份默认引擎，二者默认跟随，也可各自单独配置。

**云端 API** — 模型名可先留空，填好地址和凭证后点「拉取模型」从服务端 `/v1/models` 取真实列表：

- **Anthropic 兼容** — Anthropic 官方 API、公司 Claude 网关，或把 Anthropic 协议映射到 DeepSeek 等模型的网关。
- **OpenAI 兼容** — OpenAI Responses API。地址填 `https://api.openai.com`，凭证填 OpenAI API key。

**Apple 引擎**（仅 macOS，运行时检测，无需地址/凭证）：

- **Apple Translation** — 系统翻译框架，仅翻译。
- **Apple Intelligence** — 本地 Foundation 模型，可翻译也可总结。
- **Apple PCC / Cloud Pro** — 受系统版本与资格限制，不可用时如实说明原因，不假装可用。

> 总结需要「文本生成」能力：仅 Apple Translation 的引擎不能总结，设置里会提示而非静默失败。

## 命令行

发布命令名是 `moongate-cli`；SwiftPM target 源码位于 `Sources/moongate-cli/`。

不开 GUI 也能跑完整流程：

```sh
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli resolve <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli analyze <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli download <url> \
    --video-id <id> --format <formatID> [--subs en] [--auto-subs zh-Hans] [--dest <路径>]
```

## 性能与队列

- 并发上限（设置 → 性能）：默认同时下载 3、同时烧录 2。超出的任务显示「排队中」；**暂停一个会把空位让给下一个**。
- 字幕翻译单任务内 3 路并发请求。
- 停滞看门狗会中止卡住的下载 / 烧录 / HLS 字幕步骤（10 / 2 / 1 分钟）并允许重试。

## 平台支持

macOS 与 Windows 是发布中的原生 App。iOS 与 Android 仍是开发中的面，**不**属于当前发布矩阵——不要把源码边界测试或本地烟测当作移动端发布就绪。

## 已知限制

- macOS 首次写入 `~/Downloads` 会弹一次系统授权，允许即可。
- 仅下载你有权访问的公开视频；不绕过任何 DRM 或付费墙。
- 构建为 ad-hoc 签名（无 Apple Developer Program / 公证），首次启动可能需要手动确认。

## 许可

MIT

# Windows 版说明

[English](WINDOWS.md) · **简体中文** · [繁體中文](WINDOWS.zh-Hant.md)

Windows 版是一个独立的原生实现，位于 `windows/`：

- **MoongateCore**（C#，.NET 10）— 从 Swift 版 `MoongateCore` + `QueueManager` 逐行为基准移植的核心库：yt-dlp 封装、字幕解析/清洗/翻译、ffmpeg 烧录、队列与并发槽位、暂停/取消、设置与 cookies。附 470 个单元测试，在 macOS/Windows 上均可全量运行。
- **MoongateApp**（WPF）— 与 macOS 版同结构、同文案的图形界面：粘贴解析（含多链接批量入队）、画质/字幕选择、中文字幕翻译+烧录、队列（每任务独立暂停/取消/重试）、设置（协议选择、拉取模型、并发数、烧录上限）、WebView2 站点登录、首次启动自动下载依赖。
- **installer/installer.nsi**（NSIS）— 安装器：双击安装、无需管理员权限（装入 `%LOCALAPPDATA%\Programs\月之门`）、开始菜单/桌面快捷方式、控制面板可卸载。

> **状态：已在 Windows on ARM 虚拟机完成基础验证；普通 Windows x64 仍需跑一轮回归。** 当前已覆盖 WPF 设置窗口初始化、win-x64 自包含发布、NSIS 安装器临时目录安装与启动烟测。站点解析受本机代理/根证书状态影响；若 HTTPS 证书链不受信任，App 会给出系统时间、根证书和代理/VPN 的针对性提示，而不是泛化成普通网络波动。

## 在 macOS 上构建安装器

依赖（一次性）：`brew install dotnet makensis`

```bash
./build-windows.sh            # 输出 ~/Downloads/Moongate-Windows-Setup-v0.8.0-rc.1.exe 和 .sha256
```

脚本流程：核心库单测（必须全绿）→ `dotnet publish` win-x64 自包含（用户机器无需装 .NET）→ NSIS 打包。

## Windows 用户侧体验

1. 双击 `Moongate-Windows-Setup-v0.8.0-rc.1.exe` → 安装到默认用户目录（无 UAC 弹窗）。
2. 首次启动自动从固定版本官方源下载 yt-dlp / ffmpeg（GyanD full 构建，含 libass）/ deno 到 `%LOCALAPPDATA%\Moongate\bin`，并校验 SHA-256（需联网；设置里可重新下载、重新安装 yt-dlp）。
3. 之后与 macOS 版一致：粘贴链接 → 选画质字幕 → 下载/翻译/烧录，多文件任务自动建文件夹。
4. 站点登录走 WebView2（Win 11 自带运行时；缺失时 App 会引导安装）。
5. 卸载：设置 → 应用 → 月之门，或运行安装目录下的 `Uninstall.exe`。卸载时会询问是否一并删除用户数据：
   - 设置与登录数据：`%APPDATA%\Moongate`（settings.json、按站点隔离的 cookies、WebView2 登录会话）。
   - 依赖缓存：`%LOCALAPPDATA%\Moongate`（yt-dlp / ffmpeg / deno）。
   两处都保留时，重装无需重新下载依赖、也不必重新登录；勾选删除则彻底清理对应数据。注意：API Token、Cookie、WebView 登录态都在 `%APPDATA%\Moongate`，只删 `%LOCALAPPDATA%` 并不会清掉登录与凭证。

## 已知平台差异

| 能力 | macOS | Windows |
|---|---|---|
| 任务暂停/恢复 | SIGSTOP/SIGCONT 进程树 | NtSuspendProcess/NtResumeProcess 进程树（未真机验证） |
| 取消 | SIGINT → 3s SIGKILL | `Process.Kill` 整树直接终止（无优雅中断，靠 .part 清理兜底） |
| 依赖来源 | Homebrew（手动） | 首启自动下载官方构建 |
| 凭证文件权限 | 0600 | 无 POSIX 权限位，依赖用户目录 ACL |
| 烧录中文字体 | 苹方 | 微软雅黑 |
| 站点登录 | WKWebView | WebView2（需 Edge WebView2 运行时） |

> 架构（REL-WIN-003）：当前仅发布 **win-x64**（依赖 yt-dlp/ffmpeg/deno 也取 x64 构建）。Windows on ARM 通过系统 x64 模拟运行，**不是原生 ARM64**；发布说明里不应写成原生 ARM64 支持。后续如需原生 ARM64：增加 win-arm64 publish + ARM64 的 deno/ffmpeg 资产与双架构安装器。

## 旧的 Swift 条件编译适配

`Sources/MoongateCore` 里的 `#if os(Windows)` 分支（taskkill、PATH 定位等）仍保留，理论上可在 Windows 上用 Swift 工具链构建 `moongate-cli` 命令行版，但 GUI 路线已由 `windows/` 的 C# 实现取代，Swift 分支不再继续投入。

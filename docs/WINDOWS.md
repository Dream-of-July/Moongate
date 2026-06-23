# Windows build

[English](WINDOWS.md) · [简体中文](WINDOWS.zh-Hans.md) · [繁體中文](WINDOWS.zh-Hant.md)

The Windows app is a separate native implementation under `windows/`:

- **MoongateCore** (C#, .NET 10) — the core library, ported line-for-line from the Swift `MoongateCore` + `QueueManager`: yt-dlp wrapper, subtitle parse/clean/translate, ffmpeg burn-in, the queue and its concurrency slots, pause/cancel, settings and cookies. 470 unit tests, runnable in full on both macOS and Windows.
- **MoongateApp** (WPF) — a GUI matching the macOS app in structure and wording: paste-and-resolve (with multi-link batch enqueue), quality/subtitle selection, translate + burn-in, the queue (per-task pause/cancel/retry), settings (protocol choice, fetch models, concurrency, burn cap), WebView2 site login, and first-launch dependency download.
- **installer/installer.nsi** (NSIS) — installs without admin rights (into `%LOCALAPPDATA%\Programs\月之门`), adds Start-menu and desktop shortcuts, and is uninstallable from Control Panel.

> **Status: basic validation done on a Windows-on-ARM VM; plain Windows x64 still needs a regression pass.** Covered so far: WPF settings-window init, win-x64 self-contained publish, NSIS temp-directory install, and a launch smoke test. Site resolution depends on the local proxy / root-certificate state; on an untrusted HTTPS chain the app gives targeted hints about system time, root certificates, and proxy/VPN rather than a generic network error.

## Build the installer (on macOS)

One-time deps: `brew install dotnet makensis`

```bash
./build-windows.sh            # outputs ~/Downloads/Moongate-Windows-Setup-v0.8.0-rc.1.exe and .sha256
```

Flow: core-library unit tests (must all pass) → `dotnet publish` win-x64 self-contained (no .NET needed on the user's machine) → NSIS packaging.

## What Windows users get

1. Double-click `Moongate-Windows-Setup-v0.8.0-rc.1.exe` → installs to the default user directory (no UAC prompt).
2. First launch auto-downloads yt-dlp / ffmpeg (GyanD full build, includes libass) / deno from pinned official sources into `%LOCALAPPDATA%\Moongate\bin`, verifying SHA-256 (needs network; you can re-download or reinstall yt-dlp from settings).
3. From there it matches macOS: paste a link → pick quality and subtitles → download / translate / burn-in, with multi-file jobs auto-foldered.
4. Site login uses WebView2 (bundled on Windows 11; the app guides installation if it's missing).
5. Uninstall: Settings → Apps → 月之门, or run `Uninstall.exe` in the install directory. Uninstall asks whether to also delete user data:
   - Settings and login data: `%APPDATA%\Moongate` (settings.json, per-site cookies, WebView2 sessions).
   - Dependency cache: `%LOCALAPPDATA%\Moongate` (yt-dlp / ffmpeg / deno).
   Keep both and a reinstall needs no re-download and no re-login; tick to delete and the matching data is wiped. Note: API tokens, cookies, and WebView login state all live in `%APPDATA%\Moongate` — deleting only `%LOCALAPPDATA%` won't clear logins or credentials.

## Known platform differences

| Capability | macOS | Windows |
|---|---|---|
| Pause / resume | SIGSTOP/SIGCONT on the process tree | NtSuspendProcess/NtResumeProcess on the tree (not verified on hardware) |
| Cancel | SIGINT → 3s → SIGKILL | `Process.Kill` on the whole tree (no graceful interrupt; `.part` cleanup as backstop) |
| Dependencies | Homebrew (manual) | auto-download of official builds on first launch |
| Credential file perms | 0600 | no POSIX bits; relies on user-directory ACL |
| Burn-in CJK font | PingFang | Microsoft YaHei |
| Site login | WKWebView | WebView2 (needs the Edge WebView2 runtime) |

> Architecture (REL-WIN-003): only **win-x64** ships today (yt-dlp/ffmpeg/deno are taken as x64 builds too). Windows on ARM runs it through the system's x64 emulation — this is **not** native ARM64, and release notes shouldn't claim otherwise. Native ARM64 later means adding a win-arm64 publish plus ARM64 deno/ffmpeg assets and a dual-arch installer.

## Legacy Swift conditional compilation

The `#if os(Windows)` branches in `Sources/MoongateCore` (taskkill, PATH lookup, …) still exist and could, in theory, build the `moongate-cli` command line on Windows with the Swift toolchain — but the GUI path is now the C# implementation under `windows/`, and the Swift branch is no longer maintained.

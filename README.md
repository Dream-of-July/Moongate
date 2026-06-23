# Moongate · 月之门

**English** · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md)

A gateway to videos, subtitles, and your local library.

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-1f1f1f?style=flat-square)
![version](https://img.shields.io/badge/version-0.8.0--rc.1-1f1f1f?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-1f1f1f?style=flat-square)

Paste a video link, pick the quality and subtitles, then download — optionally summarizing, translating, or burning in subtitles before it lands in your library. Native apps for macOS and Windows.

> Named **月之门** (Moongate) since 0.4. Bundle id `com.moongate.app`; it installs as `月之门.app`.

## How it works

1. **Resolve** — Links yt-dlp supports (YouTube, Vimeo, Bilibili, direct mp4, …) resolve directly. For other pages, Moongate sniffs embedded video (`og:video`, `<video>` tags, YouTube/Vimeo iframes, `data-videoid`) and lists what it finds.
2. **Choose** — Quality is listed by tier with an estimated size and an HDR flag; subtitles separate real tracks from auto-generated ones. Keep the source container or transcode to MP4/MKV.
3. **Summarize** *(optional)* — Let AI describe the video before you commit, so you don't download the wrong one.
4. **Download** — yt-dlp and ffmpeg handle the download, merge, optional subtitle translation and burn-in, and transcode.

## Features

- **AI video summary** — One-click content summary on the picker page (subtitles first, video description as fallback).
- **HDR / Dolby Vision** — Detects HDR sources; an optional HDR toggle, mkv by default to preserve fidelity.
- **Transcode** — Remux or transcode to MP4 (H.264/H.265) or MKV. HDR→H.265 keeps 10-bit HDR; HDR→H.264 tonemaps to SDR with a heads-up.
- **HDR-safe burn-in** — Burns subtitles over HDR footage (libx265 10-bit + HDR10 metadata passthrough).
- **Subtitle translation** — Anthropic- / OpenAI-compatible APIs, or on-device Apple engines.
- **Unified AI settings** — Translation and summary share one default config; each can follow the default or be set separately.
- **Sign in only when needed** — When a site requires login, the failed task offers a *Sign in* button, opens the site, saves cookies, and retries.
- **Self-update** — Sparkle on macOS (appcast + GitHub Releases); a dedicated installer flow on Windows.

## Install

### macOS

```sh
./build.sh
```

Build artifacts go to `~/Library/Caches/vdl-build` — the repo lives under iCloud-synced `~/Documents`, where in-tree artifacts would break code signing. The app installs to `/Applications/月之门.app`.

Runtime media tools come from Homebrew:

- `yt-dlp` (≥ 2026.06.09 recommended; older builds get throttled by YouTube)
- `ffmpeg` / `ffprobe`

The app itself pulls only Sparkle 2 via SwiftPM, for macOS self-update.

### Windows

```sh
./build-windows.sh
```

Produces `Moongate-Windows-Setup-v0.8.0-rc.1.exe` (plus a `.sha256`). Double-click to install — no admin rights — and the first launch auto-downloads yt-dlp / ffmpeg / deno. Details in [docs/WINDOWS.md](docs/WINDOWS.md).

## AI setup

Settings folds translation and summary into one **AI settings** page: configure a default engine once; both follow it by default, or each can be configured on its own.

**Cloud APIs** — leave the model blank, then *Fetch models* from the server's `/v1/models` once the URL and credential are in:

- **Anthropic-compatible** — the Anthropic API, corporate Claude gateways, or gateways that map the Anthropic protocol onto DeepSeek and others.
- **OpenAI-compatible** — the OpenAI Responses API. Use `https://api.openai.com` with an OpenAI key.

**Apple engines** (macOS only, detected at runtime, no URL or credential):

- **Apple Translation** — the system framework; translation only.
- **Apple Intelligence** — the on-device Foundation model; translates and summarizes.
- **Apple PCC / Cloud Pro** — gated by OS version and eligibility; shown as unavailable with a reason rather than faked.

> Summary needs text generation. An Apple Translation-only engine can't summarize, and the settings page says so instead of failing silently.

## CLI

Run the whole flow without the GUI:

```sh
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli resolve <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli analyze <url>
swift run --scratch-path ~/Library/Caches/vdl-build moongate-cli download <url> \
    --video-id <id> --format <formatID> [--subs en] [--auto-subs zh-Hans] [--dest <path>]
```

## Performance & queue

- Concurrency caps (Settings → Performance): 3 downloads and 2 burns by default. Tasks over the cap wait as *Queued*; **pausing one hands its slot to the next**.
- Subtitle translation runs three requests in parallel per task.
- Stall watchdogs abort stuck download / burn / HLS-subtitle steps (10 / 2 / 1 min) and let you retry.

## Platform support

macOS and Windows are the shipping native apps. iOS and Android are work-in-progress and **not** part of the shipping matrix yet — don't read source-level boundary tests or local smoke runs as mobile release readiness.

## Known limitations

- macOS prompts once for permission to write to `~/Downloads` — allow it and you're set.
- Downloads only public videos you have access to; it bypasses no DRM or paywall.
- Builds are ad-hoc signed (no Apple Developer Program / notarization), so the first launch may need a manual confirmation.

## License

MIT

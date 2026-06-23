# Changelog

[English](CHANGELOG.md) · [简体中文](CHANGELOG.zh-Hans.md) · [繁體中文](CHANGELOG.zh-Hant.md)

This project follows semantic versioning (major.minor.patch).

## 0.7.6

0.7.6 is a cross-platform subtitle segmentation and timing release, focused on line breaks, display duration, and inter-cue continuity for English and Japanese subtitles across YouTube auto-captions, manual subtitles, and the pre-translation cleanup. macOS and Windows keep their core logic in lockstep.

### Fixes / improvements

- **English segmentation reads more like real subtitles**: new weak-boundary detection avoids breaking connectives like `the / and / which / to` at hard-to-read spots; short feedback lines, post-colon/semicolon handoffs, and long-pause display durations are steadier.
- **Steadier Japanese (space-less) subtitles**: character-level timing for Japanese/CJK is handled on its own, reducing auto-caption scroll carry, dense short cues, and multi-line manual subtitles getting split into blink cues or over-long trailing.
- **Preserve VTT word-level timestamps**: auto-caption downloads keep inline VTT word timestamps, and cleanup uses source-segment times instead of relying only on the whole-cue window.
- **Cross-platform shared segmenter**: a new Swift/C# `SubtitleTimingPlanner` on both sides centralizes readable-duration, weak-boundary, short-sentence, and source-anchored timing rules.
- **Evaluation tooling**: new `tools/subtitle_timing_eval/` checks segmentation timing against public samples, ASR/VTT references, and offline metrics; output goes to ignored artifacts by default.
- **Clearer task progress**: the queue surfaces per-task progress and ETA, normalizing VTT→SRT before burn-in or output.

### Tests

- Added Swift/Windows segmenter, VTT parsing, subtitle cleanup, and queue-behavior regression tests.
- Added Python offline-eval unit tests covering VTT word timing, weak boundaries, manifest/status/runbook, and the translated-subtitle overlap gate.

## 0.7.5

0.7.5 is a Windows-only hotfix, mainly fixing a `RangeBase.Value` / `Run.Text` initialization exception thrown when the Windows settings window opened due to WPF read-only bindings, plus basic build / installer / launch-smoke validation on a Windows-on-ARM VM. The latest macOS release surface stays at 0.7.3.

### Fixes / improvements

- **Windows settings window no longer crashes on the update bindings**: all `Updater.*` bindings in the update area now bind one-way explicitly, so WPF won't try to write back read-only state properties.
- **Update text no longer triggers a `Run.Text` exception**: the update area drops inline `Run` text bindings for plain `TextBlock` composition; clicking "Settings" should no longer raise `Set property 'System.Windows.Documents.Run.Text' threw an exception`.
- **Progress-value guards**: download, resolve, and queue UI progress now filter out `NaN`, infinity, and out-of-range values so WPF `RangeBase` controls never receive illegal values.
- **More accurate certificate-error hints**: when yt-dlp / the system network stack fails because a proxy or system root certificate isn't trusted, the message tells you to check Windows system time, root certificates, and proxy/VPN certificates instead of blaming a generic network blip.
- **Windows release-pipeline validation**: verified the `win-x64` self-contained publish, NSIS installer build, temp-directory install, and launch smoke test on a Windows-on-ARM VM; still running via x64 emulation, so no native ARM64 claim.

### Tests

- Windows `dotnet test windows/Moongate.Win.sln` covers 414 core tests plus 1 WPF settings-window init smoke test.

## 0.7.3

0.7.3 is a **release-hardening** version: following an external code review, it systematically tightened pre-release risk points around updates, dependencies, login credentials, cookie isolation, and settings reliability, and fixed a download progress bar stuck at 100%.

> Note: every change here passed unit tests and compilation, but has **not yet been end-to-end verified on real Windows/macOS machines** (install, in-place update, uninstall, WebView2, login, high-DPI, …); a stable release still needs on-hardware verification. See `docs/audit-progress.md`.

### Security

- **API tokens no longer hit disk in plaintext**: stored encrypted via Keychain on macOS and DPAPI on Windows; plaintext tokens in legacy settings.json migrate transactionally on first launch (write to secure storage first, erase plaintext only on success, lose nothing on failure).
- **Per-site cookie isolation**: login cookies are now exported and filtered per site (YouTube / Bilibili), and downloads pick the matching jar by URL host so they don't cross-contaminate; the old global cookies.txt migrates automatically.
- **Dependency integrity checks**: Windows managed dependencies now download at versions pinned to the app and verify SHA-256 before install, instead of tracking upstream `latest`.
- **More honest login clearing**: when WebView2 data can't be fully removed, Windows "clear all logins" honestly reports "partially cleared" and finishes on next launch.

### Fixes / improvements

- **Download progress no longer stuck at 100%**: fixed DASH split video/audio downloads freezing the bar permanently after the video stream hit 100% (the audio download + merge looked like "nothing is downloading").
- **Windows update-install race**: check the queue before updating, pass the PID to NSIS so old processes exit before overwrite, dedicated exit state, temp-dir cleanup; SemVer handles pre-releases correctly.
- **Cancelable dependency window**: the first dependency download is cancelable, the window is closable, and it shows real byte/speed progress; "re-download dependencies" now downloads-then-swaps (a failure won't break the working environment).
- **Settings reliability**: a corrupt settings file is backed up with a prompt rather than silently reset to defaults; settings stays open without losing a draft if a login/dependency jump fails to save.
- **macOS no longer manages global Homebrew**: removed the in-app "uninstall Homebrew dependencies" to avoid removing packages you installed for other projects; binary lookup supports a custom HOMEBREW_PREFIX.
- **Windows paths / parsing**: folder names avoid reserved device names (CON/NUL/COM1…); multi-link extraction is unified around http(s) anchors; remembers your last download options.
- **Multilingual installer**: the NSIS installer supports Simplified/English/Traditional Chinese, the desktop shortcut is now optional, and uninstall can optionally delete user data (settings/credentials/cookies + dependency cache).

### Tests

- macOS `swift test` and Windows `dotnet test windows/Moongate.Win.sln` both green; added unit tests covering credential migration, cookie isolation, dependency health/verification, SemVer, progress merging, path sanitization, and more.

## 0.7.2

0.7.2 is a correctness release for subtitle-translation quality and release-surface consistency, focused on auto-generated subtitles' timing, segmentation, and noisy text, so post-download subtitle translation has fewer cross-sentence mistranslations, duplicate tags, and hard-to-trace fallback behavior.

### Added

- **ASR subtitle re-segmentation**: a configurable re-segmentation pre-pass for auto-generated subtitles merges over-short, over-fragmented, or clearly mis-broken cues into more translation-friendly semantic segments, reducing context loss from word-by-word subtitles.
- **Steadier translation-fallback logging**: when ASR re-segmentation or Enhanced mode is unavailable, the macOS and Windows cores keep clearer fallback logs, making it easier to tell whether settings, the input subtitles, or the model response changed the result.

### Fixes / improvements

- **Stricter subtitle cleanup**: fixed escaping and tag handling in SRT cleanup, lowering the chance of HTML/ASS tags, repeated noise, and malformed cues reaching the translation prompt.
- **More conservative ASR detection**: hardened the auto-caption heuristic to avoid mistaking normal manual subtitles for ASR ones and over-segmenting them.
- **Copy de-noising**: renamed "smart translation prompts" to "Enhanced mode," closer to what the toggle actually does, and avoiding UI that explains the model's internals.
- **Release surface pinned to 0.7.2**: macOS/Windows default build version, installer naming, GitHub Actions defaults, README, Windows docs, and release-surface tests all updated to 0.7.2.

### Tests

- Added/updated macOS and Windows tests for subtitle cleanup, ASR re-segmentation, translation-settings migration, fallback paths, and localized copy.
- Updated release-surface tests covering the macOS build script, Sparkle ZIP/appcast scripts, the Windows installer, GitHub Actions default version, and doc artifact names.

## 0.7.0

This version completes the desktop 0.7 multilingual and first-run iteration: macOS / Windows are usable for English, Simplified Chinese, and Traditional Chinese users, the translation target language can be chosen independently, and the no-API path is clearer.

### Added

- **Trilingual UI and settings**: macOS and Windows support English / Simplified Chinese / Traditional Chinese UI languages, switchable instantly in settings; the translation target language is independent of the UI language and can be Simplified Chinese, Traditional Chinese, or English.
- **Better onboarding**: first launch lets you choose the app language and subtitle target; you can skip API setup and use Moongate as a plain video downloader. macOS additionally guides the local Apple Translation path; Windows doesn't make a cloud API a launch blocker by default.
- **Smart translation-prompt toggle**: a new independent toggle. When on, subtitle translation first analyzes the content and picks a more suitable prompt for plain content vs. songs/lyrics; the song case weights imagery, rhythm, and singability more.
- **More site recognition**: TikTok, Douyin, Xiaohongshu, and common short-link domains prefer yt-dlp's native extraction path, keeping honest hints about login, throttling, region, or platform limits on failure rather than masquerading as generic page sniffing.

### Fixes / improvements

- macOS main window, settings, queue, login, summary, dependency, update, and close-confirmation copy now use runtime localization.
- Windows WPF UI and core download / resolve / queue / transcode / burn-in / dependency / update error copy fill in the Traditional Chinese and English paths.
- **macOS self-update moved to Sparkle**: in-app updates no longer download a DMG/PKG and handle install themselves; they now use the native Sparkle 2 update window, discover updates from a GitHub Pages appcast, download `Moongate-macOS-v0.7.0.zip` from a GitHub Release, and replace the app after Sparkle EdDSA signature verification.
- **Developer-ID-free, low-cost path**: added Sparkle ZIP and appcast release scripts; the private key lives in the local Keychain and the repo holds only the public key. This solves in-app update and tamper protection without pretending to be a Gatekeeper-grade official release.
- **Unfinished-queue protection**: with unfinished tasks in the queue, the settings page blocks a manual update check first, prompting you to finish or cancel tasks, so the update restart doesn't fight the download/burn flow.
- **Release-asset boundary adjustment**: in-app auto-update assets become `Moongate-macOS-v0.7.0.zip` + `docs/appcast.xml`; the DMG stays only as a manual drag-install fallback, and the PKG is reserved for a future Developer ID Installer path.
- Release scripts, the Windows installer, GitHub Actions defaults, and doc examples updated to 0.7.0.

### Tests

- Added macOS `Localizer`, settings, onboarding, translation-target, smart-prompt, site-recognition, and release-boundary tests.
- Updated macOS update-boundary tests: confirm the Sparkle dependency, Info.plist config, ZIP/appcast scripts, and public-key file exist, and reject falling back to a homegrown PKG/DMG installer.
- Updated settings-page boundary tests: the update area is now the native Sparkle check entry, and blocks update checks while the queue is unfinished.
- Windows core-library test count updated to 271, covering trilingual core copy, settings migration, onboarding, translation target, smart prompts, and the release surface.

## 0.6.1

Fixes the macOS auto-update "downloads but won't install" problem.

### Added

- **Remember last download options**: your "subtitle handling / subtitle language / output format / HDR" choices are remembered, and the next download reuses them (e.g. "English subtitles – translate and burn in"). Subtitles are remembered by language code and auto-matched against what's actually available on the next video.

### Fixes / improvements

- **Fixed silent macOS self-update failure**: after downloading a new DMG, the old version unmounted the disk image too early on exit, so when the replace script copied the new app from the image, the source was already gone (`ditto: Cannot get the real path for source`), `/Applications/月之门.app` was never replaced, and a restart still ran the old version. The image is now unmounted by the replace script after the copy finishes, so updates complete reliably.
  - Note: this defect lives in the old version's own updater, so installed 0.5.0 / 0.6.0 still need a one-time manual download of this version; from 0.6.1 on, later versions auto-update normally.
- **Clear error when the self-update install directory isn't writable**: the replace script runs after the app exits, so a failure can't report back to the UI. It now checks the install directory's writability before exiting (e.g. /Applications on a non-admin account) and, if not writable, tells you to "run as admin or download manually from GitHub" instead of failing silently.
- **Fixed OpenAI-compatible "test connection / fetch models" errors**: test-connection previously always hit OpenAI's private `/v1/responses` endpoint, while most "OpenAI-compatible" services (Azure, DeepSeek, OpenRouter, Ollama, local inference, …) implement only `/v1/chat/completions`, so config saved but the test failed. The OpenAI protocol now uses the common `/v1/chat/completions`; fetching models also no longer sends Anthropic-specific headers to non-Anthropic services, avoiding strict gateways rejecting unknown headers. (Fixed on desktop and mobile.)

### Tests

- Updated the macOS self-update script-generation test: verify the image is unmounted after the copy, and by the script.
- Passed a full SwiftPM build and UpdateChecker tests; reproduced and verified the fix on a real UDZO image (Chinese volume name).

## 0.6.0

This version continues burn-in / transcode performance work: where the hardware path is safe to use, it leans on the system's best media engine, and it fills in progress feedback for the post-download transcode stage.

### Added

- **Hardware-acceleration planner**: the macOS transcode path adds VideoToolbox input hardware-acceleration planning; the Windows transcode path adds NVENC / Intel Quick Sync / AMD AMF input hardware-acceleration planning. Filter-free transcoding can hand decode and encode more fully to the hardware media chain.
- **Transcode percentage**: the post-download transcode stage now shows "Transcoding X%," or "Transcoding…" when progress is unknown, so it's not lumped in with generic post-processing.

### Fixes / improvements

- **Burn-in / transcode copy de-noising**: settings, docs, and localized hints no longer explicitly flag CPU fallback, only noting that compatibility issues may take longer than expected.
- **Clearer compatibility path**: paths that must go through software filters (HDR→H.264 tonemapping, etc.) keep the compatibility hint while avoiding wrongly injecting hardware input-acceleration parameters.
- **Windows queue-state alignment**: Windows fills in the post-download processing types so the transcode stage shows dedicated progress text just like macOS.
- **Fixed update-check error copy**: GitHub rate-limiting, network failures, and other update-check errors no longer show as "failed to resolve video info."

### Tests

- Added macOS / Windows tests for transcode planning, hardware input-acceleration parameters, HDR compatibility paths, transcode progress UI, localized copy, and update-check error boundaries.
- Fully verified via the SwiftPM full test suite, the Windows core-library full test suite, the Windows app build, and a release-surface string check.

## 0.5.0

This version focuses on burn-in / transcode performance and quality: hand encoding to Apple Silicon's hardware media engine (VideoToolbox), and fix a batch of burn-in, settings, and interaction issues.

### Added

- **Hardware encode acceleration (VideoToolbox)**: burn-in and transcode can go to the Mac's hardware media engine — faster, more power-efficient 4K encoding. Settings → "Burn-in & transcode" adds three "encoding" modes: Auto (hardware first, recommended) / Hardware / Software (highest quality, slower); source-file or system compatibility issues may take longer than expected. HDR sources go through hardware `hevc_videotoolbox` main10 with HDR10 color metadata passthrough (mastering-display / max-cll preserved), matching the software libx265 path's quality metadata.
- **Adaptive burn-in concurrency**: under the hardware backend, one extra burn-in runs in parallel beyond the configured value (cap 4) for higher throughput; the compatibility path keeps the original value to avoid tasks dragging each other down.
- **Selectable burn-in encoding**: Settings → "Burn-in & transcode" adds "burn-in encoding": follow source (HEVC source stays HEVC, keeps HDR, smaller) / always H.264 (best compatibility, plays almost everywhere).

### Fixes / improvements

- **Fixed missing transcode progress bar**: the post-download transcode stage now shows live progress (it previously lacked `-progress` output, so the bar didn't move).
- **Fixed HEVC-source subtitle burn-in being downgraded to H.264**: with follow-source encoding, a HEVC 4K source stays HEVC after burn-in instead of quietly dropping to H.264 and losing bitrate/resolution.
- **Fixed "scale to 1080p" off not taking effect**: turning the toggle off now persists (previously `maxBurnHeight` being empty was omitted on serialization and re-read as the 1080 default, so "off" wasn't saved and it still encoded to 1080).
- **AI-summary highlight changed to a wave effect**: the in-progress "understanding the video" text now uses a continuous per-character wave highlight (a crest rolls across the text, characters lift and brighten, then a calm gap before it swells again), replacing the previous single linear sweep; respects "reduce motion."
- **"Configure separately" for AI translation / summary gains fetch-models and test-connection**: like the main "AI settings," you can enter URL + credential, fetch the server's real model list, and test the connection.

### Tests

- Added an encoder-selection matrix unit test (hardware / software × source codec × HDR × force-H.264, including hardware-unavailable fallback), transcode hardware paths and HDR main10 metadata, encode-backend and burn-in-encoding persistence, effective concurrency under the hardware backend, and more.
- ffmpeg end-to-end verified three key paths: SDR HEVC keep HEVC, force H.264, and HDR hardware main10 preserving PQ metadata.

## 0.4.0

The product is officially named **Moongate** in this version. This is a major update centered on macOS AI capabilities, HDR support, and self-update.

### Added

- **Product name "月之门"**: the app name, window title, Dock, About panel, and installer are all "月之门"; bundle id `com.moongate.app`, installed as `/Applications/月之门.app`, with a Tahoe layered icon aligned.
- **AI video summary**: one-click AI summary of the video on the picker page (subtitles first, video description as fallback) so you can confirm before downloading; an Apple Intelligence-style flowing-border highlight while computing, with a reveal animation when done.
- **HDR / Dolby Vision download**: resolution detects the HDR source per quality tier; the picker page offers an "HDR" toggle; HDR defaults to mkv to preserve fidelity.
- **Post-download transcode / remux**: the picker page offers an output format (keep source / MP4 H.264 / MP4 H.265 / MKV). Same codec with a new container remuxes (lossless, seconds); cross-codec transcodes; HDR→H.265 keeps HDR with libx265 10-bit, HDR→H.264 tonemaps to SDR with a heads-up.
- **HDR-safe subtitle burn-in**: burns subtitles over HDR footage (libx265 10-bit + HDR10 metadata passthrough), subtitles in SDR color; falls back to SDR tonemapping when libx265 is unavailable.
- **Unified "AI settings"**: translation and summary share one default AI config; each can "follow the default" or be configured separately; adds Apple Translation (low-latency/high-fidelity), on-device Apple Intelligence, and PCC/Cloud Pro engines (availability judged honestly by system capability).
- **Sign-in guidance**: when a YouTube / Bilibili login requirement causes a failure, the failure page offers a "Sign in" button, opens the site login to save cookies, and retries.
- **Remote update**: Settings → Update can check and fully auto-download/install a new version (from GitHub Releases, verifying the download URL and bundle id, auto-restarting after replacement), with a "download from GitHub" fallback on failure.
- **Dependency management upgrade**: the dependency area collapses (one line when all ready, auto-expands when something's missing), adds "delete dependency" (red warning + confirmation), and shows per-item spinner→green-check progress for install/uninstall.

### Fixes / improvements

- Fixed a guaranteed crash on "open dependency setup": the dependency health check (which spawns an ffmpeg child process) moved out of the SwiftUI view init path to async background execution, avoiding an AttributeGraph re-entrancy crash.
- Fixed login loss caused by the rename (video downloader → Moongate): cookie migration is decoupled from settings reading.
- Fixed the Tahoe layered icon breaking after the rename (actool asset name aligned with `CFBundleIconName`).
- bilibili-style HTTP 412 throttling failures no longer misreport as "page load failed," giving an honest throttling hint (wait / switch network / don't repeatedly sign in); throttling is no longer mistaken for "needs login."
- The post-download stage shows the specific step (merging audio/video / transcoding / extracting audio / converting subtitles) instead of a generic "processing."
- The settings panel's "AI translation / AI summary" becomes a simple "follow default / configure separately" choice.
- The main-screen paste button is now a capsule style.
- The install target moved from `~/Applications` to `/Applications` (directly visible in Finder's "Applications").
- VoiceOver: the source-language picker and reset button in the Apple-engine status panel can be focused independently again.
- Entering the dependency wizard from settings no longer loses an unsaved draft.

### Tests

- Added multiple unit / boundary tests: AI-settings migration and effective config, summary-engine capability guards, HDR resolution and picker, transcode planning, HDR burn-in parameters, login detection, update-version comparison and download-safety checks, and more.

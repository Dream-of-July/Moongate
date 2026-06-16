# 0.6 Desktop Hardware Acceleration

## Background and Product Intent
0.6 focuses on making desktop transcode and burn-in work use the best available system media/GPU path where it is safe. The product promise is hardware-first performance, with compatibility handling when a source file, driver, encoder, or ffmpeg filter graph cannot stay fully on the hardware path.

User-facing copy should not expose low-level implementation labels. When compatibility handling is needed, copy should say that actual runtime may be longer than expected.

## Current Understanding
- macOS desktop uses Swift `MoongateCore` plus SwiftUI queue/settings surfaces.
- Windows desktop uses `windows/MoongateCore` plus WPF view models/resources.
- Existing burn-in uses libass subtitles, which is still a necessary CPU-rendered filter in ffmpeg. The safe implementation keeps subtitle render compatible and still prefers hardware encode around it.
- Current transcode progress already comes from ffmpeg `-progress pipe:1`; the queue UI previously hid post-download transcode progress behind generic "processing" copy.

## Goals and Non-Goals
Goals:
- Add a shared hardware acceleration report model for transcode plans.
- Use safe input hardware acceleration on filterless hardware transcode paths.
- Keep CPU-only filter paths compatible instead of forcing hardware frames into filters that cannot accept them.
- Show transcode percentage in macOS and Windows queue rows.
- Replace fallback/CPU-facing copy with compatibility-time copy.

Non-goals:
- Do not claim every filter is GPU-backed.
- Do not replace libass subtitle rendering.
- Do not add new production dependencies.
- Do not expand this slice to iOS/Android.

## Implementation Notes
- `PipelineAccelerationReport` records hardware family, decode/filter/encode usage, and optional compatibility notice.
- macOS `Transcoder.plan` adds `-hwaccel videotoolbox` only when the selected path uses VideoToolbox encode and does not require CPU video filters.
- Windows `Transcoder.BuildPlan` maps NVENC/QSV/AMF encoders to CUDA/QSV/D3D11VA input acceleration where safe.
- HDR -> H.264 tonemap paths keep the compatible CPU filter graph and carry the compatibility notice.
- Queue state now distinguishes generic post-download processing from actual transcoding, so UI can render `转码中 X%` / `Transcoding X%`.

## Verification
- Red tests were added first for hardware plan reports, safe hwaccel insertion, compatibility copy, and transcode percent display.
- Passed: `swift test --scratch-path /private/tmp/vdl-green-hwaccel --filter 'HDRSupportTests|MacOSQueueBoundaryTests'`.
- Passed: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~TranscoderPlanTests|FullyQualifiedName~WindowsSettingsSurfaceTests"`.
- Passed: `swift test --scratch-path /private/tmp/vdl-full-hwaccel` (549 tests, 0 failures).
- Passed: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj` (241 tests, 0 failures after the update-copy regression test was added).
- Passed: `dotnet build windows/MoongateApp/MoongateApp.csproj` (0 errors; NuGet vulnerability-data warning only when network access was restricted).
- Passed: `git diff --check`.

## Progress Log
- 2026-06-16: Implemented the 0.6 desktop hardware acceleration slice across macOS and Windows, including safe hardware input acceleration on filterless transcode paths, typed post-download transcoding progress, compatibility-time copy, and focused plus full validation.
- 2026-06-16: Prepared release surfaces for 0.6.0 by updating macOS/Windows packaging versions, Windows release workflow defaults, release-facing documentation, release surface tests, and changelog notes.
- 2026-06-16: Fixed a release-blocking update-settings copy bug found during local QA: update-check failures now use update-specific errors instead of video-analysis errors on both macOS and Windows.

## Risks and Follow-Up
- ffmpeg hardware filter support varies by build and driver. The current slice only injects hardware input acceleration on safe filterless paths.
- A later slice can add measured hardware scale/tonemap variants per family after validating real ffmpeg builds on Apple Silicon, NVIDIA, Intel, and AMD machines.
- Full burn-in GPU filtering remains limited by libass subtitle rendering.

# Japanese Lyrics Whisper Smoke

## Background And Product Intent

Local Whisper ASR on Japanese songs can produce defects that are painful in real viewing: late lyric onset, stray kana, malformed word splits, or repeated hallucinated lyric islands. The user wants this tuned against real J-pop MV / live samples rather than only synthetic fixtures.

## Current Understanding

- Production local-ASR cue planning flows through `Sources/MoongateCore/ASR.swift`.
- Windows parity lives in `windows/MoongateCore/Asr.cs`.
- Contract tests live in `Tests/MoongateCoreTests/ASRContractsTests.swift` and `windows/MoongateCore.Tests/AsrContractsTests.cs`.
- `moongate-cli local-asr-srt` reads whisper word JSON and calls the same Swift mapper used by the app.
- Media and ASR artifacts must stay under ignored `artifacts/subtitle_timing_eval/`.

## Goals

- Run a reproducible 20-sample Japanese song smoke through the whisper.cpp local-ASR path.
- Manually inspect the generated SRTs and risk windows.
- Convert reproducible defects into narrow Swift/C# fixtures before changing the timing planner.
- Preserve legitimate repeated choruses while suppressing malformed repetition loops.

## Non-Goals

- Do not add WhisperX, new models, or production dependencies.
- Do not commit downloaded audio, video, lyrics, or generated SRT artifacts.
- Do not solve Whisper recognition errors that have no reliable timing/text post-processing signal.

## Plan

1. Add a smoke runner that resolves/downloads audio snippets, runs `subtitle_timing_eval.cli asr --engine whisper-cpp`, runs `moongate-cli local-asr-srt`, and writes a Markdown review.
2. Start with the existing Japanese lyric loop fix and evaluate it across 20 MV/live samples.
3. Read every generated SRT review section and classify failures:
   - hallucination loop,
   - standalone residual,
   - unnatural leading particle/tail,
   - overly long sparse cue,
   - late/early timing caused by segment start,
   - legitimate repetition that must be preserved.
4. Only tune when a defect has a stable structural signature.
5. Mirror any algorithm changes in Swift and C# and add contract tests.

## Validation

- `python3 -m py_compile tools/subtitle_timing_eval/run_japanese_lyrics_whisper_smoke.py`
- Smoke runner on at least a small subset before the full 20.
- Full 20 smoke when network and YouTube access allow.
- `swift test --scratch-path .build/codex-jp-lyrics-smoke --filter ASRContractsTests`
- `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter AsrContractsTests --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
- `git diff --check`

## Risks And Rollback

- YouTube may throttle or block some samples. The runner records failures and continues.
- Official lyric repetition can look superficially similar to hallucination. Suppression must require malformed signals, not repetition alone.
- Japanese lyric tuning must be scoped to `.japaneseLyrics` unless a later sample proves a broader rule is safe.

Rollback is a normal git revert of the smoke script plus ASR planner/test changes; artifacts remain ignored.

## Progress

- 2026-06-24: Started the 20-sample J-pop/live Whisper smoke cycle.
- 2026-06-24: Added `tools/subtitle_timing_eval/run_japanese_lyrics_whisper_smoke.py` and ran the 20-sample local-ASR path.
- 2026-06-24: Tuned Japanese lyrics post-processing for dense hallucination loops, intro hallucinations, leading one-character lyric prefixes, terminal platform thanks, intro `B/GM` music hallucinations, and live/J-pop fallback detection.
- 2026-06-24: Final smoke status: 19/20 samples produced SRT; the remaining Aimer sample was filtered to empty because Whisper output was only unusable credit/platform hallucination. Final scan found no remaining `ご視聴ありがとうございました`, credit markers, or `B/GM` intro artifacts in generated SRTs.
- 2026-06-24: Validation passed: Swift `ASRContractsTests` 80 tests, Windows `.NET` `AsrContractsTests` 79 tests, Python eval tests 123 tests, script `py_compile`, and `git diff --check`.

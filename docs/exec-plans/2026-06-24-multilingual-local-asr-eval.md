# Multilingual Local-ASR Eval And Timing Tuning

## Background And Product Intent

After the 0.8.1 Beta local install, the next quality target is to keep improving subtitle timing across content types and mainstream languages without overfitting to Japanese songs. The product goal is still pragmatic: make local-ASR subtitles feel human enough for common YouTube viewing scenarios, while accepting that Whisper recognition errors themselves are outside deterministic retiming.

## Current Understanding

- Main local-ASR timing code lives in `Sources/MoongateCore/ASR.swift` and is mirrored in `windows/MoongateCore/Asr.cs`.
- The broad manifest lives in `tools/subtitle_timing_eval/samples.json`.
- The manifest currently covers `en`, `zh`, `yue`, `ja`, `ko`, `es`, `fr`, `it`, plus translated subtitle scenarios, with extra `pt` and `de` evidence.
- Japanese J-pop/live smoke now has a dedicated runner: `tools/subtitle_timing_eval/run_japanese_lyrics_whisper_smoke.py`.
- User-visible subtitle quality now has a dedicated runner: `tools/subtitle_timing_eval/run_viewing_quality_suite.py`.
  Its `songs30` suite fixes a 30-song matrix across J-pop MV/live, anime/game songs, K-pop, Chinese/Cantonese songs,
  English songs, and Romance-language songs.
- Artifacts remain ignored under `artifacts/subtitle_timing_eval/`.

## Goals

- Expand quality checks beyond Japanese lyrics into speech, animation, tutorials, news/explainers, short social clips, and music across mainstream languages.
- Fix only issue families that show up across samples/languages or have a very stable structural signature.
- Preserve macOS/Windows parity for every timing rule.
- Keep release-test packaging separate from ongoing tuning; the installed `0.8.1 Beta` should remain a stable user-test point.

## Non-Goals

- Do not introduce WhisperX, new ASR models, or production dependencies in this pass.
- Do not tune for a single video unless the failure signature is reusable.
- Do not treat missing/blocked eval artifacts as algorithm regressions.

## Current Baseline

Generated on 2026-06-24:

- `PYTHONPATH=tools/subtitle_timing_eval python3 -m subtitle_timing_eval.cli status --manifest tools/subtitle_timing_eval/samples.json --artifacts artifacts/subtitle_timing_eval --out artifacts/subtitle_timing_eval/status.current.json`
- `PYTHONPATH=tools/subtitle_timing_eval python3 -m subtitle_timing_eval.cli iteration-report --manifest tools/subtitle_timing_eval/samples.json --artifacts artifacts/subtitle_timing_eval --out artifacts/subtitle_timing_eval/iteration.current.json`

Status summary:

- `comparison_count`: 28 / `sample_count`: 34.
- Missing samples: `chinese_animation_zh`, `koupen_chan_umeboshi_ja`, `music_lyrics_japanese`.
- Blocked samples: `mtedx_portuguese_weakness_pt`, `music_lyrics_chinese`, `sebasi_praise_method_ko`, `tedx_kwangwoon_only_one_ko`.
- Insufficient-window samples: `tedx_yonsei_visual_language_ko`, `the_do_show_jimmy_o_yang_yue`.
- Failing samples currently include `ted_school_creativity_en`, `tedx_nagoyau_happiness_ja`, `sebasi_english_self_study_ko`, `cantonese_uk_yue`, `french_talk_public_fr`, `italian_talk_public_it`, `mtedx_german_flight_de`, and `portuguese_tedx_lages_pt`.
- Top algorithm issue families after evidence gaps: `weak_boundary`, `early_cutoff`, `accepted_ratio`, `start_onset_drift`, `end_offset_drift`, and `long_idle_hold`.

## Plan

1. Evidence cleanup first:
   - Regenerate missing samples where source access is available.
   - Re-run insufficient-window comparisons over the full manifest windows.
   - Keep blocked samples marked as blocked unless a same-language replacement is selected.
2. Inspect failing examples by issue family:
   - `weak_boundary`: Latin connector/subword splits and Cantonese/translated boundary splits.
   - `early_cutoff`: hold/guard behavior and candidate/reference comparability.
   - `start_onset_drift`: likely stale artifacts or ASR/reference alignment drift before retiming changes.
   - `long_idle_hold`: trim only when a real speech gap is clear.
3. Tune in this order:
   - Latin-script subword/connector boundary rules, if examples are structurally stable across English/French/Italian/German/Portuguese.
   - Cross-language hold timing only after confirming the reference windows are comparable.
   - Korean/Cantonese edge cases only after full-window artifacts are regenerated.
4. Every tuning step must add Swift and C# mirrored tests, then rerun:
   - `swift test --scratch-path .build/codex-multilingual-asr --filter ASRContractsTests`
   - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter AsrContractsTests --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
   - `python3 -m unittest tools/subtitle_timing_eval/tests/test_metrics.py`
   - `git diff --check`
5. For music-specific user-visible QA, run `run_viewing_quality_suite.py --suite songs30` and use
   `human_review.md`, `source_report.json`, and optional `agent_quality_judge.json` files as the iteration gate.
   Blocking issues include missing final source, bad platform source, final local-ASR garbage/repetition,
   long preview gaps, flash short cues, short text held too long, adjacent repeated cues, and Japanese weak-boundary splits.

## Progress

- 2026-06-24: Installed local `0.8.1 Beta` build (`0.8.1-beta`, build `8100`) for user testing.
- 2026-06-24: Generated current broad manifest `status.current.json` and `iteration.current.json`; evidence gaps are currently higher priority than new timing constants.
- 2026-06-25: Added the `songs30` viewing-quality gate, category coverage checks, optional Agent judge aggregation,
  and final-source music issue detectors. Validation passed: Python eval tests 174, Swift focused Core tests 277,
  Windows Core focused tests 162, `git diff --check`, and a manifest-only `songs30` dry run with all categories covered.

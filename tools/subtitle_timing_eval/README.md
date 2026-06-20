# Subtitle Timing Eval

Local tooling for measuring Moongate subtitle timing against an ASR word-timestamp reference.

Artifacts are written under `artifacts/subtitle_timing_eval/` and should not be committed.

## Scope

The timing gate is intentionally scoped to mainstream language coverage instead of every language on YouTube. The current manifest requires: English, Mandarin/Chinese, Cantonese, Japanese, Korean, Spanish, French, Italian, and translated-subtitle samples. This is the bounded product target for Moongate's "human-like 90% timing" work; long-tail languages should be added only when they reveal a regression that also affects this mainstream set. In gate terms, `en/zh/yue/ja/ko/es/fr/it` are required language groups, and `translated` is a required cross-language subtitle scenario.

## Quick Checks

```bash
python3 -m unittest discover -s tools/subtitle_timing_eval/tests
python3 -m subtitle_timing_eval.cli validate-manifest --manifest tools/subtitle_timing_eval/samples.json
```

When running the module from the repository root, set:

```bash
PYTHONPATH=tools/subtitle_timing_eval
```

## Workflow

Generate a manifest-driven runbook first:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli runbook \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --model small \
  --out artifacts/subtitle_timing_eval/runbook.json
```

The runbook is JSON and contains per-sample prepare, ASR, clean-srt, baseline metrics, optimized metrics, compare, and final suite commands. Use `--duration-seconds 30` to generate a short smoke runbook before a full manifest pass.

Check current artifact coverage at any point:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli status \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/status.current.json
```

`status` scans existing `comparison*.json` files and reports covered, missing, failing, and externally blocked samples against the mainstream coverage gate. Put a `blocker*.json` file in a sample artifact directory when a sample cannot be completed because of a reproducible external dependency failure such as YouTube timedtext HTTP 429. Blocked samples keep `passes_sample_completion_gate=false` while still allowing the strict language timing gate to reflect the samples that do have valid comparison evidence.

For final full-suite signoff, add the completion gate:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli status \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/status.current.json \
  --require-sample-completion
```

This command must fail while any manifest sample is missing, failing, or blocked, even if the mainstream timing gate is already green.

Materialize comparisons from already-generated report pairs:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli materialize-comparisons \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/materialized-comparisons.current.json
```

Manual-caption and cross-language translated samples use a preservation gate: they pass when optimized output does not regress from the human-timed baseline. Same-language auto/rolling samples use the stricter timing gate against ASR or VTT word timestamps. The status report keeps these separate so preservation coverage cannot be mistaken for completed strict timing coverage.

Prepare a sample section and subtitle files:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli prepare \
  --sample-id starship_test_like_you_fly_en \
  --artifacts artifacts/subtitle_timing_eval
```

`prepare` defaults to audio-only media (`ba[ext=m4a]/ba/best`) for fast ASR smoke runs. Put `media_format` in a sample entry when a QA pass needs a video track.
Use `--duration-seconds 30` for a short smoke before running the manifest's full 3-5 minute section.
If YouTube/ffmpeg fails while cutting the remote section, `prepare` falls back to downloading full audio into the ignored artifact directory and trimming locally to `<sample-id>.section.wav`.

Generate local ASR word timestamps:

```bash
python3 -m pip install -r tools/subtitle_timing_eval/requirements.txt
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli asr \
  --audio artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/<downloaded-media-file> \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/asr_words.json \
  --model small \
  --language en
```

When a downloaded YouTube VTT contains inline word timestamps, use it as the preferred reference for that sample:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli vtt-words \
  --vtt artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/ANe_HW4X8oc.en.vtt \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/vtt_words.json
```

For manual or official translated subtitles where ASR text is the wrong language, create a cue-derived reference instead:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli srt-words \
  --srt artifacts/subtitle_timing_eval/<sample>/<subtitle>.srt \
  --out artifacts/subtitle_timing_eval/<sample>/srt_words.json
```

Use this with `--gate-mode preserve` to prove Moongate does not damage human-timed cross-language subtitles.

Generate a human QA packet after the automated gates pass:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-report \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/qa.side-by-side.md
```

The packet groups samples by language, includes timestamped YouTube review links, shows baseline vs optimized cue text, and leaves `Human Verdict` / `Notes` columns for side-by-side review.

For faster local review, generate an HTML bundle with language tabs, local media snippets when available, YouTube fallbacks, synchronized baseline/optimized caption-window preview, metrics, notes, and PASS/FAIL controls:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-review \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/qa.review.html
```

Open `artifacts/subtitle_timing_eval/qa.review.html` locally, fill the verdicts, then export `qa.verdicts.review.json` from the page. Run the gate against that export:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-verdicts \
  --manifest tools/subtitle_timing_eval/samples.json \
  --review-json artifacts/subtitle_timing_eval/qa.verdicts.review.json \
  --out artifacts/subtitle_timing_eval/qa.verdicts.current.json \
  --require-pass
```

Alternatively, when reviewing directly in the Markdown packet, fill the `Human Verdict` cells with exact `PASS` or `FAIL` values and summarize the manual QA gate:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-verdicts \
  --manifest tools/subtitle_timing_eval/samples.json \
  --qa-report artifacts/subtitle_timing_eval/qa.side-by-side.md \
  --out artifacts/subtitle_timing_eval/qa.verdicts.current.json \
  --require-pass
```

The gate requires at least two `PASS` review rows per required group, zero `FAIL` rows, and zero blank or unknown verdicts. This is intentionally scoped to the manifest's mainstream groups so the eval has a clear stopping point instead of expanding into every language on YouTube.

Compare an SRT/VTT candidate against the ASR reference:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli metrics \
  --sample-id starship_test_like_you_fly_en \
  --candidate artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/source.en.srt \
  --asr-words artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/vtt_words.json \
  --window-start-seconds 40 \
  --window-end-seconds 340 \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/baseline.report.json
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli metrics \
  --sample-id starship_test_like_you_fly_en \
  --candidate artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/optimized.en.srt \
  --asr-words artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/vtt_words.json \
  --window-start-seconds 40 \
  --window-end-seconds 340 \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/optimized.report.json
```

Metrics only evaluate cues fully contained in the window. This avoids counting partial first/last cues when the downloaded audio section cuts through a sentence. Use `--asr-offset-seconds <section-start>` when the reference words start at zero, as faster-whisper output does.

Compare baseline vs optimized timing:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli compare \
  --baseline-report artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/baseline.report.json \
  --optimized-report artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/optimized.report.json \
  --language-group en \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/comparison.json
```

Summarize several sample comparisons:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli suite \
  --comparison artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/comparison.json \
  --require-manifest-coverage \
  --out artifacts/subtitle_timing_eval/suite.summary.json
```

Use `--require-manifest-coverage` on the final suite run. Without it, a small smoke suite can pass for the samples it includes, but it does not prove the full mainstream-language gate.

Check the current artifact set against the manifest's final sample gate:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli status \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/status.current.json \
  --require-sample-completion
```

`status` treats short smoke comparisons as incomplete when their paired reports do not cover the manifest window. Those samples appear under `insufficient_window_samples`; regenerate full-window reports before using the result as final evidence.

## Acceptance Window

A cue is accepted when its start error is between `-250ms` and `+450ms`, and its end error is between `-150ms` and `+900ms` relative to the ASR word span. The report also flags early cutoff, late hold, long idle hold, weak English boundaries, single-character CJK/Japanese/Korean splits, short feedback, and reading speed.

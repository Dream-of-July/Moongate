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

For the fixed 10-language human-caption suite, scope the runbook to the selected videos and optionally emit only the samples that still need strict evidence:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli runbook \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --only-incomplete \
  --out artifacts/subtitle_timing_eval/manual-suite-repair-runbook.current.json
```

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

Select the reproducible random human-caption QA suite:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli select-manual-suite \
  --manifest tools/subtitle_timing_eval/samples.json \
  --count 10 \
  --seed manual-caption-suite-2026-06-22 \
  --out artifacts/subtitle_timing_eval/manual-suite.current.json \
  --require-ready
```

This is the gate for the "10 random videos in 10 different spoken languages with human subtitles" target. For this eval, any public subtitle track that is not YouTube automatic recognition counts as human/manual-source evidence. The command excludes automatic-caption samples (`automatic_captions`, automatic `caption_kind`/`reference_kind`, or `*-orig` tracks), enforces one source/spoken language per sample, and keeps the random draw reproducible through `--seed`. If fewer than 10 distinct non-auto caption source languages exist, it writes the partial selection and exits non-zero with the missing language count.

When YouTube bot gates or rate limits a specific source, keep the draw reproducible by excluding only that blocked sample and replacing it with another same-language non-auto subtitle source:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli select-manual-suite \
  --manifest tools/subtitle_timing_eval/samples.json \
  --count 10 \
  --seed manual-caption-suite-2026-06-22 \
  --exclude-sample-id tedx_yonsei_visual_language_ko \
  --out artifacts/subtitle_timing_eval/manual-suite.current.json \
  --require-ready
```

Check artifact readiness for only that selected suite:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli manual-suite-status \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/manual-suite-status.current.json \
  --require-ready
```

This status gate scopes missing/failing/insufficient-window checks to the selected videos only. It requires strict timing evidence for the selected human-caption suite; `preserve` comparisons are reported but do not satisfy the 90% manual-suite gate. Translated public subtitle tracks are grouped by spoken/source language rather than by the generic `translated` bucket.

Current validated run (`manual-caption-suite-2026-06-22`, with blocked sources excluded) passes strict timing for 10/10 source languages: `de`, `en`, `es`, `fr`, `it`, `ja`, `ko`, `pt`, `yue`, and `zh`. After the Latin local-ASR subword repair, all selected samples currently report `accepted_ratio=1.0`. The remaining release gate is human side-by-side QA, not missing automated timing evidence.

Audit several seeded human-caption draws against the current strict artifacts:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli manual-suite-audit \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --count 10 \
  --seed manual-caption-suite-2026-06-22 \
  --seed manual-caption-suite-audit-01 \
  --seed manual-caption-suite-audit-02 \
  --seed manual-caption-suite-audit-03 \
  --seed manual-caption-suite-audit-04 \
  --seed manual-caption-suite-audit-05 \
  --out artifacts/subtitle_timing_eval/manual-suite-audit.current.json
```

Use `--exclude-sample-id` for known blocked sources, the same way as `select-manual-suite`. The audit reports every seed's selected samples, pass/fail state, thin language groups with only one current candidate, and which languages are genuinely randomized. It is an anti-overfitting check; it does not replace the final human QA verdict gate.

Current audit snapshot: the fixed selected suite passes 10/10 strict languages, and the multi-seed audit passes 6/6 seeds. The genuinely randomized language groups are currently `en` and `zh`; `de`, `es`, `fr`, `it`, `ja`, `ko`, `pt`, and `yue` still have only one strict-ready candidate each, so expanding those pools remains future evidence work rather than algorithm tuning.

For source-language local-ASR timing, use ASR/VTT word timestamps through `metrics`. For human translated subtitle tracks, use the human cue windows as the timing reference so cross-language text does not get unfairly judged against source-language word tokens:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli reference-metrics \
  --candidate artifacts/subtitle_timing_eval/english_to_chinese_auto_translate/iG9CE55wbtY.zh-CN.clean.srt \
  --reference artifacts/subtitle_timing_eval/english_to_chinese_auto_translate/iG9CE55wbtY.zh-CN.srt \
  --sample-id english_to_chinese_auto_translate \
  --window-start-seconds 60 \
  --window-end-seconds 360 \
  --out artifacts/subtitle_timing_eval/english_to_chinese_auto_translate/optimized.human-reference.report.json
```

Generate the next optimization backlog after each metrics pass:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli iteration-report \
  --manifest tools/subtitle_timing_eval/samples.json \
  --artifacts artifacts/subtitle_timing_eval \
  --out artifacts/subtitle_timing_eval/iteration.current.json
```

`iteration-report` is the anti-overfitting checkpoint. It groups failures across the whole mainstream manifest, ranks the dominant issue families (`accepted_ratio`, `start_onset_drift`, `early_cutoff`, `long_idle_hold`, `weak_boundary`, `cjk_singleton`, `reading_speed`, and artifact gaps), and includes a few worst cue examples per issue. Missing, blocked, or insufficient-window artifacts are ranked before algorithm tuning because the 90% target is not proven until the full sample matrix exists. The iteration rule is:

1. Fix the highest-ranked issue that appears across language groups or multiple samples.
2. Add or keep a regression fixture for that failure mode.
3. Re-run metrics, `materialize-comparisons`, `status --require-sample-completion`, `qa-review`, `qa-verdicts --require-text-risk-notes --require-pass`, and `iteration-report`.
4. Stop only when `iteration.current.json.ready_for_release` is true and the human QA gate also passes.

Manual-caption samples can still use `preserve` comparisons for compatibility checks, but preserve evidence is not enough for the fixed 10-language target. The manual-suite gate requires strict timing comparisons against either ASR/VTT word timing for source-language speech or `reference-metrics` human cue timing for translated/manual reference tracks.

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

Or use the same local whisper.cpp runtime/model path that Moongate uses in the app:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli asr \
  --engine whisper-cpp \
  --audio artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/<downloaded-media-file> \
  --out artifacts/subtitle_timing_eval/starship_test_like_you_fly_en/asr_words.json \
  --whisper-cli /opt/homebrew/bin/whisper-cli \
  --model-path "$HOME/Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin" \
  --ffmpeg /opt/homebrew/bin/ffmpeg \
  --language en \
  --no-gpu
```

Use `--no-gpu` when Metal allocation is unstable or the machine is short on GPU memory. The command still produces the same `asr_words.json` shape consumed by `local-asr-srt` and the timing metrics.

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
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode risk \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.md
```

The packet groups only the fixed random manual-caption suite by source/spoken language, includes timestamped YouTube review links, shows baseline vs optimized cue text, and leaves `Human Verdict` / `Notes` columns for side-by-side review. `--segment-mode risk` intentionally picks the highest-risk rows for bug hunting.

For the acceptance sample, use representative rows instead of worst-case rows:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-report \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode representative \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.representative.md
```

Representative mode is for the "90% close to human subtitles" gate: it picks accepted, normal-duration cue windows per language. The ASR text columns can be noisy, especially for non-English languages; judge the time window against the video/audio and human-reference cue timing, not ASR spelling quality.

For faster local review, generate an HTML bundle with language tabs, local media snippets when available, YouTube fallbacks, synchronized baseline/optimized caption-window preview, metrics, notes, and PASS/FAIL controls:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-review \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode representative \
  --prefill-json artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.representative.review.html
```

Open `artifacts/subtitle_timing_eval/qa.manual-suite.representative.review.html` locally, fill the verdicts, then export `qa.verdicts.review.json` from the page. `--prefill-json` only displays auto-reference suggestions and a `Use Suggestion` button; exported `human_verdict` values stay blank until a reviewer clicks PASS/FAIL or applies a suggestion after checking the row. Run the gate against that export:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-verdicts \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --review-json artifacts/subtitle_timing_eval/qa.verdicts.review.json \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.verdicts.json \
  --require-human-source \
  --require-text-risk-notes \
  --require-pass
```

For a compact non-HTML review path, generate a checklist. It keeps the same `Human Verdict` table shape that `qa-verdicts` can parse, but adds stable `Review ID` values, a `Suggested` column from auto-reference evidence, and a `Text Risk` column that highlights obvious baseline/optimized text mismatch for human review:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-checklist \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode representative \
  --prefill-json artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.checklist.md
```

`Suggested` values and `Text Risk` hints do not count as human verdicts. Fill the `Human Verdict` cells with exact `PASS` or `FAIL` values after checking the row, then summarize the manual QA gate. The summary also reports text-risk PASS/FAIL/unchecked counts and flags text-risk rows that were marked `PASS` without notes. For final signoff, keep `--require-text-risk-notes` enabled so a text-risk row cannot be accepted without a reviewer note explaining why:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-verdicts \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --qa-report artifacts/subtitle_timing_eval/qa.manual-suite.checklist.md \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.verdicts.json \
  --require-text-risk-notes \
  --require-pass
```

To list only rows that still lack human-source verdicts, generate the remaining queue:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-remaining \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode representative \
  --prefill-json artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json \
  --human-qa-report artifacts/subtitle_timing_eval/qa.manual-suite.checklist.md \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.remaining.md
```

The current remaining queue has 20 rows: 0 human-reviewed and 20 still pending. Use this as the short punch list for the final manual review. The header summarizes remaining `text-risk rows` and their review IDs so the reviewer can inspect likely text-quality failures first. If you partially fill the Markdown checklist, pass it back with `--human-qa-report`; rows with exact `PASS` or `FAIL` in `Human Verdict` are treated as `human_review` and removed from the remaining queue by stable `Review ID`, falling back to the review-time URL for older checklists.

The gate requires at least two `PASS` review rows per selected source language, zero `FAIL` rows, and zero blank or unknown verdicts. With `--require-text-risk-notes`, any row that has `Text Risk` flags and is marked `PASS` must also have reviewer notes. This is intentionally scoped to the fixed random 10-language manual-caption suite so the eval has a clear stopping point instead of expanding into every language on YouTube. For JSON review exports, keep `--require-human-source` enabled: it rejects `auto_reference` records used as human review input, while the HTML review export writes `verdict_source: human_review` only after a reviewer clicks PASS/FAIL or applies a suggestion after checking the row.

To separate automated evidence from final human judgment, prefill a review JSON from strict timing/reference metrics:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-autofill \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --max-segments-per-group 2 \
  --segment-mode representative \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json

PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli qa-verdicts \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --review-json artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json \
  --out artifacts/subtitle_timing_eval/qa.manual-suite.auto-reference.verdicts.json \
  --require-pass
```

The autofill file uses `verdict_source: auto_reference`; it is a machine evidence gate and does not claim a human has watched the rows. Current generated artifacts contain 20 auto-reference PASS rows, 0 skipped rows, and the auto-reference verdict gate passes all 10 selected language groups.

Aggregate the full completion evidence into one audit file:

```bash
PYTHONPATH=tools/subtitle_timing_eval \
python3 -m subtitle_timing_eval.cli completion-audit \
  --manifest tools/subtitle_timing_eval/samples.json \
  --selection artifacts/subtitle_timing_eval/manual-suite.current.json \
  --artifacts artifacts/subtitle_timing_eval \
  --audit-json artifacts/subtitle_timing_eval/manual-suite-audit.current.json \
  --auto-qa-json artifacts/subtitle_timing_eval/qa.manual-suite.auto-reference.verdicts.json \
  --human-qa-report artifacts/subtitle_timing_eval/qa.manual-suite.checklist.md \
  --out artifacts/subtitle_timing_eval/completion-audit.current.json \
  --require-machine-ready \
  --require-text-risk-notes
```

`completion-audit` is the one-file status view for the original goal. It checks the random 10-video manual-caption suite, 10 distinct source languages, non-auto caption eligibility, per-sample `accepted_ratio >= 0.90`, multi-seed anti-overfit audit, auto-reference representative QA, text-quality risk rows, and final human side-by-side QA. The final human gate can consume either a Markdown checklist via `--human-qa-report` or a JSON verdict summary via `--human-qa-json`; for JSON review exports, generate the summary with `qa-verdicts --require-human-source --require-text-risk-notes` so auto-reference records cannot count as human review and text-risk PASS rows cannot close the goal without notes. Markdown verdict sheets are treated as manually edited input. The current audit has `machine_ready: true`, `human_verified: false`, and `goal_complete: false`; the only remaining blocker is filling the human QA verdicts with at least two PASS rows per selected language, paying special attention to any rows listed under `text_quality_risks`.

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

Metrics only evaluate cues fully contained in the window. This avoids counting partial first/last cues when the downloaded audio section cuts through a sentence. Use `--asr-offset-seconds <section-start>` when the reference words start at zero, as faster-whisper output does. Use `--candidate-offset-seconds <section-start>` when the candidate SRT was generated from a section-relative local-ASR transcript and starts at `00:00:00,000`.

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

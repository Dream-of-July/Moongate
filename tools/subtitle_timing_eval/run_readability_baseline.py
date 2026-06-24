#!/usr/bin/env python3
"""Score reference-free subtitle readability over all candidates with fresh ASR.

Generates the candidate segmentation (moongate-cli local-asr-srt) from each
sample's uniform word-level ASR, then scores it with the readability metric
(reading speed, duration, line length, weak boundaries, orphans, overlaps).
No reference needed, so every sample with ASR is usable.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from subtitle_timing_eval.pipeline import _load_subtitle_cues  # noqa: E402
from subtitle_timing_eval.readability import (  # noqa: E402
    evaluate_readability,
    render_readability_review_markdown,
    summarize_readability_suite,
)

WINDOW_RE = re.compile(r"(\d+)-(\d+)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", default=".build-seg/debug/moongate-cli")
    ap.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    ap.add_argument("--manifest", default="tools/subtitle_timing_eval/segmentation_samples.json")
    ap.add_argument("--out-dir", default="artifacts/subtitle_timing_eval/readability")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    by_id = {s["id"]: s for s in manifest["samples"]}
    art = Path(args.artifacts)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    reports = []
    report_paths = []
    skipped = []
    for sid, sample in sorted(by_id.items()):
        d = art / sid
        seg = sorted(d.glob("asr_words.*-*.seg.json"))
        if not seg:
            skipped.append((sid, "no fresh seg ASR"))
            continue
        asr = seg[0]
        lang = (sample.get("subtitle_lang") or "und").split("-")[0]
        cand = d / ("readability-candidate.%s.srt" % lang)
        proc = subprocess.run(
            [args.binary, "local-asr-srt", "--asr-words", str(asr),
             "--language", lang, "--out", str(cand),
             "--file-name", sample.get("title") or sid],
            capture_output=True, text=True,
        )
        if proc.returncode != 0 or not cand.exists():
            skipped.append((sid, "candidate gen failed"))
            continue
        cues = _load_subtitle_cues(str(cand))
        report = evaluate_readability(cues, sid, language=sample.get("subtitle_lang"),
                                      track=sample.get("track"))
        out_path = out_dir / ("%s.readability.json" % sid)
        out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        report_paths.append(str(out_path))
        reports.append(report)

    summary = summarize_readability_suite(reports)
    (out_dir / "suite.summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    ov = summary["overall"]
    lines = ["# Subtitle readability baseline\n",
             "samples=%d  skipped=%d\n" % (len(reports), len(skipped)),
             "**Overall**: mean clean-ratio=%.3f  pass-rate=%.0f%% (%d/%d)  suite_gate=%s" % (
                 ov["mean_clean_ratio"], 100 * ov["pass_rate"], ov["pass_count"],
                 ov["sample_count"], ov["passes_suite_gate"]),
             "**flag totals**: %s\n" % json.dumps(ov["flag_totals"], ensure_ascii=False)]
    for script, agg in summary["by_script"].items():
        lines.append("**%s**: mean clean-ratio=%.3f  pass-rate=%.0f%% (%d/%d)" % (
            script, agg["mean_clean_ratio"], 100 * agg["pass_rate"], agg["pass_count"], agg["sample_count"]))
    lines.append("\n| sample | script | clean | cues | flags |")
    lines.append("|---|---|---|---|---|")
    for r in sorted(reports, key=lambda x: x["clean_ratio"]):
        fl = ",".join("%s=%d" % (k, v) for k, v in sorted(r["flag_counts"].items(), key=lambda kv: -kv[1]))
        lines.append("| %s | %s | %.3f | %d | %s |" % (
            r["sample_id"], r["script"], r["clean_ratio"], r["cue_count"], fl or "—"))
    md = "\n".join(lines) + "\n"
    (out_dir / "baseline.report.md").write_text(md, encoding="utf-8")
    (out_dir / "human_review.md").write_text(
        render_readability_review_markdown(reports),
        encoding="utf-8",
    )
    print(md)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run the subtitle *segmentation* baseline over locally-cached eval samples.

For every artifact directory that already has both Whisper word timestamps and a
reference caption, this:

  1. regenerates the candidate segmentation with the Swift segmenter
     (``moongate-cli local-asr-srt``),
  2. scores it against the reference caption with ``segmentation-metrics``
     (boundary F1 + temporal coverage + over/under-seg), and
  3. aggregates everything into a suite summary + a human-readable report.

It is fully offline (no network / no Whisper run) and resumable: only cached
inputs are read, and every output is rewritten deterministically.

Usage:
  python3 tools/subtitle_timing_eval/run_segmentation_baseline.py \
      --binary .build-seg/debug/moongate-cli \
      --artifacts artifacts/subtitle_timing_eval \
      --manifest tools/subtitle_timing_eval/samples.json \
      --out-dir artifacts/subtitle_timing_eval/segmentation
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from subtitle_timing_eval.pipeline import (  # noqa: E402
    _load_subtitle_cues,
    evaluate_segmentation_files,
    summarize_segmentation_suite_files,
)

WINDOW_RE = re.compile(r"(\d+)-(\d+)")
MIN_ASR_WORDS = 30
ROLLING_TINY_CUE_RATIO = 0.15  # fraction of <0.3s cues that marks a word-level/rolling reference


def _asr_word_count(path: Path) -> int:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return 0
    if isinstance(data, dict):
        return len(data.get("words", []))
    if isinstance(data, list):
        return len(data)
    return 0


def _reference_is_rolling(path: Path) -> bool:
    """A reference whose cues are dominated by sub-0.3s fragments is a word-level
    rolling auto-caption, not a clean human line segmentation — an unfair target
    for boundary F1."""
    try:
        cues = _load_subtitle_cues(str(path))
    except Exception:
        return False
    if len(cues) < 10:
        return False
    tiny = sum(1 for c in cues if (c.end - c.start) < 0.3)
    return (tiny / len(cues)) > ROLLING_TINY_CUE_RATIO


def _track_for(category: str) -> str:
    return "B" if "auto" in category else "A"


def _find_reference(directory: Path, lang: str) -> Path | None:
    candidates = []
    for path in sorted(directory.glob("*.srt")):
        name = path.name
        if name.endswith(".clean.srt"):
            continue
        if name.startswith(("local-asr", "seg-candidate", "srt_words")):
            continue
        candidates.append(path)
    if not candidates:
        # fall back to a YouTube VTT reference
        vtts = [p for p in sorted(directory.glob("*.vtt")) if not p.name.startswith("seg-")]
        return vtts[0] if vtts else None
    # prefer a reference whose name carries the language code
    base = lang.split("-")[0]
    for path in candidates:
        if (".%s." % base) in path.name or (".%s." % lang) in path.name:
            return path
    return candidates[0]


def _median_word_duration(path: Path) -> float:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return 99.0
    words = data.get("words", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
    durs = sorted(max(0.0, float(w["end"]) - float(w["start"])) for w in words if "start" in w and "end" in w)
    if not durs:
        return 99.0
    return durs[len(durs) // 2]


COARSE_WORD_DURATION_SECONDS = 1.2  # above this the ASR is segment-level, not word-level


def _asr_max_end(path: Path) -> float:
    """Largest word end time = how many seconds of audio were actually transcribed."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return 0.0
    words = data.get("words", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
    ends = [float(w["end"]) for w in words if "end" in w]
    return max(ends) if ends else 0.0


def _find_asr_words(directory: Path) -> tuple[Path | None, int | None, int | None]:
    """Pick the WORD-LEVEL Whisper file with the longest window. Segment-level
    (coarse) ASR is excluded: its quantized timestamps would measure ASR
    granularity, not segmentation quality."""
    def _window(path: Path) -> tuple[int | None, int | None]:
        match = WINDOW_RE.search(path.stem.replace("win", ""))
        if match:
            return int(match.group(1)), int(match.group(2))
        return None, None

    best: Path | None = None
    best_span = -1
    best_window: tuple[int | None, int | None] = (None, None)
    for path in sorted(directory.glob("asr_words*.json")):
        if "probe" in path.name:
            continue
        if _asr_word_count(path) < MIN_ASR_WORDS:
            continue
        if _median_word_duration(path) > COARSE_WORD_DURATION_SECONDS:
            continue
        start, end = _window(path)
        span = (end - start) if (start is not None and end is not None) else 0
        if span > best_span:
            best_span = span
            best = path
            best_window = (start, end)
    if best is None:
        return None, None, None
    return best, best_window[0], best_window[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build-seg/debug/moongate-cli")
    parser.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    parser.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    parser.add_argument("--out-dir", default="artifacts/subtitle_timing_eval/segmentation")
    parser.add_argument("--tolerance-seconds", type=float, default=0.5)
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    by_id = {s["id"]: s for s in manifest["samples"]}

    artifacts_root = Path(args.artifacts)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    report_paths: list[str] = []
    rows = []
    skipped = []

    for sample_id, sample in sorted(by_id.items()):
        category = sample.get("category", "")
        # segmentation track only covers caption-vs-caption; skip translation proxies
        if "translate" in category or "proxy" in category:
            skipped.append((sample_id, "translation/proxy category"))
            continue
        directory = artifacts_root / sample_id
        if not directory.is_dir():
            skipped.append((sample_id, "no artifact dir"))
            continue
        lang = sample.get("subtitle_lang", "").split("-")[0] or "und"
        reference = _find_reference(directory, sample.get("subtitle_lang", ""))
        asr_words, win_start, win_end = _find_asr_words(directory)
        if reference is None or asr_words is None:
            skipped.append((sample_id, "missing %s" % (
                "reference" if reference is None else "asr_words")))
            continue
        if _asr_word_count(asr_words) < MIN_ASR_WORDS:
            skipped.append((sample_id, "insufficient ASR words (<%d)" % MIN_ASR_WORDS))
            continue
        if _median_word_duration(asr_words) > COARSE_WORD_DURATION_SECONDS:
            skipped.append((sample_id, "coarse/segment-level ASR (no word-level file)"))
            continue
        if _reference_is_rolling(reference):
            skipped.append((sample_id, "rolling/word-level reference (unfair boundary target)"))
            continue

        candidate = directory / ("seg-candidate.%s.srt" % lang)
        proc = subprocess.run(
            [args.binary, "local-asr-srt", "--asr-words", str(asr_words),
             "--language", lang, "--out", str(candidate)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0 or not candidate.exists():
            skipped.append((sample_id, "candidate gen failed: %s" % proc.stderr.strip()[:120]))
            continue

        offset = float(win_start) if win_start is not None else 0.0
        # Window end must match what was ACTUALLY transcribed, not the manifest
        # section length: some cached audio is shorter than the manifest duration,
        # which would otherwise leave most of the window uncovered (false low coverage).
        asr_span = _asr_max_end(asr_words)
        window_start = float(win_start) if win_start is not None else None
        if asr_span > 0 and win_start is not None:
            window_end = offset + asr_span
        else:
            window_end = float(win_end) if win_end is not None else None
        out_path = out_dir / ("%s.segmentation.json" % sample_id)
        report = evaluate_segmentation_files(
            str(candidate), str(reference), sample_id, str(out_path),
            candidate_offset_seconds=offset,
            window_start=window_start, window_end=window_end,
            tolerance_seconds=args.tolerance_seconds,
            track=_track_for(category),
        )
        report_paths.append(str(out_path))
        rows.append(report)

    suite_path = out_dir / "suite.summary.json"
    summary = summarize_segmentation_suite_files(report_paths, str(suite_path))

    # human-readable console + markdown
    rows.sort(key=lambda r: r.get("aligned_boundary_f1", r["boundary_f1"]))
    lines = []
    lines.append("# Segmentation baseline\n")
    lines.append("tolerance=%.2fs  samples=%d  skipped=%d\n" % (
        args.tolerance_seconds, len(rows), len(skipped)))
    ov = summary["overall"]
    lines.append("**Overall**: aligned F1=%.3f  strong-recall=%.3f  coverage=%.3f  pass-rate=%.0f%% (%d/%d)  suite_gate=%s\n" % (
        ov["mean_aligned_boundary_f1"], ov["mean_strong_boundary_recall"], ov["mean_temporal_coverage"],
        100 * ov["pass_rate"], ov["pass_count"], ov["sample_count"], ov["passes_suite_gate"]))
    for track, agg in summary["by_track"].items():
        lines.append("**Track %s**: aligned F1=%.3f  strong-recall=%.3f  coverage=%.3f  pass-rate=%.0f%% (%d/%d)\n" % (
            track, agg["mean_aligned_boundary_f1"], agg["mean_strong_boundary_recall"], agg["mean_temporal_coverage"],
            100 * agg["pass_rate"], agg["pass_count"], agg["sample_count"]))
    lines.append("\n| sample | track | alignF1 | strongR | off_ms | coverage | seg_ratio | gate |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for r in rows:
        lines.append("| %s | %s | %.3f | %.3f | %+.0f | %.3f | %.2f | %s |" % (
            r["sample_id"], r.get("track") or "-",
            r.get("aligned_boundary_f1", 0.0), r.get("strong_boundary_recall", 0.0),
            r.get("systematic_offset_ms", 0.0), r["temporal_coverage"],
            r["segment_count_ratio"],
            "PASS" if r["passes_segmentation_gate"] else ",".join(r["gate_failures"])))
    if skipped:
        lines.append("\n## Skipped\n")
        for sid, why in skipped:
            lines.append("- %s — %s" % (sid, why))
    md = "\n".join(lines) + "\n"
    (out_dir / "baseline.report.md").write_text(md, encoding="utf-8")
    print(md)
    print("suite summary -> %s" % suite_path)


if __name__ == "__main__":
    main()

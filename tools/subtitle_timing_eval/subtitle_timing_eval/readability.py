"""Reference-free subtitle *readability / viewing-quality* metric.

Instead of matching an independent human caption's exact break points (which has
a low ceiling — Whisper's sentence segmentation legitimately differs from a human
editor's, see SEGMENTATION_EVAL.md), this scores whether OUR segmentation produces
cues that are comfortable to read and look right on screen. It needs no reference.

Each cue is checked against language-aware thresholds drawn from mainstream
subtitle style guides (Netflix Timed Text, BBC, TED):

  - reading speed (characters per second) not too fast to read,
  - duration not so short it flashes, nor so long it lingers,
  - line length not overflowing the safe area,
  - the cut does not land on a weak boundary (a function word that reads as
    "to be continued" — e.g. ending on "the"/"to" or a leading CJK particle),
  - no single-character CJK fragment, no flashing one-word orphan,
  - cues do not visually overlap / collide.

A cue is "clean" when it trips none of these. Sample readability = clean-cue
ratio; the >=90% gate means >=90% of cues read cleanly.
"""

from __future__ import annotations

import re
from statistics import mean
from typing import Any, Dict, List, Optional, Sequence

from .srt import Cue
from .metrics import (
    CJK_RE,
    HANDOFF_END_RE,
    WEAK_BOUNDARY_WORDS,
    cue_tokens,
    is_short_feedback,
)

CJK_LANG_PREFIXES = ("ja", "ko", "zh", "yue", "cmn")

# Language-aware thresholds (mainstream subtitle style guides).
# Cues are scored against a TWO-LINE display budget: players wrap a cue into up to
# two lines of `max_chars_per_line`, so the readability limit on a single cue is
# 2 x max_chars_per_line (Netflix caps a subtitle at two lines).
LATIN_THRESHOLDS = {
    "max_cps": 21.0,           # TED upper bound; Netflix ideal is 17
    "min_duration": 0.8,       # below ~0.83s a cue flashes
    "max_duration": 7.0,       # Netflix max
    "max_chars_per_line": 42,  # Netflix Latin
}
CJK_THRESHOLDS = {
    "max_cps": 11.0,           # CJK chars are information-dense; >~11/s is too fast
    "min_duration": 0.9,
    "max_duration": 7.0,
    "max_chars_per_line": 18,  # full-width chars per line
}

EPSILON = 1e-6
MAX_DISPLAY_LINES = 2
MIN_INTER_CUE_GAP = -0.001     # tolerate float noise; anything more negative is an overlap
ORPHAN_MAX_DURATION = 0.7      # a 1-token cue shorter than this flashes as an orphan


def is_cjk_language(language: Optional[str], cues: Sequence[Cue]) -> bool:
    if language:
        low = language.lower()
        if any(low.startswith(p) for p in CJK_LANG_PREFIXES):
            return True
    # fall back to script detection on the cue text
    cjk = 0
    total = 0
    for cue in cues:
        for ch in cue.text:
            if not ch.isspace():
                total += 1
                if CJK_RE.match(ch):
                    cjk += 1
    return total > 0 and (cjk / total) >= 0.3


def _visible_chars(text: str) -> int:
    return len("".join(ch for ch in text if not ch.isspace()))


def _ends_on_weak_word(text: str) -> bool:
    """A cue that ENDS on a function word (article/preposition/conjunction/copula)
    strands a word that binds to the next line — a real readability defect (BBC:
    don't separate an article/preposition from what follows). Starting the NEXT
    line with such a word is fine, so we only check the ending."""
    stripped = text.strip()
    if HANDOFF_END_RE.search(stripped):  # a colon/semicolon is a deliberate handoff
        return False
    tokens = cue_tokens(stripped)
    return bool(tokens) and tokens[-1] in WEAK_BOUNDARY_WORDS


def _max_line_chars(text: str, cjk: bool) -> int:
    longest = 0
    for line in text.splitlines() or [text]:
        n = _visible_chars(line) if cjk else len(line.strip())
        longest = max(longest, n)
    return longest


def _exceeds_display_budget(text: str, cjk: bool, max_chars_per_line: int) -> bool:
    """True if the cue cannot fit the standard 2-line safe area. If the cue has
    explicit line breaks, each line must fit; otherwise the total (which a player
    would wrap) must fit within MAX_DISPLAY_LINES x max_chars_per_line."""
    budget = MAX_DISPLAY_LINES * max_chars_per_line
    explicit_lines = [ln for ln in text.splitlines() if ln.strip()]
    if len(explicit_lines) > 1:
        if len(explicit_lines) > MAX_DISPLAY_LINES:
            return True
        per_line = max((_visible_chars(ln) if cjk else len(ln.strip())) for ln in explicit_lines)
        return per_line > max_chars_per_line
    total = _visible_chars(text) if cjk else len(text.strip())
    return total > budget


def evaluate_readability(
    cues: Sequence[Cue],
    sample_id: str,
    *,
    language: Optional[str] = None,
    track: Optional[str] = None,
) -> Dict[str, Any]:
    cjk = is_cjk_language(language, cues)
    th = CJK_THRESHOLDS if cjk else LATIN_THRESHOLDS
    ordered = list(cues)
    rows: List[Dict[str, Any]] = []

    for index, cue in enumerate(ordered):
        duration = max(0.0, cue.end - cue.start)
        chars = _visible_chars(cue.text)
        cps = chars / duration if duration > 0 else float("inf")
        tokens = cue_tokens(cue.text)
        next_cue = ordered[index + 1] if index + 1 < len(ordered) else None
        gap_to_next = (next_cue.start - cue.end) if next_cue else None

        flags: List[str] = []
        if cps > th["max_cps"]:
            flags.append("too_fast")
        if duration + EPSILON < th["min_duration"]:
            flags.append("flash_too_short")
        if duration > th["max_duration"]:
            flags.append("lingers_too_long")
        if _exceeds_display_budget(cue.text, cjk, th["max_chars_per_line"]):
            flags.append("too_long_to_fit")
        if _ends_on_weak_word(cue.text):
            flags.append("weak_boundary")
        if cjk and _visible_chars(cue.text) == 1:
            flags.append("cjk_singleton")
        if len(tokens) <= 1 and duration < ORPHAN_MAX_DURATION and not is_short_feedback(cue.text):
            flags.append("orphan_fragment")
        if gap_to_next is not None and gap_to_next < MIN_INTER_CUE_GAP:
            flags.append("overlap_next")

        rows.append({
            "index": cue.index,
            "start": cue.start,
            "end": cue.end,
            "duration": duration,
            "text": cue.text,
            "chars": chars,
            "reading_speed_cps": cps if cps != float("inf") else None,
            "gap_to_next": gap_to_next,
            "flags": flags,
            "clean": not flags,
        })

    clean = [r for r in rows if r["clean"]]
    flag_counts: Dict[str, int] = {}
    for r in rows:
        for f in r["flags"]:
            flag_counts[f] = flag_counts.get(f, 0) + 1

    clean_ratio = (len(clean) / len(rows)) if rows else 0.0
    speeds = [r["reading_speed_cps"] for r in rows if r["reading_speed_cps"] is not None]
    durations = [r["duration"] for r in rows]

    return {
        "sample_id": sample_id,
        "track": track,
        "language": language,
        "script": "cjk" if cjk else "latin",
        "cue_count": len(rows),
        "clean_cue_count": len(clean),
        "clean_ratio": clean_ratio,
        "flag_counts": flag_counts,
        "median_reading_speed_cps": sorted(speeds)[len(speeds) // 2] if speeds else 0.0,
        "median_duration": sorted(durations)[len(durations) // 2] if durations else 0.0,
        "passes_readability_gate": clean_ratio >= 0.90,
        "cues": rows,
    }


def summarize_readability_suite(reports: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    def _agg(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
        if not rows:
            return {"sample_count": 0, "mean_clean_ratio": 0.0, "pass_count": 0,
                    "pass_rate": 0.0, "passes_suite_gate": False, "flag_totals": {}}
        ratios = [r["clean_ratio"] for r in rows]
        passes = [r for r in rows if r["passes_readability_gate"]]
        flag_totals: Dict[str, int] = {}
        for r in rows:
            for f, n in r["flag_counts"].items():
                flag_totals[f] = flag_totals.get(f, 0) + n
        mean_ratio = mean(ratios)
        pass_rate = len(passes) / len(rows)
        return {
            "sample_count": len(rows),
            "mean_clean_ratio": mean_ratio,
            "pass_count": len(passes),
            "pass_rate": pass_rate,
            "flag_totals": dict(sorted(flag_totals.items(), key=lambda kv: -kv[1])),
            "passes_suite_gate": mean_ratio >= 0.90 and pass_rate >= 0.90,
        }

    by_track: Dict[str, List[Dict[str, Any]]] = {}
    by_script: Dict[str, List[Dict[str, Any]]] = {}
    for r in reports:
        by_track.setdefault(r.get("track") or "unspecified", []).append(r)
        by_script.setdefault(r.get("script") or "unknown", []).append(r)
    return {
        "overall": _agg(list(reports)),
        "by_track": {k: _agg(v) for k, v in sorted(by_track.items())},
        "by_script": {k: _agg(v) for k, v in sorted(by_script.items())},
        "worst_samples": sorted(
            ({"sample_id": r["sample_id"], "script": r["script"], "clean_ratio": r["clean_ratio"],
              "flag_counts": r["flag_counts"]} for r in reports),
            key=lambda x: x["clean_ratio"],
        )[:12],
    }


def _srt_time(seconds: float) -> str:
    total_ms = max(0, int(round(seconds * 1000)))
    ms = total_ms % 1000
    total_s = total_ms // 1000
    s = total_s % 60
    total_m = total_s // 60
    m = total_m % 60
    h = total_m // 60
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def render_readability_review_markdown(
    reports: Sequence[Dict[str, Any]],
    *,
    max_samples: int = 12,
    max_cues_per_sample: int = 6,
) -> str:
    """Render a compact human review queue with the actual subtitle text.

    Numeric gates are useful for triage, but subtitle quality work needs a
    reviewer to see the cue text and timing. This report is intentionally
    candidate-first: it lists the worst samples and their flagged cues so each
    optimization pass can be grounded in visible subtitle output.
    """
    ordered = sorted(
        reports,
        key=lambda r: (r.get("clean_ratio", 0.0), -sum(r.get("flag_counts", {}).values()), r.get("sample_id", "")),
    )
    lines = [
        "# Human Readability Review",
        "",
        "Review the candidate subtitle cues below before changing thresholds. Focus on whether the visible text would feel natural on screen.",
        "",
    ]
    for report in ordered[:max_samples]:
        flagged = [cue for cue in report.get("cues", []) if cue.get("flags")]
        if not flagged:
            continue
        lines.append(
            "## {sample} ({script}, clean={clean:.3f})".format(
                sample=report.get("sample_id", "unknown"),
                script=report.get("script", "unknown"),
                clean=float(report.get("clean_ratio", 0.0)),
            )
        )
        lines.append("")
        for cue in flagged[:max_cues_per_sample]:
            flags = ", ".join(cue.get("flags", []))
            lines.append(
                "- `{start} --> {end}` cue {index}: `{flags}`".format(
                    start=_srt_time(float(cue.get("start", 0.0))),
                    end=_srt_time(float(cue.get("end", 0.0))),
                    index=cue.get("index", "?"),
                    flags=flags,
                )
            )
            text = str(cue.get("text", "")).replace("\n", " / ")
            lines.append(f"  > {text}")
        lines.append("")
    if len(lines) <= 4:
        lines.append("No flagged cues in the selected reports.")
        lines.append("")
    return "\n".join(lines)

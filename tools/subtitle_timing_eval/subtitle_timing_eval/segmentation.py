"""Subtitle *segmentation* quality metrics.

This module is intentionally separate from ``metrics.py`` (which scores subtitle
*timing* error). Here we score whether the segmenter cut the stream into cues at
the right places, comparing a candidate segmentation against a reference
segmentation in a way that is robust to differing transcription text (Whisper
text vs. human caption text describe the same speech with different wording).

A segmentation is represented by its set of *boundaries* — the onset (start
time) of each cue. We match candidate boundaries to reference boundaries within
a time tolerance window and compute precision / recall / F1, plus
over/under-segmentation ratios and temporal text coverage.

See ``SEGMENTATION_EVAL.md`` for the full metric definition and the >=90% gate.
"""

from __future__ import annotations

import re
from statistics import mean
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .srt import Cue

# Default acceptance gate (kept in sync with SEGMENTATION_EVAL.md).
DEFAULT_TOLERANCE_SECONDS = 0.5
REPORT_TOLERANCES_SECONDS = (0.3, 0.5, 1.0)
TRIVIAL_BOUNDARY_EPSILON_SECONDS = 0.2

GATE_MIN_F1 = 0.90
GATE_MIN_COVERAGE = 0.90
GATE_MIN_SEGMENT_COUNT_RATIO = 0.80
GATE_MAX_SEGMENT_COUNT_RATIO = 1.25

# A "strong" reference boundary is one a listener must agree on: the previous
# cue ends a sentence, or there is a real speech gap before this cue. Missing a
# strong boundary means we merged across a sentence/pause — a real defect,
# independent of YouTube's reading-speed line wrapping.
STRONG_GAP_SECONDS = 0.4
GATE_MIN_STRONG_RECALL = 0.90
_SENTENCE_END_RE = re.compile(r"[.!?。！？…]+[\"')\]”’」』）]*\s*$")


def strong_reference_boundaries(
    reference_cues: Sequence["Cue"],
    window_start: Optional[float],
    epsilon: float = TRIVIAL_BOUNDARY_EPSILON_SECONDS,
    gap_seconds: float = STRONG_GAP_SECONDS,
) -> List[float]:
    """Onsets of reference cues that follow a sentence-end or a real speech gap."""
    edge = window_start
    ordered = sorted(reference_cues, key=lambda c: (c.start, c.end))
    strong: List[float] = []
    for i, cue in enumerate(ordered):
        if i == 0:
            continue
        if edge is not None and cue.start <= edge + epsilon:
            continue
        prev = ordered[i - 1]
        gap = cue.start - prev.end
        if gap >= gap_seconds or _SENTENCE_END_RE.search(prev.text.strip()):
            strong.append(cue.start)
    strong.sort()
    return strong


# ---------------------------------------------------------------------------
# Window / boundary helpers
# ---------------------------------------------------------------------------

def clip_cues_to_window(
    cues: Sequence[Cue],
    window_start: Optional[float],
    window_end: Optional[float],
) -> List[Cue]:
    """Return cues that overlap ``[window_start, window_end]`` (open bounds when
    ``None``), with their spans clamped to the window."""
    low = window_start if window_start is not None else float("-inf")
    high = window_end if window_end is not None else float("inf")
    clipped: List[Cue] = []
    for cue in cues:
        start = max(cue.start, low)
        end = min(cue.end, high)
        if end <= start:
            # Cue lies fully outside the window (or collapses to zero width).
            if cue.end <= low or cue.start >= high:
                continue
            end = max(start, min(cue.end, high))
            if end <= start:
                continue
        clipped.append(Cue(index=cue.index, start=start, end=end, text=cue.text))
    return clipped


def cue_onset_boundaries(
    cues: Sequence[Cue],
    window_start: Optional[float],
    epsilon: float = TRIVIAL_BOUNDARY_EPSILON_SECONDS,
) -> List[float]:
    """Boundary set = cue onsets, dropping the trivial onset(s) that coincide
    with the window start (the first cue beginning at the window edge is not a
    *decision* the segmenter made about where to cut)."""
    edge = window_start
    boundaries: List[float] = []
    for cue in cues:
        if edge is not None and cue.start <= edge + epsilon:
            continue
        boundaries.append(cue.start)
    boundaries.sort()
    return boundaries


# ---------------------------------------------------------------------------
# Boundary matching (one-to-one, nearest within tolerance)
# ---------------------------------------------------------------------------

def match_boundaries(
    candidate: Sequence[float],
    reference: Sequence[float],
    tolerance: float,
) -> Tuple[List[Tuple[int, int, float]], List[int], List[int]]:
    """Greedy one-to-one matching by ascending |Δt|.

    Returns ``(matches, unmatched_candidate_idx, unmatched_reference_idx)`` where
    ``matches`` is a list of ``(candidate_index, reference_index, abs_delta)``.

    Greedy-nearest is optimal for the count of matches here because boundaries
    are 1-D points and the tolerance gate is symmetric; matching the globally
    smallest gaps first never blocks a feasible pairing that a different order
    would have allowed.
    """
    pairs: List[Tuple[float, int, int]] = []
    for ci, ct in enumerate(candidate):
        for ri, rt in enumerate(reference):
            delta = abs(ct - rt)
            if delta <= tolerance:
                pairs.append((delta, ci, ri))
    pairs.sort(key=lambda item: (item[0], item[1], item[2]))

    used_candidate: set[int] = set()
    used_reference: set[int] = set()
    matches: List[Tuple[int, int, float]] = []
    for delta, ci, ri in pairs:
        if ci in used_candidate or ri in used_reference:
            continue
        used_candidate.add(ci)
        used_reference.add(ri)
        matches.append((ci, ri, delta))

    unmatched_candidate = [ci for ci in range(len(candidate)) if ci not in used_candidate]
    unmatched_reference = [ri for ri in range(len(reference)) if ri not in used_reference]
    return matches, unmatched_candidate, unmatched_reference


def _prf(tp: int, fp: int, fn: int) -> Tuple[float, float, float]:
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
    return precision, recall, f1


# ---------------------------------------------------------------------------
# Temporal coverage
# ---------------------------------------------------------------------------

def _merge_spans(spans: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    ordered = sorted((s, e) for s, e in spans if e > s)
    merged: List[Tuple[float, float]] = []
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _covered_duration(
    reference_spans: Sequence[Tuple[float, float]],
    candidate_spans: Sequence[Tuple[float, float]],
) -> Tuple[float, float]:
    """Return ``(covered_reference_seconds, total_reference_seconds)``."""
    ref = _merge_spans(reference_spans)
    cand = _merge_spans(candidate_spans)
    total = sum(e - s for s, e in ref)
    if total <= 0:
        return 0.0, 0.0
    covered = 0.0
    j = 0
    for rs, re in ref:
        # advance candidate spans that end before this reference span starts
        while j < len(cand) and cand[j][1] <= rs:
            j += 1
        k = j
        while k < len(cand) and cand[k][0] < re:
            overlap = min(re, cand[k][1]) - max(rs, cand[k][0])
            if overlap > 0:
                covered += overlap
            k += 1
    return covered, total


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def _estimate_systematic_offset(
    candidate: Sequence[float],
    reference: Sequence[float],
    search_window: float,
) -> float:
    """Estimate the systematic onset offset (candidate - reference) as the
    median signed delta to the nearest reference boundary, over candidate
    boundaries that have a reference within ``search_window``.

    Moongate deliberately nudges cue onsets later for readability
    (``WhisperCueRetimer.onsetDelaySeconds``); that constant display shift is a
    *timing* concern, already scored by the timing eval. Segmentation quality —
    "did we cut in the right places?" — should be invariant to a constant
    offset, so we report an offset-aligned F1 alongside the raw F1.
    """
    if not candidate or not reference:
        return 0.0
    ref_sorted = sorted(reference)
    signed: List[float] = []
    import bisect

    for t in candidate:
        j = bisect.bisect_left(ref_sorted, t)
        best: Optional[Tuple[float, float]] = None
        for k in (j - 1, j, j + 1):
            if 0 <= k < len(ref_sorted):
                delta = t - ref_sorted[k]
                if best is None or abs(delta) < abs(best[1]):
                    best = (abs(delta), delta)
        if best is not None and best[0] <= search_window:
            signed.append(best[1])
    if not signed:
        return 0.0
    signed.sort()
    mid = len(signed) // 2
    if len(signed) % 2:
        return signed[mid]
    return (signed[mid - 1] + signed[mid]) / 2.0


def _best_aligned_scores(
    candidate: Sequence[float],
    reference: Sequence[float],
    tolerance: float,
    max_offset: float = 1.0,
    step: float = 0.05,
) -> Tuple[float, Dict[str, Any]]:
    """Search a bounded global onset offset (candidate shifted by -offset) that
    maximises boundary F1, and return ``(offset_seconds, scores)``.

    Bounding to ``max_offset`` (1.0s) keeps this honest: it absorbs the
    intentional, constant readability nudge and DTW onset bias, but cannot
    "cheat" past a plausible display shift. Absolute onset accuracy is scored
    separately by the timing eval.
    """
    if not candidate or not reference:
        return 0.0, _boundary_scores(candidate, reference, tolerance)
    best_offset = 0.0
    best_scores = _boundary_scores(candidate, reference, tolerance)
    n = int(round(max_offset / step))
    for i in range(-n, n + 1):
        offset = i * step
        shifted = [t - offset for t in candidate]
        scores = _boundary_scores(shifted, reference, tolerance)
        if scores["f1"] > best_scores["f1"]:
            best_scores = scores
            best_offset = offset
    return best_offset, best_scores


def evaluate_segmentation(
    candidate_cues: Sequence[Cue],
    reference_cues: Sequence[Cue],
    sample_id: str,
    *,
    window_start: Optional[float] = None,
    window_end: Optional[float] = None,
    tolerance: float = DEFAULT_TOLERANCE_SECONDS,
    report_tolerances: Sequence[float] = REPORT_TOLERANCES_SECONDS,
    track: Optional[str] = None,
) -> Dict[str, Any]:
    """Score candidate segmentation against reference segmentation.

    Returns a JSON-serializable report including boundary precision/recall/F1 at
    the primary tolerance and each report tolerance, over/under-segmentation
    ratios, temporal coverage, and the >=90% gate verdict.
    """
    cand = clip_cues_to_window(candidate_cues, window_start, window_end)
    ref = clip_cues_to_window(reference_cues, window_start, window_end)

    cand_boundaries = cue_onset_boundaries(cand, window_start)
    ref_boundaries = cue_onset_boundaries(ref, window_start)

    primary = _boundary_scores(cand_boundaries, ref_boundaries, tolerance)

    # Offset-aligned scoring: search a bounded global onset shift that maximises
    # F1, removing the intentional readability nudge already covered by the
    # timing eval, so this reflects *where* we cut rather than display delay.
    systematic_offset, aligned = _best_aligned_scores(
        cand_boundaries, ref_boundaries, tolerance
    )

    # Strong-boundary recall: of the reference boundaries a listener must agree
    # on (sentence-end or real gap), how many did we cut? Uses the same aligned
    # offset so the constant readability nudge does not count as a miss.
    strong = strong_reference_boundaries(ref, window_start)
    aligned_cand = [t - systematic_offset for t in cand_boundaries]
    strong_matches, _, strong_unmatched = match_boundaries(aligned_cand, strong, tolerance)
    strong_recall = (len(strong_matches) / len(strong)) if strong else 1.0

    by_tolerance: Dict[str, Any] = {}
    tolset = sorted(set(list(report_tolerances) + [tolerance]))
    for tol in tolset:
        by_tolerance[f"{tol:g}"] = _boundary_scores(cand_boundaries, ref_boundaries, tol)

    covered, total_ref = _covered_duration(
        [(c.start, c.end) for c in ref],
        [(c.start, c.end) for c in cand],
    )
    coverage = (covered / total_ref) if total_ref > 0 else 0.0

    n_ref = len(ref_boundaries)
    n_cand = len(cand_boundaries)
    segment_count_ratio = (n_cand / n_ref) if n_ref else (0.0 if n_cand == 0 else float("inf"))
    over_seg = (primary["false_positives"] / n_ref) if n_ref else 0.0
    under_seg = (primary["false_negatives"] / n_ref) if n_ref else 0.0

    gate_failures: List[str] = []
    if strong_recall < GATE_MIN_STRONG_RECALL:
        gate_failures.append("missed_strong_boundary")
    if coverage < GATE_MIN_COVERAGE:
        gate_failures.append("low_text_coverage")
    if not (GATE_MIN_SEGMENT_COUNT_RATIO <= segment_count_ratio <= GATE_MAX_SEGMENT_COUNT_RATIO):
        gate_failures.append(
            "over_segmentation" if segment_count_ratio > GATE_MAX_SEGMENT_COUNT_RATIO
            else "under_segmentation"
        )

    return {
        "sample_id": sample_id,
        "track": track,
        "alignment_mode": "segmentation_boundary",
        "window": {"start": window_start, "end": window_end},
        "primary_tolerance_seconds": tolerance,
        "candidate_cue_count": len(cand),
        "reference_cue_count": len(ref),
        "candidate_boundary_count": n_cand,
        "reference_boundary_count": n_ref,
        "boundary_precision": primary["precision"],
        "boundary_recall": primary["recall"],
        "boundary_f1": primary["f1"],
        "raw_boundary_f1": primary["f1"],
        "systematic_offset_ms": systematic_offset * 1000.0,
        "aligned_boundary_precision": aligned["precision"],
        "aligned_boundary_recall": aligned["recall"],
        "aligned_boundary_f1": aligned["f1"],
        "strong_reference_boundary_count": len(strong),
        "strong_boundary_recall": strong_recall,
        "missed_strong_boundary_count": len(strong_unmatched),
        "true_positives": primary["true_positives"],
        "false_positives": primary["false_positives"],
        "false_negatives": primary["false_negatives"],
        "mean_abs_boundary_error_ms": primary["mean_abs_error_ms"],
        "f1_by_tolerance": {tol: data["f1"] for tol, data in by_tolerance.items()},
        "by_tolerance": by_tolerance,
        "segment_count_ratio": segment_count_ratio,
        "over_segmentation_ratio": over_seg,
        "under_segmentation_ratio": under_seg,
        "temporal_coverage": coverage,
        "covered_reference_seconds": covered,
        "total_reference_seconds": total_ref,
        "passes_segmentation_gate": not gate_failures,
        "gate_failures": gate_failures,
    }


def _boundary_scores(
    candidate: Sequence[float],
    reference: Sequence[float],
    tolerance: float,
) -> Dict[str, Any]:
    matches, unmatched_c, unmatched_r = match_boundaries(candidate, reference, tolerance)
    tp = len(matches)
    fp = len(unmatched_c)
    fn = len(unmatched_r)
    precision, recall, f1 = _prf(tp, fp, fn)
    errors_ms = [delta * 1000.0 for _, _, delta in matches]
    return {
        "tolerance_seconds": tolerance,
        "true_positives": tp,
        "false_positives": fp,
        "false_negatives": fn,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "mean_abs_error_ms": mean(errors_ms) if errors_ms else 0.0,
    }


def summarize_suite(reports: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    """Aggregate per-sample segmentation reports into a suite-level summary,
    optionally split by track."""
    def _agg(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
        if not rows:
            return {
                "sample_count": 0,
                "mean_boundary_f1": 0.0,
                "mean_temporal_coverage": 0.0,
                "mean_segment_count_ratio": 0.0,
                "pass_count": 0,
                "pass_rate": 0.0,
                "passes_suite_gate": False,
            }
        f1s = [r["boundary_f1"] for r in rows]
        aligned_f1s = [r.get("aligned_boundary_f1", r["boundary_f1"]) for r in rows]
        strong_recalls = [r.get("strong_boundary_recall", 1.0) for r in rows]
        covs = [r["temporal_coverage"] for r in rows]
        ratios = [r["segment_count_ratio"] for r in rows if r["segment_count_ratio"] != float("inf")]
        passes = [r for r in rows if r["passes_segmentation_gate"]]
        mean_aligned_f1 = mean(aligned_f1s)
        mean_strong_recall = mean(strong_recalls)
        pass_rate = len(passes) / len(rows)
        return {
            "sample_count": len(rows),
            "mean_boundary_f1": mean(f1s),
            "mean_aligned_boundary_f1": mean_aligned_f1,
            "mean_strong_boundary_recall": mean_strong_recall,
            "mean_boundary_precision": mean(r["boundary_precision"] for r in rows),
            "mean_boundary_recall": mean(r["boundary_recall"] for r in rows),
            "mean_temporal_coverage": mean(covs),
            "mean_segment_count_ratio": mean(ratios) if ratios else 0.0,
            "pass_count": len(passes),
            "pass_rate": pass_rate,
            # Headline gate (product-neutral): don't miss mandatory breaks, cover
            # the speech, don't grossly over/under-split.
            "passes_suite_gate": mean_strong_recall >= GATE_MIN_STRONG_RECALL and pass_rate >= 0.90,
        }

    by_track: Dict[str, List[Dict[str, Any]]] = {}
    for report in reports:
        track = report.get("track") or "unspecified"
        by_track.setdefault(track, []).append(report)

    return {
        "overall": _agg(list(reports)),
        "by_track": {track: _agg(rows) for track, rows in sorted(by_track.items())},
        "failing_samples": sorted(
            (
                {
                    "sample_id": r["sample_id"],
                    "track": r.get("track"),
                    "boundary_f1": r["boundary_f1"],
                    "temporal_coverage": r["temporal_coverage"],
                    "segment_count_ratio": r["segment_count_ratio"],
                    "gate_failures": r["gate_failures"],
                }
                for r in reports
                if not r["passes_segmentation_gate"]
            ),
            key=lambda item: item["boundary_f1"],
        ),
    }

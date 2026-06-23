from __future__ import annotations

from dataclasses import asdict, is_dataclass
import json
import math
import re
from statistics import mean, median
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

from .srt import Cue
from .vtt import Word


ACCEPTED_START_MIN_MS = -250.0
ACCEPTED_START_MAX_MS = 450.0
ACCEPTED_END_MIN_MS = -150.0
ACCEPTED_END_MAX_MS = 900.0
LONG_IDLE_HOLD_MS = 900.0
EARLY_CUTOFF_MS = 150.0
WEAK_BOUNDARY_WORDS = {
    "the", "a", "an", "to", "of", "and", "or", "but", "that", "which", "what",
    "is", "are", "was", "were", "be", "been", "being", "in", "on", "at",
    "for", "with", "from", "as", "if", "when", "where", "why", "how",
}
SHORT_FEEDBACK_MAX_WORDS = 3
CJK_START_TIME_SCORE_WEIGHT = 40.0
LATIN_TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)?|[€$£¥₩]")
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")
CJK_MIXED_TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)?|[€$£¥₩]|[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")
SENTENCE_END_RE = re.compile(r"[.!?。！？][\"')\]”’」』）]*$")
HANDOFF_END_RE = re.compile(r"[:;：；][\"')\]”’」』）]*$")
PARENTHETICAL_RE = re.compile(r"^[\(（]\s*(.{6,80}?)\s*[\)）]$")


def cue_tokens(text: str) -> List[str]:
    if CJK_RE.search(text):
        return [token.lower() for token in CJK_MIXED_TOKEN_RE.findall(text)]
    latin = [token.lower().strip("'-.?!,;:") for token in LATIN_TOKEN_RE.findall(text)]
    if latin:
        return [token for token in latin if token]
    return CJK_RE.findall(text)


def _word_dict(word: Any) -> Dict[str, Any]:
    if isinstance(word, dict):
        return word
    if is_dataclass(word):
        return asdict(word)
    return {"start": word.start, "end": word.end, "text": word.text}


def normalize_words(words: Iterable[Any]) -> List[Dict[str, Any]]:
    normalized = []
    for word in words:
        item = _word_dict(word)
        text = str(item.get("text", "")).strip()
        if not text:
            continue
        start = float(item["start"])
        end = float(item["end"])
        if end < start:
            end = start
        normalized.append({"start": start, "end": end, "text": text})
    normalized.sort(key=lambda w: (w["start"], w["end"]))
    return normalized


def offset_words(words: Iterable[Any], offset_seconds: float) -> List[Dict[str, Any]]:
    normalized = normalize_words(words)
    if offset_seconds == 0:
        return normalized
    return [
        {
            **word,
            "start": word["start"] + offset_seconds,
            "end": word["end"] + offset_seconds,
        }
        for word in normalized
    ]


def _match_by_tokens(cue: Cue, words: Sequence[Dict[str, Any]], cursor: int) -> Tuple[Optional[int], Optional[int], int, int, int]:
    tokens = cue_tokens(cue.text)
    if not tokens:
        return None, None, 0, 0, 0
    flattened: List[str] = []
    token_word_indices: List[int] = []
    for word_index, word in enumerate(words):
        for token in cue_tokens(word["text"]):
            flattened.append(token)
            token_word_indices.append(word_index)

    cursor_token = next((index for index, word_index in enumerate(token_word_indices) if word_index >= cursor), len(flattened))
    search_start = max(0, cursor_token - 6)
    cjk_token_stream = any(CJK_RE.fullmatch(token) for token in tokens)
    best_exact: Optional[Tuple[float, int, int, int, int, int]] = None
    for start in range(search_start, len(flattened)):
        if flattened[start:start + len(tokens)] == tokens:
            start_word = token_word_indices[start]
            end_word = token_word_indices[start + len(tokens) - 1]
            start_time_delta = abs(words[start_word]["start"] - cue.start)
            if not cjk_token_stream:
                score = (
                    len(tokens) * 12.0
                    - start_time_delta * 8.0
                    - abs(start_word - cursor) * 0.02
                )
                candidate = (score, start_word, end_word, 0, 0, len(tokens))
                if best_exact is None or score > best_exact[0]:
                    best_exact = candidate
                continue
            score = (
                len(tokens) * 12.0
                - start_time_delta * CJK_START_TIME_SCORE_WEIGHT
                - abs(start_word - cursor) * 0.02
            )
            candidate = (score, start_word, end_word, 0, 0, len(tokens))
            if best_exact is None or score > best_exact[0]:
                best_exact = candidate

    if len(tokens) < 4:
        if best_exact is not None:
            return best_exact[1], best_exact[2], best_exact[3], best_exact[4], best_exact[5]
        return None, None, 0, 0, 0

    if cjk_token_stream:
        min_run = min(len(tokens), max(4, math.ceil(len(tokens) * 0.35)))
        best_contiguous: Optional[Tuple[float, int, int, int, int, int]] = best_exact
        for token_offset in range(0, len(tokens) - min_run + 1):
            for start in range(search_start, len(flattened)):
                run = 0
                while (
                    token_offset + run < len(tokens)
                    and start + run < len(flattened)
                    and tokens[token_offset + run] == flattened[start + run]
                ):
                    run += 1
                if run < min_run:
                    continue
                trailing_missing = len(tokens) - token_offset - run
                start_time_delta = abs(words[token_word_indices[start]]["start"] - cue.start)
                score = (
                    run * 12.0
                    - token_offset * 1.1
                    - trailing_missing * 0.8
                    - start_time_delta * CJK_START_TIME_SCORE_WEIGHT
                    - abs(token_word_indices[start] - cursor) * 0.02
                )
                if best_contiguous is None or score > best_contiguous[0]:
                    best_contiguous = (
                        score,
                        token_word_indices[start],
                        token_word_indices[start + run - 1],
                        token_offset,
                        trailing_missing,
                        run,
                    )
        required_matches = min(len(tokens), max(4, math.ceil(len(tokens) * 0.45)))
        best_fuzzy: Optional[Tuple[float, int, int, int, int, int]] = None
        max_scan = len(tokens) * 3 + 12
        max_lookahead = 8
        for start in range(search_start, len(flattened)):
            for token_offset in range(0, len(tokens) - required_matches + 1):
                cue_index = token_offset
                matched_indices: List[int] = []
                skipped_tokens = token_offset
                leading_missing_tokens = token_offset
                for word_index in range(start, min(len(flattened), start + max_scan)):
                    match_index = None
                    for candidate_index in range(cue_index, min(len(tokens), cue_index + max_lookahead)):
                        if flattened[word_index] == tokens[candidate_index]:
                            match_index = candidate_index
                            break
                    if match_index is None:
                        continue
                    if not matched_indices:
                        leading_missing_tokens = match_index
                    skipped_tokens += match_index - cue_index
                    matched_indices.append(word_index)
                    cue_index = match_index + 1
                    if cue_index == len(tokens):
                        break
                if len(matched_indices) < required_matches:
                    continue
                trailing_missing = len(tokens) - cue_index
                coverage = len(matched_indices) / len(tokens)
                span = matched_indices[-1] - matched_indices[0] + 1
                start_time_delta = abs(words[token_word_indices[matched_indices[0]]]["start"] - cue.start)
                score = (
                    len(matched_indices) * 10.0
                    + coverage * 20.0
                    - span * 0.45
                    - skipped_tokens * 1.4
                    - leading_missing_tokens * 1.0
                    - trailing_missing * 0.6
                    - start_time_delta * CJK_START_TIME_SCORE_WEIGHT
                    - abs(token_word_indices[matched_indices[0]] - cursor) * 0.02
                )
                if best_fuzzy is None or score > best_fuzzy[0]:
                    best_fuzzy = (
                        score,
                        token_word_indices[matched_indices[0]],
                        token_word_indices[matched_indices[-1]],
                        leading_missing_tokens,
                        trailing_missing,
                        len(matched_indices),
                    )
        if best_fuzzy is not None and best_contiguous is not None:
            fuzzy_start_delta = abs(words[best_fuzzy[1]]["start"] - cue.start)
            contiguous_start_delta = abs(words[best_contiguous[1]]["start"] - cue.start)
            if best_fuzzy[3] == 0 and fuzzy_start_delta + 0.35 < contiguous_start_delta:
                return (
                    best_fuzzy[1],
                    best_fuzzy[2],
                    best_fuzzy[3],
                    best_fuzzy[4],
                    best_fuzzy[5],
                )
        if best_fuzzy is not None and (best_contiguous is None or best_fuzzy[0] >= best_contiguous[0]):
            return (
                best_fuzzy[1],
                best_fuzzy[2],
                best_fuzzy[3],
                best_fuzzy[4],
                best_fuzzy[5],
            )
        if best_contiguous is not None:
            return (
                best_contiguous[1],
                best_contiguous[2],
                best_contiguous[3],
                best_contiguous[4],
                best_contiguous[5],
            )
        return None, None, 0, 0, 0

    required_matches = min(len(tokens), max(3, math.ceil(len(tokens) * 0.50)))
    best: Optional[Tuple[float, int, int, int, int, int]] = None
    max_scan = len(tokens) * 3 + 8
    for start in range(search_start, len(flattened)):
        for token_offset in range(0, len(tokens) - required_matches + 1):
            cue_index = token_offset
            matched_indices: List[int] = []
            skipped_tokens = token_offset
            leading_missing_tokens = token_offset
            for word_index in range(start, min(len(flattened), start + max_scan)):
                if not flattened[word_index]:
                    continue
                match_index = None
                for candidate_index in range(cue_index, min(len(tokens), cue_index + 4)):
                    if flattened[word_index] == tokens[candidate_index]:
                        match_index = candidate_index
                        break
                if match_index is not None:
                    if not matched_indices:
                        leading_missing_tokens = match_index
                    skipped_tokens += match_index - cue_index
                    matched_indices.append(word_index)
                    cue_index = match_index + 1
                    if cue_index == len(tokens):
                        break
            if len(matched_indices) < required_matches:
                continue
            trailing_missing = len(tokens) - cue_index
            coverage = len(matched_indices) / len(tokens)
            span = matched_indices[-1] - matched_indices[0] + 1
            start_word = token_word_indices[matched_indices[0]]
            start_time_delta = abs(words[start_word]["start"] - cue.start)
            score = (
                coverage * 100.0
                - span * 0.55
                - skipped_tokens * 2.0
                - start_time_delta * 8.0
                - abs(token_word_indices[start] - cursor) * 0.02
            )
            if best is None or score > best[0]:
                best = (
                    score,
                    start_word,
                    token_word_indices[matched_indices[-1]],
                    leading_missing_tokens,
                    trailing_missing,
                    len(matched_indices),
                )

    if best_exact is not None:
        if best is not None:
            exact_start_delta = abs(words[best_exact[1]]["start"] - cue.start)
            fuzzy_start_delta = abs(words[best[1]]["start"] - cue.start)
            if fuzzy_start_delta + 2.0 < exact_start_delta:
                return best[1], best[2], best[3], best[4], best[5]
        return best_exact[1], best_exact[2], best_exact[3], best_exact[4], best_exact[5]
    if best is not None:
        return best[1], best[2], best[3], best[4], best[5]
    return None, None, 0, 0, 0


def _match_by_overlap(cue: Cue, words: Sequence[Dict[str, Any]]) -> Tuple[Optional[int], Optional[int]]:
    covered = [
        index for index, word in enumerate(words)
        if word["end"] >= cue.start - 0.05 and word["start"] <= cue.end + 0.05
    ]
    if not covered:
        return None, None
    return covered[0], covered[-1]


def _match_by_speech(cue: Cue, speech_segments: Sequence[Dict[str, Any]]) -> Tuple[Optional[int], Optional[int]]:
    covered = []
    for index, segment in enumerate(speech_segments):
        overlap_start = max(cue.start - 0.05, segment["start"])
        overlap_end = min(cue.end + 0.05, segment["end"])
        if overlap_end - overlap_start >= 0.05:
            covered.append(index)
    if not covered:
        return None, None
    return covered[0], covered[-1]


def is_short_feedback(text: str) -> bool:
    tokens = cue_tokens(text)
    if not tokens or len(tokens) > SHORT_FEEDBACK_MAX_WORDS:
        return False
    return len(text.strip()) <= 24


def weak_boundary(cue: Cue, next_cue: Optional[Cue]) -> bool:
    if HANDOFF_END_RE.search(cue.text.strip()):
        return False
    tokens = cue_tokens(cue.text)
    if tokens and tokens[-1] in WEAK_BOUNDARY_WORDS:
        return True
    if next_cue is not None and not SENTENCE_END_RE.search(cue.text.strip()):
        next_tokens = cue_tokens(next_cue.text)
        if next_tokens and next_tokens[0] in WEAK_BOUNDARY_WORDS:
            return True
    return False


def cjk_singleton(cue: Cue) -> bool:
    visible = "".join(ch for ch in cue.text.strip() if not ch.isspace())
    return len(visible) == 1 and bool(CJK_RE.match(visible))


def visual_annotation_reason(text: str) -> Optional[str]:
    stripped = " ".join(text.strip().split())
    match = PARENTHETICAL_RE.match(stripped)
    if not match:
        return None
    inner = match.group(1)
    if CJK_RE.search(inner) and re.search(r"\d", inner):
        return "visual_annotation"
    return None


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percentile
    low = int(math.floor(rank))
    high = int(math.ceil(rank))
    if low == high:
        return ordered[low]
    return ordered[low] * (high - rank) + ordered[high] * (rank - low)


def _metric_value(row: Dict[str, Any], field: str) -> float:
    value = row.get(field)
    return float(value) if isinstance(value, (int, float)) else 0.0


def evaluate_cues(
    cues: Sequence[Cue],
    words: Iterable[Any],
    sample_id: str,
    alignment_mode: str = "text",
) -> Dict[str, Any]:
    if alignment_mode not in {"text", "overlap", "speech"}:
        raise ValueError("alignment_mode must be 'text', 'overlap', or 'speech'")
    asr_words = normalize_words(words)
    rows: List[Dict[str, Any]] = []
    cursor = 0
    for index, cue in enumerate(cues):
        excluded_reason = visual_annotation_reason(cue.text)
        if excluded_reason is not None:
            rows.append({
                "index": cue.index,
                "start": cue.start,
                "end": cue.end,
                "duration": max(0.0, cue.end - cue.start),
                "text": cue.text,
                "reading_speed_chars_per_second": (
                    len("".join(ch for ch in cue.text if not ch.isspace())) / max(0.001, cue.end - cue.start)
                ),
                "match_method": "excluded",
                "reference_start": None,
                "reference_end": None,
                "short_feedback": False,
                "weak_boundary": False,
                "cjk_singleton": False,
                "excluded_reason": excluded_reason,
                "start_error_ms": None,
                "end_error_ms": None,
                "early_cutoff_ms": None,
                "late_hold_ms": None,
                "long_idle_hold_ms": None,
                "accepted": False,
            })
            continue

        match_start = None
        match_end = None
        leading_missing_tokens = 0
        trailing_missing_tokens = 0
        matched_token_count = 0
        match_method = "text"
        if alignment_mode == "speech":
            match_start, match_end = _match_by_speech(cue, asr_words)
            match_method = "speech"
        elif alignment_mode == "text":
            match_start, match_end, leading_missing_tokens, trailing_missing_tokens, matched_token_count = _match_by_tokens(cue, asr_words, cursor)
        if alignment_mode == "overlap" or match_start is None or match_end is None:
            match_start, match_end = _match_by_overlap(cue, asr_words)
            leading_missing_tokens = 0
            trailing_missing_tokens = 0
            matched_token_count = 0
            match_method = "speech" if alignment_mode == "speech" else "overlap"

        reference_start = None
        reference_end = None
        if match_start is not None and match_end is not None:
            reference_start = asr_words[match_start]["start"]
            reference_end = asr_words[match_end]["end"]
            if match_method == "text" and (leading_missing_tokens > 0 or trailing_missing_tokens > 0):
                matched_duration = max(0.0, reference_end - reference_start)
                estimated_token_seconds = min(0.45, max(0.12, matched_duration / max(1, matched_token_count)))
                reference_start = max(0.0, reference_start - leading_missing_tokens * estimated_token_seconds)
                reference_end = reference_end + trailing_missing_tokens * estimated_token_seconds
            cursor = max(cursor, match_end + 1)

        duration = max(0.0, cue.end - cue.start)
        readable_characters = len("".join(ch for ch in cue.text if not ch.isspace()))
        reading_speed = readable_characters / duration if duration > 0 else 0.0
        row: Dict[str, Any] = {
            "index": cue.index,
            "start": cue.start,
            "end": cue.end,
            "duration": duration,
            "text": cue.text,
            "reading_speed_chars_per_second": reading_speed,
            "match_method": match_method if reference_start is not None else "unmatched",
            "reference_start": reference_start,
            "reference_end": reference_end,
            "short_feedback": is_short_feedback(cue.text),
            "weak_boundary": weak_boundary(cue, cues[index + 1] if index + 1 < len(cues) else None),
            "cjk_singleton": cjk_singleton(cue),
        }
        if reference_start is None or reference_end is None:
            row.update({
                "start_error_ms": None,
                "end_error_ms": None,
                "early_cutoff_ms": None,
                "late_hold_ms": None,
                "long_idle_hold_ms": None,
                "accepted": False,
            })
        else:
            start_error = (cue.start - reference_start) * 1000.0
            end_error = (cue.end - reference_end) * 1000.0
            early_cutoff = max(0.0, -end_error)
            late_hold = max(0.0, end_error)
            row.update({
                "start_error_ms": start_error,
                "end_error_ms": end_error,
                "early_cutoff_ms": early_cutoff if early_cutoff > EARLY_CUTOFF_MS else 0.0,
                "late_hold_ms": late_hold,
                "long_idle_hold_ms": late_hold if late_hold > LONG_IDLE_HOLD_MS else 0.0,
                "accepted": (
                    ACCEPTED_START_MIN_MS <= start_error <= ACCEPTED_START_MAX_MS
                    and ACCEPTED_END_MIN_MS <= end_error <= ACCEPTED_END_MAX_MS
                ),
            })
        rows.append(row)
    return {
        "sample_id": sample_id,
        "cue_count": len(cues),
        "word_count": len(asr_words),
        "alignment_mode": alignment_mode,
        "cues": rows,
    }


def evaluate_cues_against_reference_cues(
    cues: Sequence[Cue],
    reference_cues: Sequence[Cue],
    sample_id: str,
) -> Dict[str, Any]:
    ordered_cues = list(cues)
    sorted_references = sorted(reference_cues, key=lambda cue: (cue.start, cue.end))
    rows: List[Dict[str, Any]] = []
    for index, cue in enumerate(ordered_cues):
        overlaps = [
            reference
            for reference in sorted_references
            if reference.end > cue.start and reference.start < cue.end
        ]
        if overlaps:
            reference_start = min(reference.start for reference in overlaps)
            reference_end = max(reference.end for reference in overlaps)
            reference_text = "\n".join(reference.text for reference in overlaps)
            match_method = "reference_overlap"
            if len(overlaps) == 1:
                reference = overlaps[0]
                group_indices = [
                    candidate_index
                    for candidate_index, candidate in enumerate(ordered_cues)
                    if candidate.end > reference.start and candidate.start < reference.end
                ]
                if len(group_indices) > 1 and index in group_indices:
                    position = group_indices.index(index)
                    if position > 0:
                        previous_candidate = ordered_cues[group_indices[position - 1]]
                        reference_start = max(reference.start, previous_candidate.end)
                    if position + 1 < len(group_indices):
                        next_candidate = ordered_cues[group_indices[position + 1]]
                        reference_end = min(reference.end, next_candidate.start)
                    if reference_end < reference_start:
                        reference_start = reference.start
                        reference_end = reference.end
        elif sorted_references:
            cue_center = (cue.start + cue.end) / 2.0
            nearest = min(
                sorted_references,
                key=lambda reference: abs(((reference.start + reference.end) / 2.0) - cue_center),
            )
            reference_start = nearest.start
            reference_end = nearest.end
            reference_text = nearest.text
            match_method = "reference_nearest"
        else:
            reference_start = None
            reference_end = None
            reference_text = ""
            match_method = "unmatched"

        duration = max(0.0, cue.end - cue.start)
        readable_characters = len("".join(ch for ch in cue.text if not ch.isspace()))
        reading_speed = readable_characters / duration if duration > 0 else 0.0
        row: Dict[str, Any] = {
            "index": cue.index,
            "start": cue.start,
            "end": cue.end,
            "duration": duration,
            "text": cue.text,
            "reading_speed_chars_per_second": reading_speed,
            "match_method": match_method,
            "reference_start": reference_start,
            "reference_end": reference_end,
            "reference_text": reference_text,
            "short_feedback": is_short_feedback(cue.text),
            "weak_boundary": weak_boundary(cue, ordered_cues[index + 1] if index + 1 < len(ordered_cues) else None),
            "cjk_singleton": cjk_singleton(cue),
        }
        if reference_start is None or reference_end is None:
            row.update({
                "start_error_ms": None,
                "end_error_ms": None,
                "early_cutoff_ms": None,
                "late_hold_ms": None,
                "long_idle_hold_ms": None,
                "accepted": False,
            })
        else:
            start_error = (cue.start - reference_start) * 1000.0
            end_error = (cue.end - reference_end) * 1000.0
            early_cutoff = max(0.0, -end_error)
            late_hold = max(0.0, end_error)
            row.update({
                "start_error_ms": start_error,
                "end_error_ms": end_error,
                "early_cutoff_ms": early_cutoff if early_cutoff > EARLY_CUTOFF_MS else 0.0,
                "late_hold_ms": late_hold,
                "long_idle_hold_ms": late_hold if late_hold > LONG_IDLE_HOLD_MS else 0.0,
                "accepted": (
                    ACCEPTED_START_MIN_MS <= start_error <= ACCEPTED_START_MAX_MS
                    and ACCEPTED_END_MIN_MS <= end_error <= ACCEPTED_END_MAX_MS
                ),
            })
        rows.append(row)
    return {
        "sample_id": sample_id,
        "cue_count": len(cues),
        "word_count": len(sorted_references),
        "alignment_mode": "reference_cue",
        "cues": rows,
    }


def summarize_report(report: Dict[str, Any]) -> Dict[str, Any]:
    rows = report["cues"]
    durations = [row["duration"] for row in rows]
    reading_speeds = [row["reading_speed_chars_per_second"] for row in rows]
    matched = [row for row in rows if row["start_error_ms"] is not None]
    accepted = [row for row in matched if row["accepted"]]
    start_errors = [abs(row["start_error_ms"]) for row in matched]
    end_errors = [abs(row["end_error_ms"]) for row in matched]
    return {
        "sample_id": report["sample_id"],
        "cue_count": report["cue_count"],
        "word_count": report["word_count"],
        "matched_cue_count": len(matched),
        "accepted_cue_count": len(accepted),
        "accepted_ratio": (len(accepted) / len(matched)) if matched else 0.0,
        "avg_duration": mean(durations) if durations else 0.0,
        "median_duration": median(durations) if durations else 0.0,
        "p90_duration": _percentile(durations, 0.90),
        "avg_reading_speed_chars_per_second": mean(reading_speeds) if reading_speeds else 0.0,
        "p90_reading_speed_chars_per_second": _percentile(reading_speeds, 0.90),
        "p90_abs_start_error_ms": _percentile(start_errors, 0.90),
        "p90_abs_end_error_ms": _percentile(end_errors, 0.90),
        "early_cutoff_count": sum(1 for row in rows if _metric_value(row, "early_cutoff_ms")),
        "late_hold_count": sum(1 for row in rows if _metric_value(row, "late_hold_ms") > LONG_IDLE_HOLD_MS),
        "long_idle_hold_count": sum(1 for row in rows if _metric_value(row, "long_idle_hold_ms")),
        "weak_boundary_count": sum(1 for row in rows if row["weak_boundary"]),
        "cjk_singleton_count": sum(1 for row in rows if row["cjk_singleton"]),
        "short_feedback_count": sum(1 for row in rows if row["short_feedback"]),
    }


def load_words_json(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict) and "words" in data:
        return normalize_words(data["words"])
    if isinstance(data, dict) and "segments" in data:
        return normalize_words(
            {
                **segment,
                "text": segment.get("text", "__speech__"),
            }
            for segment in data["segments"]
        )
    if isinstance(data, list):
        return normalize_words(data)
    raise ValueError("ASR JSON must be a list, an object with a 'words' array, or an object with a 'segments' array")

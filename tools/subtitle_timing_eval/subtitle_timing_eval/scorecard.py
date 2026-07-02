"""Moongate 字幕质量 **可量化测试标准** — 四维 scorecard。

本模块把"字幕好不好"拆成四个可独立打分（0-100）、可分别设 ≥80 门禁的维度：

1. recognition  识别准确率  —— Whisper/平台字幕把语音转成文字转得对不对
2. segmentation 分段/分词准确率 —— 首词起始、切句健康度、以及 cue 起点是否有声学活动支撑
3. translation  翻译准确率  —— 译文是否忠实、通顺、一致
4. source_decision 源决策正确率 —— "用平台字幕 / 本地 Whisper / 云端"选得对不对

设计原则（与七月 2026-06-29 的指示一致）：
- **可计算部分自动算**：词级置信度（来自 whisper words.json）、结构健康度（镜像
  `PlatformSubtitleQualityGate`）、分段边界 F1 / 强边界召回（`segmentation.py`，信息项）、
  声学活动支撑（`vad.py` 能量 VAD = "看音频波谱"）、有人工参考时的 CER/WER。
- **语义部分由 agent/LLM 裁判补**：识别/翻译的"是否真的对、是否通顺"由 agent 实际读输出、
  必要时对照在线人工字幕后，写入 `agent_*_judge.json`，本模块合并其分数。
- 某个分量缺失时按存在的分量**重新归一**，绝不用占位假分充数；纯结构无语义裁判时翻译分**封顶**，
  诚实标注"需 LLM 裁判才能认证 ≥80"。

所有 rubric 常量集中在 `RUBRIC` 顶部，便于校准。打分函数是纯函数（无 I/O），文件扫描在 CLI 层。
"""

from __future__ import annotations

import math
import re
import unicodedata
from html import escape as html_escape
from dataclasses import dataclass, field
from statistics import mean
from typing import Any, Dict, List, Optional, Sequence
from urllib.parse import quote as url_quote

from .srt import Cue
from .viewing_quality import (
    normalized_language_code,
    source_quality_report,
    is_cjk_language,
    weak_boundary_candidates,
    preview_rows,
)


# ---------------------------------------------------------------------------
# Rubric constants (single place to calibrate the standard)
# ---------------------------------------------------------------------------

EXCELLENT_GATE = 80.0  # 七月要求：各维 ≥80 视为优秀

PUNCT_RE = re.compile(r"[\s\.,!?;:'\"()\[\]{}<>~`@#$%^&*_+=|\\/。，！？；：、（）【】「」『』《》…—–·♪♫\-]")


@dataclass(frozen=True)
class _Rubric:
    # --- recognition: confidence (from words.json word probabilities) ---
    confidence_min_words: int = 24          # 少于此词数视为不可评（与 LocalASRConfidence 一致）
    confidence_floor_prob: float = 0.60     # avg_prob<=此值 → 0 分
    confidence_ceiling_prob: float = 0.95   # avg_prob>=此值 → 100 分（封顶前）
    confidence_low_prob: float = 0.50       # 单词低置信阈值
    confidence_low_ratio_free: float = 0.10 # 低置信词占比超出此值才扣分
    confidence_low_ratio_penalty: float = 120.0
    confidence_low_ratio_penalty_cap: float = 35.0

    # --- recognition / structural health penalties (镜像 SubtitleQualityScorer) ---
    bad_scalar_penalty: float = 200.0
    bad_scalar_penalty_cap: float = 45.0
    repetition_penalty: float = 70.0
    repetition_penalty_cap: float = 35.0
    romaji_loop_penalty: float = 50.0
    romaji_loop_penalty_cap: float = 30.0
    cjk_latin_leak_penalty: float = 60.0
    cjk_latin_leak_penalty_cap: float = 30.0
    low_unique_penalty: float = 40.0

    # --- recognition component weights (renormalized over present components) ---
    w_reference: float = 0.50
    w_confidence: float = 0.25
    w_structural: float = 0.25
    # 有 LLM 裁判(实际读过输出)时让它**主导**——它是真值,whisper 自信度只是代理,绝不能让
    # "自信乱码"(如 BLACKPINK avg_prob 0.85 却错)靠置信度把分数抬过门。
    w_llm_recognition: float = 0.70

    # --- segmentation ---
    seg_w_strong_recall: float = 0.40
    seg_w_aligned_f1: float = 0.30
    seg_w_coverage: float = 0.20
    seg_w_count_ratio: float = 0.10
    seg_acoustic_tolerance_s: float = 0.40   # cue onset 落入声学活动段的前后容忍窗
    seg_internal_long_cue_penalty: float = 40.0
    seg_internal_long_cue_multiplier: float = 200.0  # long_cue_ratio→扣分系数(单点校准,与上方 cap 配合)
    seg_internal_weak_boundary_penalty: float = 8.0    # 每个悬空/词中断候选
    seg_internal_weak_boundary_cap: float = 40.0
    seg_first_onset_free_tolerance_s: float = 0.25
    seg_first_onset_zero_score_error_s: float = 1.50
    # segmentation 分量权重：声学活动支撑 + 首词起始 + 内生健康度优先于参考
    # （whisper-vs-人工结构性封顶~0.65）
    seg_w_acoustic_when_present: float = 0.40
    seg_w_internal_base: float = 0.35
    seg_w_first_onset_when_present: float = 0.25
    seg_w_reference_when_present: float = 0.25
    seg_word_activity_merge_gap_s: float = 1.10

    # --- translation ---
    translation_structural_only_cap: float = 75.0  # 无 LLM 裁判时翻译分封顶（不可认证优秀）
    translation_empty_penalty: float = 60.0
    translation_repeat_penalty: float = 45.0
    translation_romaji_leak_penalty: float = 50.0
    translation_count_mismatch_penalty: float = 30.0
    translation_count_mismatch_threshold: float = 0.50  # 仅惩罚"严重"数目失配；LLM 重分段(如 43→29)是合法的
    w_llm_translation: float = 0.70  # 有 LLM 裁判时主导


RUBRIC = _Rubric()


# ---------------------------------------------------------------------------
# Small numeric helpers
# ---------------------------------------------------------------------------

def _clamp(value: float, low: float = 0.0, high: float = 100.0) -> float:
    return max(low, min(high, value))


def _linear_map(value: float, in_lo: float, in_hi: float, out_lo: float, out_hi: float) -> float:
    if in_hi <= in_lo:
        return out_lo
    t = (value - in_lo) / (in_hi - in_lo)
    return out_lo + _clamp(t, 0.0, 1.0) * (out_hi - out_lo)


def _weighted(components: Dict[str, Optional[float]], weights: Dict[str, float]) -> Optional[float]:
    """Weighted mean over the components that are present (not None), renormalized."""
    present = {k: v for k, v in components.items() if v is not None}
    if not present:
        return None
    total_w = sum(weights.get(k, 0.0) for k in present)
    if total_w <= 0:
        return mean(present.values())
    return sum(v * weights.get(k, 0.0) for k, v in present.items()) / total_w


def levenshtein(a: Sequence[Any], b: Sequence[Any]) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        current = [i]
        for j, cb in enumerate(b, start=1):
            cost = 0 if ca == cb else 1
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost))
        previous = current
    return previous[-1]


def _normalize_for_cer(text: str) -> str:
    return PUNCT_RE.sub("", text)


def _reference_text_for_language(text: str, language_code: Optional[str]) -> str:
    if not is_cjk_language(language_code):
        return text
    if not _looks_like_cjk_learning_reference(text):
        return text
    kept: List[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if _contains_cjk(stripped) or _is_numeric_reference_line(stripped):
            kept.append(stripped)
    return "\n".join(kept) if kept else text


def _looks_like_cjk_learning_reference(text: str) -> bool:
    cjk_lines = 0
    latin_only_lines = 0
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        has_cjk = _contains_cjk(stripped)
        has_latin = _contains_latin(stripped)
        if has_cjk:
            cjk_lines += 1
        elif has_latin:
            latin_only_lines += 1
    return cjk_lines >= 3 and latin_only_lines >= 3 and latin_only_lines >= cjk_lines * 0.75


def _contains_cjk(text: str) -> bool:
    return any(
        (0x3040 <= ord(ch) <= 0x309F)
        or (0x30A0 <= ord(ch) <= 0x30FF)
        or (0x4E00 <= ord(ch) <= 0x9FFF)
        for ch in text
    )


def _contains_latin(text: str) -> bool:
    return any(("A" <= ch <= "Z") or ("a" <= ch <= "z") or ("\u00c0" <= ch <= "\u024f") for ch in text)


def _is_numeric_reference_line(text: str) -> bool:
    normalized = PUNCT_RE.sub("", text)
    return bool(normalized) and all(ch.isdigit() for ch in normalized)


def _normalize_for_wer(text: str) -> List[str]:
    return [t for t in PUNCT_RE.sub(" ", text.lower()).split() if t]


def reference_similarity_score(
    candidate_text: str,
    reference_text: str,
    *,
    language_code: Optional[str],
) -> Optional[float]:
    """CER (CJK) / WER (Latin) → 0-100 similarity. None when either side is empty."""
    cjk = is_cjk_language(language_code)
    reference_text = _reference_text_for_language(reference_text, language_code)
    if cjk:
        cand = _normalize_for_cer(candidate_text)
        ref = _normalize_for_cer(reference_text)
        if not ref:
            return None
        err = levenshtein(list(cand), list(ref)) / max(1, len(ref))
    else:
        cand_t = _normalize_for_wer(candidate_text)
        ref_t = _normalize_for_wer(reference_text)
        if not ref_t:
            return None
        err = levenshtein(cand_t, ref_t) / max(1, len(ref_t))
    return _clamp((1.0 - err) * 100.0)


# ---------------------------------------------------------------------------
# Dimension result
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class DimensionScore:
    name: str
    score: Optional[float]               # None = 不可评（无任何分量）
    components: Dict[str, Optional[float]] = field(default_factory=dict)
    notes: List[str] = field(default_factory=list)
    capped: bool = False                 # 是否因缺语义裁判而被封顶
    verified: bool = False               # 是否有"金标准"分量(人工参考/LLM裁判/声学/场景真值)支撑；
                                         # 纯置信度+结构的高分是"健康但未验证"——自信乱码可能假性通过

    @property
    def passes(self) -> bool:
        return self.score is not None and self.score >= EXCELLENT_GATE

    @property
    def verified_pass(self) -> bool:
        return self.passes and self.verified


# ---------------------------------------------------------------------------
# 1. Recognition
# ---------------------------------------------------------------------------

def confidence_from_words(words: Sequence[Dict[str, Any]]) -> Optional[Dict[str, float]]:
    probs = [float(w.get("probability", 0.0)) for w in words if "probability" in w]
    if len(probs) < RUBRIC.confidence_min_words:
        return None
    avg = mean(probs)
    low_ratio = sum(1 for p in probs if p < RUBRIC.confidence_low_prob) / len(probs)
    return {"word_count": float(len(probs)), "avg_probability": avg, "low_conf_ratio": low_ratio}


def _confidence_score(stats: Optional[Dict[str, float]]) -> Optional[float]:
    if not stats:
        return None
    base = _linear_map(stats["avg_probability"], RUBRIC.confidence_floor_prob, RUBRIC.confidence_ceiling_prob, 0.0, 100.0)
    excess = max(0.0, stats["low_conf_ratio"] - RUBRIC.confidence_low_ratio_free)
    penalty = min(RUBRIC.confidence_low_ratio_penalty_cap, excess * RUBRIC.confidence_low_ratio_penalty)
    return _clamp(base - penalty)


def _structural_recognition_score(report) -> float:
    value = 100.0
    value -= min(RUBRIC.bad_scalar_penalty_cap, report.bad_scalar_ratio * RUBRIC.bad_scalar_penalty)
    value -= min(RUBRIC.repetition_penalty_cap, report.adjacent_identical_ratio * RUBRIC.repetition_penalty)
    value -= min(RUBRIC.romaji_loop_penalty_cap, report.romanized_loop_token_ratio * RUBRIC.romaji_loop_penalty)
    if report.cjk_language and report.visible_scalar_count >= 6:
        leak = max(0.0, report.latin_scalar_ratio - 0.10)
        value -= min(RUBRIC.cjk_latin_leak_penalty_cap, leak * RUBRIC.cjk_latin_leak_penalty)
    if report.cue_count >= 12 and report.unique_cue_text_ratio <= 0.25:
        value -= RUBRIC.low_unique_penalty * (0.25 - report.unique_cue_text_ratio) / 0.25
    return _clamp(value)


def _meaningful_scalar_count(text: str) -> int:
    count = 0
    for ch in text:
        if ch.isspace():
            continue
        category = unicodedata.category(ch)
        if category[0] in {"P", "S", "C"}:
            continue
        count += 1
    return count


def _looks_near_empty_transcript(cues: Sequence[Cue]) -> bool:
    if len(cues) != 1:
        return False
    return _meaningful_scalar_count(cues[0].text) <= 2


def recognition_score(
    *,
    candidate_cues: Sequence[Cue],
    language_code: Optional[str],
    words: Optional[Sequence[Dict[str, Any]]] = None,
    reference_text: Optional[str] = None,
    llm_accuracy_score: Optional[float] = None,
) -> DimensionScore:
    notes: List[str] = []
    report = source_quality_report(
        candidate_cues,
        requested_language_code=language_code,
        subtitle_language_code=language_code,
    )
    structural = _structural_recognition_score(report)
    structural_reasons = list(report.reasons)
    if _looks_near_empty_transcript(candidate_cues):
        structural = 0.0
        structural_reasons.append("nearEmptyTranscript")

    conf_stats = confidence_from_words(words) if words else None
    confidence = _confidence_score(conf_stats)
    if words and confidence is None:
        notes.append("confidence:tooFewWords")

    ref_score: Optional[float] = None
    if reference_text:
        candidate_text = "\n".join(c.text for c in candidate_cues)
        ref_score = reference_similarity_score(candidate_text, reference_text, language_code=language_code)
        if ref_score is None:
            notes.append("reference:empty")

    components: Dict[str, Optional[float]] = {
        "reference": ref_score,
        "confidence": confidence,
        "structural": structural,
        "llm": llm_accuracy_score,
    }
    weights = {
        "reference": RUBRIC.w_reference,
        "confidence": RUBRIC.w_confidence,
        "structural": RUBRIC.w_structural,
        "llm": RUBRIC.w_llm_recognition,
    }
    score = _weighted(components, weights)
    if (
        score is not None
        and ref_score is None
        and llm_accuracy_score is not None
        and llm_accuracy_score < EXCELLENT_GATE
        and score > llm_accuracy_score
    ):
        score = llm_accuracy_score
        notes.append("llm:semanticCap")
    if score is None:
        notes.append("recognition:noComponents")
    if structural_reasons:
        notes.append("structuralReasons:" + ",".join(sorted(set(structural_reasons))))
    verified = ref_score is not None or llm_accuracy_score is not None
    if not verified:
        notes.append("unverified:needsReferenceOrLLM")
    return DimensionScore("recognition", score, components, notes, verified=verified)


# ---------------------------------------------------------------------------
# 2. Segmentation
# ---------------------------------------------------------------------------

def acoustic_boundary_agreement(
    cue_onsets: Sequence[float],
    speech_segments: Sequence[Dict[str, float]],
    *,
    tolerance: float = RUBRIC.seg_acoustic_tolerance_s,
) -> Optional[float]:
    """每个 cue 起点是否有语音活动支撑的比例 → 0-100。

    语音段来自能量 VAD（`vad.py`）。能量 VAD 只能可靠说明某个时间点附近有没有声音/语音活动；
    它不能判断连续讲话或唱歌里的每个字幕切点是否等同于人类句边界。句边界质量由 word timing
    first-onset 和内生弱边界检查补足。"""
    if not cue_onsets or not speech_segments:
        return None
    intervals: List[tuple[float, float]] = []
    for seg in speech_segments:
        try:
            start = float(seg["start"])
            end = float(seg["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(start) and math.isfinite(end) and end >= start:
            intervals.append((start - tolerance, end + tolerance))
    return _onset_interval_agreement(cue_onsets, intervals)


def timed_word_activity_agreement(
    cue_onsets: Sequence[float],
    words: Optional[Sequence[Dict[str, Any]]],
    *,
    tolerance: float = RUBRIC.seg_acoustic_tolerance_s,
    merge_gap: float = RUBRIC.seg_word_activity_merge_gap_s,
) -> Optional[float]:
    """Score cue onsets against continuous timed-word activity spans.

    Energy VAD can become sparse on quiet lecture audio because it keys off local RMS peaks.
    Timed ASR words are not a sentence-boundary oracle, but they are aligned speech evidence.
    We use them only as a fallback inside `segmentation_score` when acoustic VAD exists but
    under-covers otherwise continuous speech.
    """
    if not cue_onsets or not words:
        return None

    intervals: List[tuple[float, float]] = []
    for word in words:
        if not isinstance(word, dict):
            continue
        try:
            start = float(word.get("start"))
            end = float(word.get("end"))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(start) or not math.isfinite(end):
            continue
        if end < start:
            continue
        if end == start:
            end = start + 0.01
        intervals.append((start, end))

    if not intervals:
        return None
    intervals.sort()
    merged: List[tuple[float, float]] = []
    for start, end in intervals:
        if merged and start - merged[-1][1] <= merge_gap:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    padded = [(start - tolerance, end + tolerance) for start, end in merged]
    return _onset_interval_agreement(cue_onsets, padded)


def _onset_interval_agreement(
    cue_onsets: Sequence[float],
    intervals: Sequence[tuple[float, float]],
) -> Optional[float]:
    if not intervals:
        return None
    hits = 0
    for onset in cue_onsets:
        if any(start <= onset <= end for start, end in intervals):
            hits += 1
    return _clamp(hits / len(cue_onsets) * 100.0)


def _first_word_start(words: Optional[Sequence[Dict[str, Any]]]) -> Optional[float]:
    if not words:
        return None
    starts: List[float] = []
    for word in words:
        if not isinstance(word, dict):
            continue
        try:
            start = float(word.get("start"))
        except (TypeError, ValueError):
            continue
        if math.isfinite(start):
            starts.append(start)
    return min(starts) if starts else None


def _first_speech_start(speech_segments: Optional[Sequence[Dict[str, float]]]) -> Optional[float]:
    if not speech_segments:
        return None
    starts: List[float] = []
    for segment in speech_segments:
        try:
            start = float(segment["start"])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(start):
            starts.append(start)
    return min(starts) if starts else None


def _opening_intro_noise_prefix(words: Optional[Sequence[Dict[str, Any]]], cutoff: float) -> List[Dict[str, Any]]:
    if not words:
        return []
    prefix = _words_before(words, cutoff)
    if not prefix:
        return []
    end = (
        _bgm_intro_noise_prefix_end(prefix)
        or _credit_intro_noise_prefix_end(prefix)
        or _repeated_marker_intro_noise_prefix_end(prefix)
        or 0
    )
    return prefix[:end] if end > 0 else []


def _bgm_intro_noise_prefix_end(prefix: Sequence[Dict[str, Any]]) -> Optional[int]:
    normalized = ""
    for index, word in enumerate(prefix):
        start = _word_start(word)
        if start is not None and start > 20.5:
            break
        token = _normalized_latin_word_text(word)
        if token not in {"B", "G", "M", "BG", "GM", "BGM"}:
            break
        normalized += token
        if normalized == "BGM":
            return index + 1
        if not "BGM".startswith(normalized):
            break
    return None


def _credit_intro_noise_prefix_end(prefix: Sequence[Dict[str, Any]]) -> Optional[int]:
    full_normalized = "".join(_normalized_credit_token(str(word.get("text", ""))) for word in prefix)
    markers = ("作詞", "作词", "作曲", "編曲", "编曲", "初音ミク")
    marker_positions = [full_normalized.find(marker) for marker in markers if marker in full_normalized]
    if marker_positions and min(marker_positions) <= 6:
        return len(prefix)

    normalized = ""
    end = 0
    saw_marker = False
    trailing_name_characters = 0
    for word in prefix:
        token = _normalized_credit_token(str(word.get("text", "")))
        if not token and saw_marker:
            end += 1
            continue
        if _is_credit_marker_token(token):
            normalized += token
            saw_marker = True
            trailing_name_characters = 0
            end += 1
            continue
        if saw_marker and 0 < len(token) <= 2 and trailing_name_characters + len(token) <= 4:
            normalized += token
            trailing_name_characters += len(token)
            end += 1
            continue
        break
    if not saw_marker or end <= 0:
        return None
    if any(marker in normalized for marker in markers):
        return end
    return None


def _repeated_marker_intro_noise_prefix_end(prefix: Sequence[Dict[str, Any]]) -> Optional[int]:
    tokens: List[str] = []
    end = 0
    for word in prefix:
        token = _short_marker_loop_token(str(word.get("text", "")))
        if token is None:
            break
        tokens.append(token.lower())
        end += 1
    if len(tokens) < 8:
        return None
    unique_ratio = len(set(tokens)) / len(tokens)
    if unique_ratio <= 0.45:
        return end
    return None


def _word_start(word: Dict[str, Any]) -> Optional[float]:
    try:
        start = float(word.get("start"))
    except (TypeError, ValueError):
        return None
    return start if math.isfinite(start) else None


def _normalized_latin_word_text(word: Dict[str, Any]) -> str:
    return _normalized_latin_text(str(word.get("text", "")))


def _normalized_latin_text(text: str) -> str:
    return "".join(ch.upper() for ch in text if ("A" <= ch <= "Z") or ("a" <= ch <= "z"))


def _normalized_credit_token(text: str) -> str:
    return "".join(
        ch
        for ch in text
        if ("\u3040" <= ch <= "\u30ff") or ("\u4e00" <= ch <= "\u9fff")
    )


def _is_credit_marker_token(token: str) -> bool:
    if not token:
        return False
    markers = ("作詞", "作词", "作曲", "編曲", "编曲", "初音ミク")
    marker_parts = {"作", "詞", "词", "曲", "編", "编", "初", "音", "ミ", "ク"}
    return token in marker_parts or any(marker in token for marker in markers)


def _short_marker_loop_token(text: str) -> Optional[str]:
    stripped = text.strip()
    if not stripped:
        return None
    if any(marker in stripped for marker in ("*", "♪", "♫")):
        return re.sub(r"\s+", "", stripped)
    latin = _normalized_latin_text(stripped)
    if 0 < len(latin) <= 4:
        return latin
    return None


def first_onset_alignment_score(
    candidate_cues: Sequence[Cue],
    *,
    words: Optional[Sequence[Dict[str, Any]]] = None,
    speech_segments: Optional[Sequence[Dict[str, float]]] = None,
    tolerance: float = RUBRIC.seg_first_onset_free_tolerance_s,
    zero_score_error: float = RUBRIC.seg_first_onset_zero_score_error_s,
) -> Optional[Dict[str, Any]]:
    """Score how close the first subtitle cue starts to the first spoken word.

    This targets the user-visible opening problem: the first subtitle should appear when the
    speaker says the first word, not after the first phrase has already started. Timed ASR words
    are preferred because they are the same evidence used by the local-ASR retimer; energy VAD
    speech segments are a fallback when word timestamps are absent.
    """
    if not candidate_cues:
        return None
    first_cue_start = min(float(cue.start) for cue in candidate_cues)
    ignored_intro_prefix = _opening_intro_noise_prefix(words, first_cue_start)
    scoring_words = list(words or [])
    if ignored_intro_prefix:
        scoring_words = scoring_words[len(ignored_intro_prefix):]
    reference = _first_word_start(scoring_words)
    source = "words"
    if reference is None:
        reference = _first_speech_start(speech_segments)
        source = "speech"
    if reference is None:
        return None

    signed_error = first_cue_start - reference
    # Energy VAD is an under-approximation on music, quiet dialogue, and sound-effect cues.
    # Without word evidence, a cue that starts before the first detected speech is not proof
    # of bad first-onset timing; it is only weak evidence that VAD missed earlier activity.
    if source == "speech" and signed_error < -tolerance:
        return None
    absolute_error = abs(signed_error)
    if absolute_error <= tolerance:
        score = 100.0
    else:
        score = _linear_map(absolute_error, tolerance, zero_score_error, 100.0, 0.0)
    prefix_words = _words_before(scoring_words, first_cue_start)
    prefix_start = _first_word_start(prefix_words)
    prefix_text = _prefix_text_preview(prefix_words)
    ignored_prefix_start = _first_word_start(ignored_intro_prefix)
    ignored_prefix_text = _prefix_text_preview(ignored_intro_prefix)
    return {
        "score": _clamp(score),
        "error_seconds": signed_error,
        "absolute_error_seconds": absolute_error,
        "cue_start_seconds": first_cue_start,
        "reference_start_seconds": reference,
        "reference_source": source,
        "prefix_word_count": len(prefix_words),
        "prefix_seconds": max(0.0, first_cue_start - prefix_start) if prefix_start is not None else 0.0,
        "prefix_text_preview": prefix_text,
        "ignored_intro_prefix_word_count": len(ignored_intro_prefix),
        "ignored_intro_prefix_seconds": (
            max(0.0, first_cue_start - ignored_prefix_start) if ignored_prefix_start is not None else 0.0
        ),
        "ignored_intro_prefix_text_preview": ignored_prefix_text,
    }


def _words_before(words: Optional[Sequence[Dict[str, Any]]], cutoff: float) -> List[Dict[str, Any]]:
    if not words:
        return []
    result: List[Dict[str, Any]] = []
    for word in words:
        if not isinstance(word, dict):
            continue
        try:
            start = float(word.get("start"))
        except (TypeError, ValueError):
            continue
        if math.isfinite(start) and start < cutoff:
            result.append(word)
    return result


def _prefix_text_preview(words: Sequence[Dict[str, Any]], max_tokens: int = 12) -> str:
    tokens: List[str] = []
    for word in words[:max_tokens]:
        text = str(word.get("text", "")).strip()
        if text:
            tokens.append(text)
    return " ".join(tokens)


def _internal_segmentation_score(
    cues: Sequence[Cue],
    *,
    language_code: Optional[str],
) -> float:
    if not cues:
        return 0.0
    value = 100.0
    report = source_quality_report(
        cues, requested_language_code=language_code, subtitle_language_code=language_code
    )
    if report.long_cue_ratio > 0:
        value -= min(RUBRIC.seg_internal_long_cue_penalty, report.long_cue_ratio * RUBRIC.seg_internal_long_cue_multiplier)
    rows = preview_rows(cues, [], preview_seconds=float("inf"))
    weak = weak_boundary_candidates(rows, language_code=language_code)
    if cues:
        density = len(weak) / len(cues)
        value -= min(RUBRIC.seg_internal_weak_boundary_cap, density * 100.0 * RUBRIC.seg_internal_weak_boundary_penalty / 8.0)
    return _clamp(value)


def segmentation_score(
    *,
    candidate_cues: Sequence[Cue],
    language_code: Optional[str],
    reference_report: Optional[Dict[str, Any]] = None,
    speech_segments: Optional[Sequence[Dict[str, float]]] = None,
    words: Optional[Sequence[Dict[str, Any]]] = None,
    allow_speech_first_onset: bool = True,
) -> DimensionScore:
    notes: List[str] = []
    internal = _internal_segmentation_score(candidate_cues, language_code=language_code)

    acoustic: Optional[float] = None
    if speech_segments:
        onsets = [c.start for c in candidate_cues]
        acoustic = acoustic_boundary_agreement(onsets, speech_segments)
        timed_word_activity = timed_word_activity_agreement(onsets, words)
        if timed_word_activity is not None and (acoustic is None or timed_word_activity > acoustic):
            acoustic = timed_word_activity
            notes.append("acoustic:timedWordActivityFallback")
        if acoustic is None:
            notes.append("acoustic:unavailable")

    first_onset_speech_segments = speech_segments if allow_speech_first_onset or words else None
    first_onset_payload = first_onset_alignment_score(
        candidate_cues,
        words=words,
        speech_segments=first_onset_speech_segments,
    )
    first_onset = first_onset_payload["score"] if first_onset_payload else None
    first_onset_prefix_words: Optional[float] = None
    first_onset_prefix_seconds: Optional[float] = None
    first_onset_ignored_intro_words: Optional[float] = None
    first_onset_ignored_intro_seconds: Optional[float] = None
    if first_onset_payload:
        first_onset_prefix_words = float(first_onset_payload["prefix_word_count"])
        first_onset_prefix_seconds = float(first_onset_payload["prefix_seconds"])
        first_onset_ignored_intro_words = float(first_onset_payload["ignored_intro_prefix_word_count"])
        first_onset_ignored_intro_seconds = float(first_onset_payload["ignored_intro_prefix_seconds"])
        notes.append(
            "firstOnsetError="
            f"{float(first_onset_payload['error_seconds']):.3f}s,"
            f"source={first_onset_payload['reference_source']}"
        )
        if first_onset_payload["ignored_intro_prefix_word_count"]:
            notes.append(
                "firstOnsetIgnoredIntro="
                f"{int(first_onset_payload['ignored_intro_prefix_word_count'])} words/"
                f"{float(first_onset_payload['ignored_intro_prefix_seconds']):.3f}s:"
                f"text={first_onset_payload['ignored_intro_prefix_text_preview']}"
            )
        if first_onset_payload["prefix_word_count"]:
            notes.append(
                "firstOnsetPrefix="
                f"{int(first_onset_payload['prefix_word_count'])} words/"
                f"{float(first_onset_payload['prefix_seconds']):.3f}s:"
                f"text={first_onset_payload['prefix_text_preview']}"
            )
    elif speech_segments and not words and not allow_speech_first_onset:
        notes.append("firstOnset:speechFallbackDisabled")

    # 人工参考的边界 F1 只作信息备注，**不计入分数也不算验证**：whisper 的切句风格天然不同于
    # 人工字幕(已证实结构性封顶~0.65,风格差异非缺陷),拿它当门会让分段永远不达标。公正的外部验证
    # 是声学活动支撑 + first-onset + 内生弱边界检查。
    if reference_report:
        strong = float(reference_report.get("strong_boundary_recall", 0.0))
        aligned = float(reference_report.get("aligned_boundary_f1", reference_report.get("boundary_f1", 0.0)))
        notes.append(f"refInfo:strongRecall={strong:.2f},alignedF1={aligned:.2f}(notScored,styleCapped)")

    components: Dict[str, Optional[float]] = {
        "acoustic": acoustic,
        "first_onset": first_onset,
        "first_onset_prefix_words": first_onset_prefix_words,
        "first_onset_prefix_seconds": first_onset_prefix_seconds,
        "first_onset_ignored_intro_words": first_onset_ignored_intro_words,
        "first_onset_ignored_intro_seconds": first_onset_ignored_intro_seconds,
        "internal": internal,
    }
    weights = {
        "acoustic": RUBRIC.seg_w_acoustic_when_present,
        "first_onset": RUBRIC.seg_w_first_onset_when_present,
        "internal": RUBRIC.seg_w_internal_base,
    }
    score = _weighted(components, weights)
    verified = acoustic is not None
    if not verified:
        notes.append("unverified:needsAcoustic")
    return DimensionScore("segmentation", score, components, notes, verified=verified)


# ---------------------------------------------------------------------------
# 3. Translation
# ---------------------------------------------------------------------------

def _structural_translation_score(
    source_cues: Sequence[Cue],
    translated_cues: Sequence[Cue],
) -> float:
    if not translated_cues:
        return 0.0
    value = 100.0
    texts = [c.text.strip() for c in translated_cues]
    non_empty = [t for t in texts if t]
    empty_ratio = 1.0 - (len(non_empty) / len(texts) if texts else 0.0)
    value -= min(RUBRIC.translation_empty_penalty, empty_ratio * RUBRIC.translation_empty_penalty * 2.0)

    repeats = sum(1 for a, b in zip(non_empty, non_empty[1:]) if a == b)
    if len(non_empty) > 1:
        repeat_ratio = repeats / (len(non_empty) - 1)
        if repeat_ratio >= 0.20:
            value -= RUBRIC.translation_repeat_penalty

    romaji_leaks = sum(1 for t in non_empty if re.search(r"\b(?:ni|nani|dare|carano|ana|me|ani)\b", t, re.I))
    if non_empty and romaji_leaks / len(non_empty) >= 0.05:
        value -= RUBRIC.translation_romaji_leak_penalty

    if source_cues:
        diff = abs(len(translated_cues) - len(source_cues)) / max(1, len(source_cues))
        if diff > RUBRIC.translation_count_mismatch_threshold:
            value -= min(RUBRIC.translation_count_mismatch_penalty, diff * RUBRIC.translation_count_mismatch_penalty)
    return _clamp(value)


def translation_score(
    *,
    source_cues: Sequence[Cue],
    translated_cues: Sequence[Cue],
    llm_translation_score: Optional[float] = None,
) -> DimensionScore:
    notes: List[str] = []
    structural = _structural_translation_score(source_cues, translated_cues)
    capped = False
    if llm_translation_score is None:
        score = min(structural, RUBRIC.translation_structural_only_cap)
        if structural > RUBRIC.translation_structural_only_cap:
            capped = True
            notes.append("cappedNeedsLLMJudge")
    else:
        score = _weighted(
            {"llm": llm_translation_score, "structural": structural},
            {"llm": RUBRIC.w_llm_translation, "structural": 1.0 - RUBRIC.w_llm_translation},
        )
    return DimensionScore(
        "translation",
        score,
        {"structural": structural, "llm": llm_translation_score},
        notes,
        capped=capped,
        verified=llm_translation_score is not None,
    )


# ---------------------------------------------------------------------------
# 4. Source decision
# ---------------------------------------------------------------------------

def predicted_decision_for_gate(
    *,
    platform_usable: Optional[bool],
    platform_available: bool,
    local_asr_available: bool,
    cloud_available: bool,
    manual_available: bool = False,
    platform_verdict: Optional[str] = None,
    local_asr_verdict: Optional[str] = None,
) -> str:
    """Python 侧 `autoBest` 决策镜像（M1 后由 Swift/C# 引擎取代为真值）。"""
    if manual_available:
        return "manual"
    local_asr_below_floor = (
        local_asr_verdict is not None
        and _subtitle_verdict_rank(local_asr_verdict) < _subtitle_verdict_rank("usable")
    )
    if platform_available and platform_usable:
        if (
            local_asr_available
            and _subtitle_verdict_rank(platform_verdict) < _subtitle_verdict_rank("usable")
        ):
            if local_asr_below_floor and cloud_available:
                return "cloudASR"
            return "localASR"
        return "platform"
    if local_asr_available:
        if local_asr_below_floor and cloud_available:
            return "cloudASR"
        return "localASR"
    if cloud_available:
        return "cloudASR"
    if platform_available:
        return "platform"   # 不可用但无更好选择 → 沿用并提示
    return "none"


def _subtitle_verdict_rank(value: Optional[str]) -> int:
    if not value:
        return _subtitle_verdict_rank("good")
    normalized = str(value).strip()
    ranks = {
        "unusable": 0,
        "lowConfidence": 1,
        "lowconfidence": 1,
        "usable": 2,
        "good": 3,
        "excellent": 4,
    }
    return ranks.get(normalized, ranks.get(normalized.lower(), 3))


def source_decision_score(scenarios: Sequence[Dict[str, Any]]) -> DimensionScore:
    """对带"已知正确答案"的场景集打分：决策正确率 → 0-100。"""
    if not scenarios:
        return DimensionScore("source_decision", None, {}, ["noScenarios"])
    correct = 0
    failures: List[str] = []
    for sc in scenarios:
        predicted = predicted_decision_for_gate(
            platform_usable=sc.get("platform_usable"),
            platform_available=bool(sc.get("platform_available", False)),
            local_asr_available=bool(sc.get("local_asr_available", False)),
            cloud_available=bool(sc.get("cloud_available", False)),
            manual_available=bool(sc.get("manual_available", False)),
            platform_verdict=sc.get("platform_verdict"),
            local_asr_verdict=sc.get("local_asr_verdict"),
        )
        expected = sc.get("expected_decision")
        if predicted == expected:
            correct += 1
        else:
            failures.append(f"{sc.get('id', '?')}:exp={expected},got={predicted}")
    score = correct / len(scenarios) * 100.0
    notes = [f"{correct}/{len(scenarios)} correct"]
    if failures:
        notes.append("failures:" + "; ".join(failures[:8]))
    return DimensionScore(
        "source_decision",
        score,
        {"accuracy": score, "scenario_count": float(len(scenarios)), "correct_count": float(correct)},
        notes,
        verified=True,
    )


# ---------------------------------------------------------------------------
# Aggregation + render
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SampleScorecard:
    sample_id: str
    language_code: str
    category: str
    dimensions: Dict[str, DimensionScore]
    scored_source_kind: str = "local-asr"
    scored_source_path: Optional[str] = None
    audio_review_paths: List[str] = field(default_factory=list)
    evidence_risks: List[str] = field(default_factory=list)


def suite_summary(samples: Sequence[SampleScorecard], source_decision: Optional[DimensionScore]) -> Dict[str, Any]:
    dim_names = ["recognition", "segmentation", "translation"]
    per_dim: Dict[str, Any] = {}
    for name in dim_names:
        dims = [s.dimensions[name] for s in samples if name in s.dimensions and s.dimensions[name].score is not None]
        scored = [d.score for d in dims]
        verified = [d.score for d in dims if d.verified]
        # Ceiling, not floor: "≥60% 样本有金标准支撑" must round up, otherwise e.g. 12 scored
        # would enforce only 7 (58.3%) < 60%.
        required_verified = max(1, math.ceil(0.6 * len(scored))) if scored else 0
        evidence_quality = _verified_evidence_quality(dims)
        strong_verified_scores = [
            float(d.score)
            for d in dims
            if d.score is not None and _is_strong_verified_evidence(d)
        ]
        per_dim[name] = {
            "mean": round(mean(scored), 1) if scored else None,
            "scored_samples": len(scored),
            "verified_samples": len(verified),
            "required_verified_samples": required_verified,
            "additional_verified_needed": max(0, required_verified - len(verified)),
            "strong_verified_samples": len(strong_verified_scores),
            "strict_additional_verified_needed": max(0, required_verified - len(strong_verified_scores)),
            "strict_verified_mean": round(mean(strong_verified_scores), 1) if strong_verified_scores else None,
            "evidence_quality": evidence_quality,
            "verified_mean": round(mean(verified), 1) if verified else None,
            "pass_count": sum(1 for v in scored if v >= EXCELLENT_GATE),
            "verified_pass_count": sum(1 for d in dims if d.verified_pass),
            # 真正达标 = 已验证样本均分≥80 且验证覆盖足够(≥60%样本有金标准支撑)
            "passes_gate": bool(verified)
            and mean(verified) >= EXCELLENT_GATE
            and len(verified) >= required_verified,
            "passes_gate_unverified": bool(scored) and mean(scored) >= EXCELLENT_GATE,
        }
    if source_decision is not None:
        scenario_count = int(source_decision.components.get("scenario_count") or 0)
        if scenario_count <= 0 and source_decision.score is not None:
            scenario_count = 1
        correct_count = int(source_decision.components.get("correct_count") or 0)
        if correct_count <= 0 and source_decision.passes:
            correct_count = scenario_count
        verified_count = scenario_count if source_decision.verified else 0
        per_dim["source_decision"] = {
            "mean": round(source_decision.score, 1) if source_decision.score is not None else None,
            "scored_samples": scenario_count,
            "verified_samples": verified_count,
            "required_verified_samples": scenario_count,
            "additional_verified_needed": max(0, scenario_count - verified_count),
            "strong_verified_samples": verified_count,
            "strict_additional_verified_needed": max(0, scenario_count - verified_count),
            "strict_verified_mean": (
                round(source_decision.score, 1)
                if source_decision.verified and source_decision.score is not None
                else None
            ),
            "evidence_quality": {
                "non_judge_verified_count": verified_count,
                "traceable_judge_count": 0,
                "untraceable_judge_count": 0,
            },
            "verified_mean": round(source_decision.score, 1) if source_decision.score is not None else None,
            "pass_count": correct_count,
            "verified_pass_count": correct_count if source_decision.verified else 0,
            "passes_gate": source_decision.verified_pass,
            "passes_gate_unverified": source_decision.passes,
        }
    overall_means = [d["mean"] for d in per_dim.values() if d["mean"] is not None]
    return {
        "excellent_gate": EXCELLENT_GATE,
        "sample_count": len(samples),
        "dimensions": per_dim,
        "overall_mean": round(mean(overall_means), 1) if overall_means else None,
        "all_dimensions_pass": all(d["passes_gate"] for d in per_dim.values()) if per_dim else False,
        "all_dimensions_pass_unverified": all(d["passes_gate_unverified"] for d in per_dim.values()) if per_dim else False,
    }


def _verified_evidence_quality(dims: Sequence[DimensionScore]) -> Dict[str, int]:
    quality = {
        "non_judge_verified_count": 0,
        "traceable_judge_count": 0,
        "untraceable_judge_count": 0,
    }
    for dim in dims:
        if not dim.verified:
            continue
        notes = set(dim.notes)
        if "judgeEvidence:sourceUrlsMissing" in notes:
            quality["untraceable_judge_count"] += 1
        elif "judgeEvidence:sourceUrls" in notes or "judgeEvidence:evidenceUrls" in notes:
            quality["traceable_judge_count"] += 1
        else:
            quality["non_judge_verified_count"] += 1
    return quality


def quality_backlog(
    samples: Sequence[SampleScorecard],
    source_decision: Optional[DimensionScore],
    *,
    max_items: int = 30,
) -> List[Dict[str, Any]]:
    """Return a deterministic prioritized list of subtitle-quality work items."""
    items: List[Dict[str, Any]] = []
    for sample in samples:
        recognition = sample.dimensions.get("recognition")
        if recognition and recognition.score is not None:
            if recognition.score < EXCELLENT_GATE:
                if recognition.verified:
                    items.append(_backlog_item(
                        sample,
                        "recognition_below_gate",
                        "recognition",
                        EXCELLENT_GATE - recognition.score,
                        recognition.score,
                        _evidence(recognition.notes),
                        "Fix the proven low-recognition source or route to a better ASR/source option.",
                    ))
                else:
                    items.append(_backlog_item(
                        sample,
                        "recognition_low_auto_score_unverified",
                        "recognition",
                        (EXCELLENT_GATE - recognition.score) + 8.0,
                        recognition.score,
                        _evidence(recognition.notes),
                        "Add a human reference or numeric agent recognition judge before tuning production behavior.",
                    ))
            elif not recognition.verified:
                items.append(_backlog_item(
                    sample,
                    "recognition_unverified",
                    "recognition",
                    12.0,
                    recognition.score,
                    _evidence(recognition.notes),
                    "Add human subtitle reference or agent recognition judge before counting this sample as human-level evidence.",
                ))

        segmentation = sample.dimensions.get("segmentation")
        if segmentation:
            first_onset = segmentation.components.get("first_onset")
            if first_onset is not None and first_onset < EXCELLENT_GATE:
                first_onset_evidence = _evidence([n for n in segmentation.notes if n.startswith("firstOnset")])
                issue = _first_onset_issue(segmentation.components, first_onset_evidence)
                items.append(_backlog_item(
                    sample,
                    issue,
                    "segmentation",
                    (EXCELLENT_GATE - float(first_onset)) + 15.0,
                    float(first_onset),
                    first_onset_evidence,
                    _first_onset_action(issue),
                ))
            if segmentation.score is not None and segmentation.score < EXCELLENT_GATE:
                items.append(_backlog_item(
                    sample,
                    "segmentation_below_gate",
                    "segmentation",
                    EXCELLENT_GATE - segmentation.score,
                    segmentation.score,
                    _evidence(segmentation.notes),
                    "Inspect cue length, weak boundaries, acoustic evidence, and first-onset diagnostics.",
                ))
            if segmentation.score is not None and not segmentation.verified:
                items.append(_backlog_item(
                    sample,
                    "segmentation_unverified",
                    "segmentation",
                    8.0,
                    segmentation.score,
                    _evidence(segmentation.notes),
                    "Generate acoustic VAD evidence before treating segmentation as verified.",
                ))

        translation = sample.dimensions.get("translation")
        if translation:
            if translation.score is not None and translation.score < EXCELLENT_GATE:
                items.append(_backlog_item(
                    sample,
                    "translation_below_gate",
                    "translation",
                    EXCELLENT_GATE - translation.score,
                    translation.score,
                    _evidence(translation.notes),
                    "Compare the translated subtitle against human translation or add an agent translation judge.",
                ))
            if translation.capped or not translation.verified:
                items.append(_backlog_item(
                    sample,
                    "translation_unverified",
                    "translation",
                    10.0,
                    translation.score,
                    _evidence(translation.notes),
                    "Add a human/agent translation judge; structural checks alone cannot certify translation quality.",
                ))

    if source_decision and not source_decision.verified_pass:
        items.append({
            "issue": "source_decision_below_gate",
            "sample_id": "source_decision_scenarios",
            "language_code": "all",
            "category": "scenario",
            "dimension": "source_decision",
            "severity": round(EXCELLENT_GATE - float(source_decision.score or 0.0), 3),
            "score": source_decision.score,
            "evidence": _evidence(source_decision.notes),
            "action": "Fix source-decision scenario failures before trusting platform-to-Whisper switching metrics.",
        })

    items.sort(key=lambda item: (-float(item["severity"]), item["sample_id"], item["issue"]))
    return items[:max_items]


def recognition_review_queue(samples: Sequence[SampleScorecard]) -> List[Dict[str, Any]]:
    """Return unverified recognition samples as an actionable evidence-gathering queue.

    This queue is intentionally separate from the score. It tells reviewers what evidence is
    missing, but it never turns prompts, platform captions, or automatic confidence into verified
    recognition proof.
    """
    items: List[Dict[str, Any]] = []
    for sample in samples:
        recognition = sample.dimensions.get("recognition")
        if recognition is None or recognition.score is None or recognition.verified:
            continue

        reason, priority, action = _recognition_review_reason(sample, recognition)
        items.append({
            "sample_id": sample.sample_id,
            "language_code": sample.language_code,
            "category": sample.category,
            "score": round(recognition.score, 3),
            "source_kind": sample.scored_source_kind,
            "source_path": sample.scored_source_path,
            "prompt_path": _recognition_prompt_path(sample.scored_source_path),
            "audio_review_paths": list(sample.audio_review_paths),
            "reason": reason,
            "priority": priority,
            "evidence": _evidence(recognition.notes),
            "review_risks": list(sample.evidence_risks),
            "action": action,
        })
    items.sort(key=lambda item: (item["priority"], item["language_code"], item["sample_id"]))
    return items


def recognition_evidence_plan(
    samples: Sequence[SampleScorecard],
    *,
    minimum_accuracy_score: float = EXCELLENT_GATE,
) -> Dict[str, Any]:
    """Recommend the smallest recognition evidence batch needed to fill coverage.

    This is a workflow artifact only. It never marks recognition verified; it picks the safest
    next samples to review so the coverage gate can be filled without overfitting to low automatic
    scores or counting generated prompts as proof.
    """
    recognition_dims = [
        s.dimensions["recognition"]
        for s in samples
        if "recognition" in s.dimensions and s.dimensions["recognition"].score is not None
    ]
    scored = [float(d.score) for d in recognition_dims if d.score is not None]
    verified_scores = [float(d.score) for d in recognition_dims if d.score is not None and d.verified]
    required_verified = max(1, int(0.6 * len(scored))) if scored else 0
    additional_needed = max(0, required_verified - len(verified_scores))
    evidence_quality = _verified_evidence_quality(recognition_dims)
    strong_verified_scores = [
        float(d.score)
        for d in recognition_dims
        if d.score is not None and _is_strong_verified_evidence(d)
    ]
    strict_additional_needed = max(0, required_verified - len(strong_verified_scores))
    source_url_backfill_candidates = _recognition_source_url_backfill_candidates(samples)

    queue = recognition_review_queue(samples)
    high_confidence = [
        item for item in queue
        if _review_queue_score(item) >= EXCELLENT_GATE
        and item.get("reason") != "low_auto_score_needs_reference"
    ]
    fallback = [item for item in queue if item not in high_confidence]
    ordered = sorted(high_confidence, key=_recognition_evidence_plan_rank) + sorted(
        fallback,
        key=_recognition_evidence_plan_rank,
    )
    recommended = [_recognition_evidence_item(item, minimum_accuracy_score) for item in ordered[:additional_needed]]
    recommended_ids = {item["sample_id"] for item in recommended}
    candidates_with_review_risks = [
        _recognition_evidence_item(item, minimum_accuracy_score)
        for item in queue
        if item.get("review_risks")
        and item.get("sample_id") not in recommended_ids
        and _review_queue_score(item) >= EXCELLENT_GATE
        and item.get("reason") != "low_auto_score_needs_reference"
    ]
    deferred_low_auto = [
        _recognition_evidence_item(item, minimum_accuracy_score)
        for item in queue
        if item.get("reason") == "low_auto_score_needs_reference"
        and item.get("sample_id") not in recommended_ids
    ]
    language_coverage = _recognition_language_coverage(
        samples,
        recommended,
        candidates_with_review_risks,
        deferred_low_auto,
    )
    coverage_warnings = _recognition_coverage_warnings(
        language_coverage,
        recommended,
        additional_needed,
    )
    multilingual_follow_up = _recognition_multilingual_follow_up(
        queue,
        recommended,
        language_coverage,
        minimum_accuracy_score,
    )
    balanced_recommended = _recognition_balanced_recommended(
        queue,
        recommended,
        language_coverage,
        minimum_accuracy_score,
        additional_needed,
    )

    projected_scores = verified_scores + [float(minimum_accuracy_score)] * len(recommended)
    projected_mean = mean(projected_scores) if projected_scores else None
    projected_verified = len(verified_scores) + len(recommended)
    projected_passes = (
        projected_mean is not None
        and projected_mean >= EXCELLENT_GATE
        and projected_verified >= required_verified
    )
    label_score = int(minimum_accuracy_score) if float(minimum_accuracy_score).is_integer() else minimum_accuracy_score
    return {
        "scored_samples": len(scored),
        "verified_samples": len(verified_scores),
        "required_verified_samples": required_verified,
        "additional_verified_needed": additional_needed,
        "strong_verified_samples": len(strong_verified_scores),
        "strict_additional_verified_needed": strict_additional_needed,
        "strict_verified_mean": round(mean(strong_verified_scores), 1) if strong_verified_scores else None,
        "evidence_quality": evidence_quality,
        "source_url_backfill_count": len(source_url_backfill_candidates),
        "source_url_backfill_candidates": source_url_backfill_candidates,
        "recommended_count": len(recommended),
        "recommended_language_count": len({str(item.get("language_code")) for item in recommended if item.get("language_code")}),
        "balanced_recommended_count": len(balanced_recommended),
        "balanced_recommended_language_count": len({
            str(item.get("language_code")) for item in balanced_recommended if item.get("language_code")
        }),
        "minimum_accuracy_score": float(minimum_accuracy_score),
        f"projected_verified_mean_if_recommended_score_{label_score}": round(projected_mean, 1) if projected_mean is not None else None,
        f"projected_passes_gate_if_recommended_score_{label_score}": projected_passes,
        "language_coverage": language_coverage,
        "coverage_warnings": coverage_warnings,
        "recommended": recommended,
        "balanced_recommended": balanced_recommended,
        "candidates_with_review_risks": candidates_with_review_risks,
        "deferred_low_auto_score": deferred_low_auto,
        "multilingual_follow_up": multilingual_follow_up,
        "note": (
            "Planning artifact only: review recommendations do not verify recognition until a "
            "numeric agent judge, explicit manual platform provenance, or human/reference subtitle is added."
        ),
    }


def _is_strong_verified_evidence(dim: DimensionScore) -> bool:
    return dim.verified and "judgeEvidence:sourceUrlsMissing" not in set(dim.notes)


def _recognition_source_url_backfill_candidates(samples: Sequence[SampleScorecard]) -> List[Dict[str, Any]]:
    candidates: List[Dict[str, Any]] = []
    for sample in samples:
        recognition = sample.dimensions.get("recognition")
        if (
            recognition is None
            or recognition.score is None
            or not recognition.verified
            or "judgeEvidence:sourceUrlsMissing" not in set(recognition.notes)
        ):
            continue
        candidates.append({
            "sample_id": sample.sample_id,
            "language_code": sample.language_code,
            "category": sample.category,
            "score": round(float(recognition.score), 3),
            "source_kind": sample.scored_source_kind,
            "source_path": sample.scored_source_path,
            "evidence": _evidence(recognition.notes),
            "action": "Backfill sourceUrls or equivalent reference/audio evidence for the historical recognition judge.",
        })
    candidates.sort(key=lambda item: (str(item.get("language_code", "")), str(item.get("sample_id", ""))))
    return candidates


def _recognition_language_coverage(
    samples: Sequence[SampleScorecard],
    recommended: Sequence[Dict[str, Any]],
    risky: Sequence[Dict[str, Any]],
    deferred_low_auto: Sequence[Dict[str, Any]],
) -> Dict[str, Dict[str, int]]:
    coverage: Dict[str, Dict[str, int]] = {}

    def ensure(language_code: Any) -> Dict[str, int]:
        lang = str(language_code or "unknown")
        return coverage.setdefault(lang, {
            "scored_samples": 0,
            "verified_samples": 0,
            "verified_pass_count": 0,
            "unverified_pass_count": 0,
            "recommended_count": 0,
            "risky_candidate_count": 0,
            "deferred_low_auto_count": 0,
        })

    for sample in samples:
        recognition = sample.dimensions.get("recognition")
        if recognition is None or recognition.score is None:
            continue
        bucket = ensure(sample.language_code)
        bucket["scored_samples"] += 1
        if recognition.verified:
            bucket["verified_samples"] += 1
            if recognition.passes:
                bucket["verified_pass_count"] += 1
        elif recognition.passes:
            bucket["unverified_pass_count"] += 1

    for item in recommended:
        ensure(item.get("language_code"))["recommended_count"] += 1
    for item in risky:
        ensure(item.get("language_code"))["risky_candidate_count"] += 1
    for item in deferred_low_auto:
        ensure(item.get("language_code"))["deferred_low_auto_count"] += 1
    return {lang: coverage[lang] for lang in sorted(coverage)}


def _recognition_coverage_warnings(
    language_coverage: Dict[str, Dict[str, int]],
    recommended: Sequence[Dict[str, Any]],
    additional_needed: int,
) -> List[str]:
    warnings: List[str] = []
    if additional_needed <= 0 or not recommended:
        return warnings
    recommended_languages = sorted({str(item.get("language_code")) for item in recommended if item.get("language_code")})
    scored_languages = [lang for lang, data in language_coverage.items() if data.get("scored_samples", 0) > 0]
    if len(recommended_languages) == 1 and len(scored_languages) > 1:
        warnings.append(f"recommendedSingleLanguage:{recommended_languages[0]}")
    risky_recommended_count = sum(1 for item in recommended if item.get("review_risks"))
    if risky_recommended_count > 0:
        warnings.append(f"recommendedEvidenceRisks:{risky_recommended_count}")
    return warnings


def _recognition_multilingual_follow_up(
    queue: Sequence[Dict[str, Any]],
    recommended: Sequence[Dict[str, Any]],
    language_coverage: Dict[str, Dict[str, int]],
    minimum_accuracy_score: float,
    *,
    max_items: int = 6,
) -> List[Dict[str, Any]]:
    recommended_ids = {str(item.get("sample_id")) for item in recommended if item.get("sample_id")}
    recommended_languages = {str(item.get("language_code")) for item in recommended if item.get("language_code")}
    candidates = [
        item for item in queue
        if item.get("sample_id") not in recommended_ids
        and item.get("language_code")
        and str(item.get("language_code")) not in recommended_languages
    ]
    candidates.sort(key=lambda item: _recognition_multilingual_follow_up_rank(item, language_coverage))

    selected: List[Dict[str, Any]] = []
    seen_languages: set[str] = set()
    for item in candidates:
        language_code = str(item.get("language_code"))
        if language_code in seen_languages:
            continue
        seen_languages.add(language_code)
        selected.append(_recognition_evidence_item(item, minimum_accuracy_score))
        if len(selected) >= max_items:
            break
    return selected


def _recognition_multilingual_follow_up_rank(
    item: Dict[str, Any],
    language_coverage: Dict[str, Dict[str, int]],
) -> tuple[int, int, int, float, str, str]:
    language_code = str(item.get("language_code") or "")
    coverage = language_coverage.get(language_code, {})
    verified_samples = int(coverage.get("verified_samples", 0))
    verified_pass_count = int(coverage.get("verified_pass_count", 0))
    return (
        0 if verified_samples == 0 else 1,
        0 if verified_pass_count == 0 else 1,
        0 if _review_queue_score(item) >= EXCELLENT_GATE else 1,
        -_review_queue_score(item),
        language_code,
        str(item.get("sample_id", "")),
    )


def _recognition_balanced_recommended(
    queue: Sequence[Dict[str, Any]],
    recommended: Sequence[Dict[str, Any]],
    language_coverage: Dict[str, Dict[str, int]],
    minimum_accuracy_score: float,
    additional_needed: int,
) -> List[Dict[str, Any]]:
    if additional_needed <= 1 or not recommended:
        return []
    recommended_languages = {
        str(item.get("language_code"))
        for item in recommended
        if item.get("language_code")
    }
    if len(recommended_languages) != 1:
        return []
    primary_language = next(iter(recommended_languages))
    recommended_ids = {str(item.get("sample_id")) for item in recommended if item.get("sample_id")}
    alternates = [
        item for item in queue
        if item.get("sample_id") not in recommended_ids
        and item.get("language_code")
        and str(item.get("language_code")) != primary_language
        and item.get("reason") != "low_auto_score_needs_reference"
        and _review_queue_score(item) >= EXCELLENT_GATE
    ]
    if not alternates:
        return []
    alternates.sort(key=lambda item: _recognition_balanced_alternate_rank(item, language_coverage))

    selected = [dict(item) for item in recommended[:1]]
    selected_languages = {
        str(item.get("language_code"))
        for item in selected
        if item.get("language_code")
    }
    for item in alternates:
        language_code = str(item.get("language_code"))
        if language_code in selected_languages:
            continue
        selected.append(_recognition_evidence_item(item, minimum_accuracy_score))
        selected_languages.add(language_code)
        if len(selected) >= additional_needed:
            break
    if len(selected) < additional_needed:
        for item in recommended[1:]:
            if item.get("sample_id") in {entry.get("sample_id") for entry in selected}:
                continue
            selected.append(dict(item))
            if len(selected) >= additional_needed:
                break
    if len({str(item.get("language_code")) for item in selected if item.get("language_code")}) <= 1:
        return []
    return selected[:additional_needed]


def _recognition_balanced_alternate_rank(
    item: Dict[str, Any],
    language_coverage: Dict[str, Dict[str, int]],
) -> tuple[int, int, int, float, str, str]:
    language_code = str(item.get("language_code") or "")
    coverage = language_coverage.get(language_code, {})
    verified_pass_count = int(coverage.get("verified_pass_count", 0))
    verified_samples = int(coverage.get("verified_samples", 0))
    return (
        0 if verified_pass_count == 0 else 1,
        0 if verified_samples == 0 else 1,
        1 if item.get("review_risks") else 0,
        -_review_queue_score(item),
        language_code,
        str(item.get("sample_id", "")),
    )


def _review_queue_score(item: Dict[str, Any]) -> float:
    score = item.get("score")
    return float(score) if isinstance(score, (int, float)) and math.isfinite(float(score)) else -math.inf


def _recognition_evidence_plan_rank(item: Dict[str, Any]) -> tuple[int, int, int, float, str, str]:
    reason_order = {
        "platform_provenance_or_judge_needed": 0,
        "semantic_judge_needed": 1,
        "low_auto_score_needs_reference": 2,
    }
    low_auto = 1 if item.get("reason") == "low_auto_score_needs_reference" or _review_queue_score(item) < EXCELLENT_GATE else 0
    return (
        low_auto,
        1 if item.get("review_risks") else 0,
        reason_order.get(str(item.get("reason", "")), 9),
        -_review_queue_score(item),
        str(item.get("language_code", "")),
        str(item.get("sample_id", "")),
    )


def _recognition_evidence_item(item: Dict[str, Any], minimum_accuracy_score: float) -> Dict[str, Any]:
    return {
        "sample_id": item.get("sample_id"),
        "language_code": item.get("language_code"),
        "category": item.get("category"),
        "score": item.get("score"),
        "source_kind": item.get("source_kind"),
        "source_path": item.get("source_path"),
        "prompt_path": item.get("prompt_path"),
        "audio_review_paths": list(item.get("audio_review_paths") or []),
        "reason": item.get("reason"),
        "review_risks": list(item.get("review_risks") or []),
        "minimum_accuracy_score": float(minimum_accuracy_score),
        "action": item.get("action"),
    }


def _recognition_review_reason(
    sample: SampleScorecard,
    recognition: DimensionScore,
) -> tuple[str, int, str]:
    if recognition.score is not None and recognition.score < EXCELLENT_GATE:
        return (
            "low_auto_score_needs_reference",
            10,
            "Add a human reference or numeric agent recognition judge before tuning production behavior.",
        )
    if sample.scored_source_kind == "platform":
        return (
            "platform_provenance_or_judge_needed",
            20,
            "Add platform manual-caption provenance or a numeric agent recognition judge; do not infer provenance from VTT headers.",
        )
    return (
        "semantic_judge_needed",
        30,
        "Add a numeric agent recognition judge or human subtitle reference to verify this clean-looking automatic score.",
    )


def _recognition_prompt_path(source_path: Optional[str]) -> Optional[str]:
    if not source_path:
        return None
    normalized = source_path.replace("\\", "/")
    if "/" not in normalized:
        return "agent_recognition.prompt.md"
    return normalized.rsplit("/", 1)[0] + "/agent_recognition.prompt.md"


def _backlog_item(
    sample: SampleScorecard,
    issue: str,
    dimension: str,
    severity: float,
    score: Optional[float],
    evidence: str,
    action: str,
) -> Dict[str, Any]:
    return {
        "issue": issue,
        "sample_id": sample.sample_id,
        "language_code": sample.language_code,
        "category": sample.category,
        "dimension": dimension,
        "severity": round(max(0.0, severity), 3),
        "score": round(score, 3) if isinstance(score, (int, float)) else score,
        "evidence": evidence,
        "action": action,
        "source_kind": sample.scored_source_kind,
        "source_path": sample.scored_source_path,
    }


def _first_onset_issue(components: Dict[str, Optional[float]], evidence: str) -> str:
    prefix_words = float(components.get("first_onset_prefix_words") or 0.0)
    prefix_seconds = float(components.get("first_onset_prefix_seconds") or 0.0)
    if _looks_like_intro_credit_noise(evidence):
        return "opening_intro_noise"
    if prefix_words >= 3 or prefix_seconds >= 1.0:
        return "opening_prefix_dropped"
    return "first_onset"


def _first_onset_action(issue: str) -> str:
    if issue == "opening_intro_noise":
        return "Treat the opening prefix as likely intro/credit hallucination; verify against audio before changing retiming."
    if issue == "opening_prefix_dropped":
        return "Inspect whether ASR words before the first cue are real speech/lyrics; if repeated, fix opening cue generation."
    return "Inspect the opening cue against audio/word timing; fix retiming only after repeated samples show the same failure."


def _looks_like_intro_credit_noise(text: str) -> bool:
    normalized = re.sub(r"\s+", "", text)
    markers = ("作詞", "作曲", "編曲", "初音ミク", "vocal", "lyrics", "composed", "arranged")
    if any(marker.lower() in normalized.lower() for marker in markers):
        return True
    low = normalized.lower()
    if "bgm" in low or low.count("*") >= 3 or low.count("♪") >= 2:
        return True
    tokens = re.findall(r"[A-Za-z*♪]{1,4}", text)
    if len(tokens) >= 8:
        unique_ratio = len(set(t.lower() for t in tokens)) / len(tokens)
        return unique_ratio <= 0.45
    return False


def _evidence(notes: Sequence[str]) -> str:
    return "; ".join(notes[:3]) if notes else ""


def render_markdown(
    samples: Sequence[SampleScorecard],
    summary: Dict[str, Any],
    source_decision: Optional[DimensionScore] = None,
) -> str:
    lines = ["# Moongate 字幕质量 Scorecard", ""]
    lines.append(f"门禁：各维 ≥ {summary['excellent_gate']:.0f} 分（优秀）。样本数：{summary['sample_count']}。")
    lines.append("")
    lines.append("## 汇总")
    lines.append("")
    lines.append("| 维度 | 均分 | 已评 | 已验证 | 验证缺口 | 强证缺口 | 验证均分 | ≥80 | 门禁(验证) |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|:---:|")
    label = {
        "recognition": "识别 recognition",
        "segmentation": "分段 segmentation",
        "translation": "翻译 translation",
        "source_decision": "源决策 source_decision",
    }
    for name, data in summary["dimensions"].items():
        mark = "✅" if data["passes_gate"] else "❌"
        mean_str = f"{data['mean']:.1f}" if data["mean"] is not None else "—"
        vmean_str = f"{data['verified_mean']:.1f}" if data.get("verified_mean") is not None else "—"
        lines.append(
            f"| {label.get(name, name)} | {mean_str} | {data['scored_samples']} | "
            f"{data.get('verified_samples', 0)} | {data.get('additional_verified_needed', 0)} | "
            f"{data.get('strict_additional_verified_needed', data.get('additional_verified_needed', 0))} | "
            f"{vmean_str} | {data['pass_count']} | {mark} |"
        )
    overall = f"{summary['overall_mean']:.1f}" if summary["overall_mean"] is not None else "—"
    lines.append("")
    lines.append(f"**总体均分：{overall}　全维达标(经验证)：{'是 ✅' if summary['all_dimensions_pass'] else '否 ❌'}**")
    lines.append("")
    lines.append("> 门禁口径：仅当有金标准分量（人工参考 / LLM 裁判 / 声学 / 场景真值）支撑、且验证覆盖 ≥60% 样本时才算达标。")
    lines.append("> 纯置信度+结构的高分标为「未验证」——自信乱码可能假性通过，需 agent 补 LLM 裁判或人工字幕对照。")
    lines.append("")
    lines.append("## Evidence Quality")
    lines.append("")
    lines.append("| 维度 | 强证已验证 | 可追溯 judge | 缺来源 judge | 非 judge 验证 |")
    lines.append("|---|---:|---:|---:|---:|")
    for name, data in summary["dimensions"].items():
        quality = data.get("evidence_quality") or {}
        lines.append(
            f"| {label.get(name, name)} | {data.get('strong_verified_samples', 0)} | "
            f"{quality.get('traceable_judge_count', 0)} | "
            f"{quality.get('untraceable_judge_count', 0)} | "
            f"{quality.get('non_judge_verified_count', 0)} |"
        )
    lines.append("")
    lines.append("## 逐样本")
    lines.append("")
    lines.append("| sample | 语言 | 类型 | 识别 | 分段 | 翻译 |")
    lines.append("|---|---|---|---:|---:|---:|")
    for s in samples:
        def cell(name: str) -> str:
            dim = s.dimensions.get(name)
            if dim is None or dim.score is None:
                return "—"
            flag = "·封顶" if dim.capped else ""
            return f"{dim.score:.0f}{flag}"
        lines.append(
            f"| {s.sample_id} | {s.language_code} | {s.category} | "
            f"{cell('recognition')} | {cell('segmentation')} | {cell('translation')} |"
        )
    lines.append("")
    backlog = quality_backlog(samples, source_decision, max_items=12)
    if backlog:
        lines.append("## Backlog")
        lines.append("")
        lines.append("| issue | sample | 语言 | score | severity | evidence |")
        lines.append("|---|---|---|---:|---:|---|")
        for item in backlog:
            score = item["score"]
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "—"
            lines.append(
                f"| {item['issue']} | {item['sample_id']} | {item['language_code']} | "
                f"{score_text} | {item['severity']:.1f} | {item['evidence']} |"
            )
    lines.append("")
    return "\n".join(lines) + "\n"


def render_recognition_review_queue_markdown(queue: Sequence[Dict[str, Any]]) -> str:
    lines = ["# Recognition Review Queue", ""]
    lines.append(
        "Only human/reference subtitles or numeric `agent_recognition_judge.json.accuracyScore` "
        "can verify recognition. Prompts and holistic viewing-quality JSON are not proof."
    )
    lines.append("")
    if not queue:
        lines.append("No unverified recognition samples.")
        lines.append("")
        return "\n".join(lines)
    lines.append("| priority | reason | sample | lang | score | source | risks | audio | prompt |")
    lines.append("|---:|---|---|---|---:|---|---|---|---|")
    for item in queue:
        score = item.get("score")
        score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "—"
        prompt = item.get("prompt_path") or "—"
        source = item.get("source_kind") or "—"
        risks = ", ".join(str(r) for r in item.get("review_risks") or []) or "—"
        audio = _join_md_values(item.get("audio_review_paths") or [])
        lines.append(
            f"| {item.get('priority', 0)} | {item.get('reason', '')} | {item.get('sample_id', '')} | "
            f"{item.get('language_code', '')} | {score_text} | {source} | {_md_cell(risks)} | {_md_cell(audio)} | {prompt} |"
        )
    lines.append("")
    return "\n".join(lines)


def render_recognition_evidence_plan_markdown(plan: Dict[str, Any]) -> str:
    lines = ["# Recognition Evidence Plan", ""]
    lines.append(str(plan.get("note") or "Planning artifact only."))
    lines.append("")
    lines.append(
        f"Recognition verified coverage: {plan.get('verified_samples', 0)}/"
        f"{plan.get('scored_samples', 0)} scored; required "
        f"{plan.get('required_verified_samples', 0)}; gap "
        f"{plan.get('additional_verified_needed', 0)}."
    )
    lines.append(
        f"Strict traceable evidence: {plan.get('strong_verified_samples', 0)}/"
        f"{plan.get('scored_samples', 0)} scored; strict gap "
        f"{plan.get('strict_additional_verified_needed', plan.get('additional_verified_needed', 0))}; "
        f"source-url backfill candidates {plan.get('source_url_backfill_count', 0)}."
    )
    evidence_quality = plan.get("evidence_quality") or {}
    if evidence_quality:
        lines.append(
            "Evidence quality: "
            f"non-judge verified {evidence_quality.get('non_judge_verified_count', 0)}, "
            f"traceable judge {evidence_quality.get('traceable_judge_count', 0)}, "
            f"missing-source judge {evidence_quality.get('untraceable_judge_count', 0)}."
        )
    projected_mean_key = next(
        (key for key in plan if key.startswith("projected_verified_mean_if_recommended_score_")),
        None,
    )
    projected_pass_key = next(
        (key for key in plan if key.startswith("projected_passes_gate_if_recommended_score_")),
        None,
    )
    if projected_mean_key:
        projected_mean = plan.get(projected_mean_key)
        projected_pass = plan.get(projected_pass_key) if projected_pass_key else None
        lines.append(f"Projected verified mean after recommendations: {projected_mean}; projected gate pass: {projected_pass}.")
    lines.append("")

    warnings = plan.get("coverage_warnings") or []
    if warnings:
        lines.append("Coverage warnings: " + ", ".join(str(w) for w in warnings))
        lines.append("")

    source_url_backfill = plan.get("source_url_backfill_candidates") or []
    if source_url_backfill:
        lines.append("## Source URL Backfill")
        lines.append("")
        lines.append("Historical numeric judges remain accepted for continuity, but these need cited sources before they count as strong evidence.")
        lines.append("")
        lines.append("| sample | lang | score | source | action |")
        lines.append("|---|---|---:|---|---|")
        for item in source_url_backfill:
            score = item.get("score")
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{score_text} | {_md_cell(item.get('source_kind'))} | {_md_cell(item.get('action'))} |"
            )
        lines.append("")

    reference_acquisition = plan.get("reference_acquisition_attempts") or []
    if reference_acquisition:
        lines.append("## Reference Acquisition Attempts")
        lines.append("")
        lines.append("These attempts document evidence searches only. They do not verify recognition or change scores.")
        lines.append("")
        lines.append("| sample | lang | status | source | checked | next action |")
        lines.append("|---|---|---|---|---|---|")
        for item in reference_acquisition:
            source = item.get("sourceUrl")
            if source is None and isinstance(item.get("sourceUrls"), list):
                source = ", ".join(str(url) for url in item.get("sourceUrls") or [] if str(url).strip())
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{_md_cell(item.get('status'))} | {_md_cell(source)} | {_md_cell(item.get('checkedAt'))} | "
                f"{_md_cell(item.get('nextAction'))} |"
            )
        lines.append("")

    language_coverage = plan.get("language_coverage") or {}
    if language_coverage:
        lines.append("## Language Coverage")
        lines.append("")
        lines.append("| lang | scored | verified | verified ≥80 | unverified ≥80 | recommended | risky | deferred low-auto |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for lang, data in sorted(language_coverage.items()):
            lines.append(
                f"| {_md_cell(lang)} | {int(data.get('scored_samples', 0))} | "
                f"{int(data.get('verified_samples', 0))} | {int(data.get('verified_pass_count', 0))} | "
                f"{int(data.get('unverified_pass_count', 0))} | {int(data.get('recommended_count', 0))} | "
                f"{int(data.get('risky_candidate_count', 0))} | {int(data.get('deferred_low_auto_count', 0))} |"
            )
        lines.append("")

    recommended = plan.get("recommended") or []
    if not recommended:
        lines.append("No additional recognition evidence is required for the current coverage gate.")
        lines.append("")
        return "\n".join(lines)

    lines.append("| sample | lang | score | reason | source | minimum judge score | risks | audio | prompt |")
    lines.append("|---|---|---:|---|---|---:|---|---|---|")
    for item in recommended:
        score = item.get("score")
        score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
        minimum = item.get("minimum_accuracy_score")
        minimum_text = f"{minimum:.1f}" if isinstance(minimum, (int, float)) else "-"
        risks = ", ".join(str(r) for r in item.get("review_risks") or []) or "-"
        audio = _join_md_values(item.get("audio_review_paths") or [])
        lines.append(
            f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
            f"{score_text} | {_md_cell(item.get('reason'))} | {_md_cell(item.get('source_kind'))} | "
            f"{minimum_text} | {_md_cell(risks)} | {_md_cell(audio)} | {_md_cell(item.get('prompt_path'))} |"
        )

    balanced = plan.get("balanced_recommended") or []
    if balanced:
        lines.append("")
        lines.append("## Balanced Coverage Batch")
        lines.append("")
        lines.append("This alternative fills the same coverage gap while adding language diversity; items still require real reference/audio-backed evidence before they verify recognition.")
        lines.append("")
        lines.append("| sample | lang | score | reason | source | minimum judge score | risks | audio | prompt |")
        lines.append("|---|---|---:|---|---|---:|---|---|---|")
        for item in balanced:
            score = item.get("score")
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
            minimum = item.get("minimum_accuracy_score")
            minimum_text = f"{minimum:.1f}" if isinstance(minimum, (int, float)) else "-"
            risks = ", ".join(str(r) for r in item.get("review_risks") or []) or "-"
            audio = _join_md_values(item.get("audio_review_paths") or [])
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{score_text} | {_md_cell(item.get('reason'))} | {_md_cell(item.get('source_kind'))} | "
                f"{minimum_text} | {_md_cell(risks)} | {_md_cell(audio)} | {_md_cell(item.get('prompt_path'))} |"
            )

    multilingual_follow_up = plan.get("multilingual_follow_up") or []
    if multilingual_follow_up:
        lines.append("")
        lines.append("## Multilingual Follow-up")
        lines.append("")
        lines.append("These are non-scoring follow-up reviews to keep recognition evidence from overfitting to the fastest single-language coverage path.")
        lines.append("")
        lines.append("| sample | lang | score | reason | risks | audio | prompt |")
        lines.append("|---|---|---:|---|---|---|---|")
        for item in multilingual_follow_up:
            score = item.get("score")
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
            risks = ", ".join(str(r) for r in item.get("review_risks") or []) or "-"
            audio = _join_md_values(item.get("audio_review_paths") or [])
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{score_text} | {_md_cell(item.get('reason'))} | {_md_cell(risks)} | "
                f"{_md_cell(audio)} | {_md_cell(item.get('prompt_path'))} |"
            )

    risky = plan.get("candidates_with_review_risks") or []
    if risky:
        lines.append("")
        lines.append("## Risky Candidates")
        lines.append("")
        lines.append("These candidates are not recommended first while enough clean high-confidence candidates exist.")
        lines.append("")
        lines.append("| sample | lang | score | risks | audio | prompt |")
        lines.append("|---|---|---:|---|---|---|")
        for item in risky:
            score = item.get("score")
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
            risks = ", ".join(str(r) for r in item.get("review_risks") or []) or "-"
            audio = _join_md_values(item.get("audio_review_paths") or [])
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{score_text} | {_md_cell(risks)} | {_md_cell(audio)} | {_md_cell(item.get('prompt_path'))} |"
            )

    deferred = plan.get("deferred_low_auto_score") or []
    if deferred:
        lines.append("")
        lines.append("## Deferred Low Automatic Scores")
        lines.append("")
        lines.append("Review these as possible real failures, but do not use them as the fastest coverage-fill path.")
        lines.append("")
        lines.append("| sample | lang | score | audio | prompt |")
        lines.append("|---|---|---:|---|---|")
        for item in deferred:
            score = item.get("score")
            score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
            audio = _join_md_values(item.get("audio_review_paths") or [])
            lines.append(
                f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
                f"{score_text} | {_md_cell(audio)} | {_md_cell(item.get('prompt_path'))} |"
            )
    lines.append("")
    return "\n".join(lines)


def render_recognition_review_packet_markdown(plan: Dict[str, Any]) -> str:
    lines = ["# Recognition Review Packet", ""]
    lines.append(
        "Audio paths are access paths, not proof. Only write a numeric judge after reliable "
        "reference or audio review supports the score."
    )
    lines.append("")
    lines.append(
        f"Recognition verified coverage: {plan.get('verified_samples', 0)}/"
        f"{plan.get('scored_samples', 0)}; required "
        f"{plan.get('required_verified_samples', 0)}; gap "
        f"{plan.get('additional_verified_needed', 0)}."
    )
    lines.append(
        f"Strict traceable gap: "
        f"{plan.get('strict_additional_verified_needed', plan.get('additional_verified_needed', 0))}."
    )
    lines.append("")
    lines.append("Judge JSON contract:")
    lines.append("")
    lines.append("```json")
    lines.append(
        '{"accuracyScore": null, "issues": [], "notes": "", "judgedBy": "agent", '
        '"language": "", "evidence": [], "confidence": "low|medium|high", "sourceUrls": []}'
    )
    lines.append("```")
    lines.append("")

    recommended = plan.get("recommended") or []
    if not recommended:
        lines.append("No recommended recognition review items.")
        lines.append("")
        return "\n".join(lines)

    _append_recognition_review_packet_table(lines, recommended)
    balanced = plan.get("balanced_recommended") or []
    if balanced:
        lines.append("")
        lines.append("## Balanced Coverage Batch")
        lines.append("")
        lines.append("Alternative batch for filling the same recognition gap while adding language diversity. Evidence rules are unchanged.")
        lines.append("")
        _append_recognition_review_packet_table(lines, balanced)
    lines.append("")
    return "\n".join(lines)


def render_recognition_review_packet_html(plan: Dict[str, Any]) -> str:
    recommended = plan.get("recommended") or []
    lines = [
        "<!doctype html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>Recognition Review Packet</title>",
        "<style>",
        "body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;margin:32px;line-height:1.45;color:#1d1d1f;background:#f5f5f7}",
        "main{max-width:1120px;margin:0 auto}",
        "section{background:white;border:1px solid #d2d2d7;border-radius:8px;padding:18px;margin:16px 0}",
        "code{background:#f5f5f7;border-radius:4px;padding:2px 4px}",
        "audio,video{display:block;width:100%;max-width:840px;margin:8px 0 14px}",
        ".meta{color:#515154}",
        ".path{word-break:break-all}",
        "</style>",
        "</head>",
        "<body>",
        "<main>",
        "<h1>Recognition Review Packet</h1>",
        "<p><strong>Audio controls are access paths, not proof.</strong> Only write a numeric judge after reliable reference or audio review supports the score.</p>",
        (
            "<p class=\"meta\">Recognition verified coverage: "
            f"{html_escape(str(plan.get('verified_samples', 0)))}/"
            f"{html_escape(str(plan.get('scored_samples', 0)))}; required "
            f"{html_escape(str(plan.get('required_verified_samples', 0)))}; gap "
            f"{html_escape(str(plan.get('additional_verified_needed', 0)))}.</p>"
        ),
        (
            "<p class=\"meta\">Strict traceable gap: "
            f"{html_escape(str(plan.get('strict_additional_verified_needed', plan.get('additional_verified_needed', 0))))}.</p>"
        ),
        "<section>",
        "<h2>Judge JSON contract</h2>",
        "<pre><code>{&quot;accuracyScore&quot;: null, &quot;issues&quot;: [], &quot;notes&quot;: &quot;&quot;, &quot;judgedBy&quot;: &quot;agent&quot;, &quot;language&quot;: &quot;&quot;, &quot;evidence&quot;: [], &quot;confidence&quot;: &quot;low|medium|high&quot;, &quot;sourceUrls&quot;: []}</code></pre>",
        "</section>",
    ]
    if not recommended:
        lines.extend(["<section><p>No recommended recognition review items.</p></section>", "</main>", "</body>", "</html>"])
        return "\n".join(lines)

    lines.append("<h2>Fastest Coverage Batch</h2>")
    for item in recommended:
        _append_recognition_review_packet_html_item(lines, item)
    balanced = plan.get("balanced_recommended") or []
    if balanced:
        lines.append("<h2>Balanced Coverage Batch</h2>")
        lines.append("<p class=\"meta\">Alternative batch for filling the same recognition gap while adding language diversity. Evidence rules are unchanged.</p>")
        for item in balanced:
            _append_recognition_review_packet_html_item(lines, item)
    lines.extend(["</main>", "</body>", "</html>"])
    return "\n".join(lines)


def _append_recognition_review_packet_table(lines: List[str], items: Sequence[Dict[str, Any]]) -> None:
    lines.append("| sample | lang | reason | score | minimum | risks | audio | prompt | judge output |")
    lines.append("|---|---|---|---:|---:|---|---|---|---|")
    for item in items:
        score = item.get("score")
        score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
        minimum = item.get("minimum_accuracy_score")
        minimum_text = f"{minimum:.1f}" if isinstance(minimum, (int, float)) else "-"
        risks = ", ".join(str(risk) for risk in item.get("review_risks") or []) or "-"
        audio = _join_md_values(item.get("audio_review_paths") or [])
        prompt = item.get("prompt_path")
        lines.append(
            f"| {_md_cell(item.get('sample_id'))} | {_md_cell(item.get('language_code'))} | "
            f"{_md_cell(item.get('reason'))} | {score_text} | {minimum_text} | "
            f"{_md_cell(risks)} | {_md_cell(audio)} | {_md_cell(prompt)} | "
            f"{_md_cell(_recognition_judge_path(item))} |"
        )


def _append_recognition_review_packet_html_item(lines: List[str], item: Dict[str, Any]) -> None:
        sample_id = html_escape(str(item.get("sample_id") or "unknown"))
        score = item.get("score")
        score_text = f"{score:.1f}" if isinstance(score, (int, float)) else "-"
        minimum = item.get("minimum_accuracy_score")
        minimum_text = f"{minimum:.1f}" if isinstance(minimum, (int, float)) else "-"
        risks = ", ".join(str(risk) for risk in item.get("review_risks") or []) or "-"
        prompt = item.get("prompt_path")
        judge = _recognition_judge_path(item)
        lines.extend([
            "<section>",
            f"<h2>{sample_id}</h2>",
            (
                "<p class=\"meta\">"
                f"lang: {html_escape(str(item.get('language_code') or '-'))} · "
                f"reason: {html_escape(str(item.get('reason') or '-'))} · "
                f"score: {html_escape(score_text)} · minimum: {html_escape(minimum_text)}"
                f" · risks: {html_escape(risks)}"
                "</p>"
            ),
        ])
        for media_path in item.get("audio_review_paths") or []:
            lines.extend(_html_media_block(str(media_path)))
        if prompt:
            lines.append(f'<p class="path">prompt: {_html_path_link(str(prompt))}</p>')
        if judge:
            lines.append(f'<p class="path">judge output: {_html_path_link(str(judge))}</p>')
        lines.append("</section>")


def recognition_review_judge_templates(plan: Dict[str, Any]) -> List[Dict[str, Any]]:
    templates: List[Dict[str, Any]] = []
    grouped_items = [
        ("recommended", item)
        for item in plan.get("recommended") or []
    ] + [
        ("balanced_recommended", item)
        for item in plan.get("balanced_recommended") or []
    ] + [
        ("multilingual_follow_up", item)
        for item in plan.get("multilingual_follow_up") or []
    ]
    for review_group, item in grouped_items:
        judge_output_path = _recognition_judge_path(item)
        templates.append({
            "review_group": review_group,
            "sample_id": item.get("sample_id"),
            "language_code": item.get("language_code"),
            "reason": item.get("reason"),
            "minimum_accuracy_score": item.get("minimum_accuracy_score"),
            "prompt_path": item.get("prompt_path"),
            "audio_review_paths": list(item.get("audio_review_paths") or []),
            "judge_output_path": judge_output_path,
            "template": {
                "accuracyScore": None,
                "issues": [],
                "notes": "insufficient evidence until reliable reference or audio review is completed",
                "judgedBy": "agent",
                "language": item.get("language_code") or "",
                "evidence": [],
                "confidence": "low",
                "sourceUrls": [],
            },
        })
    return templates


def _html_media_block(path: str) -> List[str]:
    uri = _html_path_uri(path)
    tag = "video" if path.lower().endswith((".webm", ".mp4", ".mov")) else "audio"
    return [
        f'<p class="path">{_html_path_link(path)}</p>',
        f'<{tag} controls preload="metadata" src="{html_escape(uri, quote=True)}"></{tag}>',
    ]


def _html_path_link(path: str) -> str:
    uri = _html_path_uri(path)
    return f'<a href="{html_escape(uri, quote=True)}"><code>{html_escape(path)}</code></a>'


def _html_path_uri(path: str) -> str:
    if path.startswith("/"):
        return "file://" + url_quote(path)
    return url_quote(path)


def _recognition_judge_path(item: Dict[str, Any]) -> Optional[str]:
    for key in ("prompt_path", "source_path"):
        raw = item.get(key)
        if not raw:
            continue
        normalized = str(raw).replace("\\", "/")
        if "/" not in normalized:
            return "agent_recognition_judge.json"
        return normalized.rsplit("/", 1)[0] + "/agent_recognition_judge.json"
    return None


def _join_md_values(values: Sequence[Any]) -> str:
    text_values = [str(value) for value in values if str(value).strip()]
    return "; ".join(text_values) if text_values else "-"


def _md_cell(value: Any) -> str:
    text = "-" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")

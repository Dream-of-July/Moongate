#!/usr/bin/env python3
"""Moongate 字幕质量 scorecard — 基线运行器。

扫描 `artifacts/subtitle_timing_eval` 下的缓存样本，对每个样本自动计算可计算的分量
（识别置信度/结构健康度、分段内生质量+可选声学一致性、翻译结构、有人工 .clean.srt 时的
CER/WER 与分段参考），合并 agent 写入的语义裁判（`agent_recognition_judge.json` /
`agent_translation_judge.json`，若存在），并对 `source_decision_scenarios.json` 跑源决策正确率，
最后产出 `scorecard.json` + `scorecard.md`。

用法：
  python3 run_scorecard_baseline.py                      # 默认扫 artifacts/subtitle_timing_eval
  python3 run_scorecard_baseline.py --acoustic           # 额外用能量 VAD 做声学边界校验(需 ffmpeg,较慢)
  python3 run_scorecard_baseline.py --roots viewing_quality viewing_quality_songs30
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import replace
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/subtitle_timing_eval"))

from subtitle_timing_eval import scorecard as sc  # noqa: E402
from subtitle_timing_eval.srt import Cue, parse_srt  # noqa: E402
from subtitle_timing_eval.segmentation import evaluate_segmentation  # noqa: E402
from subtitle_timing_eval.vtt import parse_vtt_word_timestamps  # noqa: E402
from subtitle_timing_eval.viewing_quality import load_subtitle_cues, normalized_language_code  # noqa: E402

DEFAULT_ARTIFACTS = ROOT / "artifacts/subtitle_timing_eval"
CANDIDATE_GLOBS = ["local-asr.*.srt", "local-asr*.srt", "*.local-asr.*.srt"]
LANG_RE = re.compile(r"local-asr(?:\.\d+-\d+)?\.([a-z]{2,3})(?:\s+\d+)?\.srt$", re.I)
SUBTITLE_LANG_RE = re.compile(r"\.([a-z]{2,3}(?:-[a-z0-9]+)?)\.(?:srt|vtt)$", re.I)
MANUAL_PLATFORM_CAPTION_KINDS = {"manual", "official", "human", "uploaded", "uploaded_subtitle"}
WINDOW_RE = re.compile(r"(\d+)-(\d+)")
DURATION_RE = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")
SILENCE_START_RE = re.compile(r"silence_start:\s*([0-9.]+)")
SILENCE_END_RE = re.compile(r"silence_end:\s*([0-9.]+)")
SILENCE_DURATION_RE = re.compile(r"silence_duration:\s*([0-9.]+)")
VTT_INLINE_TIME_RE = re.compile(r"<(?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3}>")


def _clean(name: str) -> bool:
    # 跳过 macOS iCloud 的 " 2" 重复副本
    return " 2." not in name and " 3." not in name


def _resolve_candidate_path(sample_dir: Path, raw_path: str) -> Optional[Path]:
    path = Path(raw_path)
    if path.is_absolute():
        return path if path.is_file() and _clean(path.name) else None
    for base in [sample_dir, ROOT]:
        resolved = base / path
        if resolved.is_file() and _clean(resolved.name):
            return resolved
    return None


def pick_selected_source_candidate(sample_dir: Path) -> Optional[Tuple[Path, str, Dict[str, Any]]]:
    source_candidates = sample_dir / "source_candidates.json"
    if not source_candidates.is_file():
        return None
    try:
        data = json.loads(source_candidates.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, list):
        return None
    for candidate in data:
        if not isinstance(candidate, dict) or not candidate.get("selected"):
            continue
        raw_path = candidate.get("path")
        if not isinstance(raw_path, str) or not raw_path.strip():
            continue
        resolved = _resolve_candidate_path(sample_dir, raw_path)
        if resolved is not None:
            kind = str(candidate.get("kind") or "selected")
            return resolved, kind, dict(candidate)
    return None


def pick_scored_source(sample_dir: Path) -> Tuple[Optional[Path], str, Optional[Dict[str, Any]]]:
    selected = pick_selected_source_candidate(sample_dir)
    if selected is not None:
        return selected
    found: List[Path] = []
    for pattern in CANDIDATE_GLOBS:
        found.extend(sample_dir.glob(pattern))
    found = [p for p in dict.fromkeys(found) if p.is_file() and p.stat().st_size > 0 and _clean(p.name)]
    if not found:
        return None, "missing", None
    # 优先无窗口的 local-asr.<lang>.srt，其次最新
    found.sort(key=lambda p: (("-" in p.stem), -p.stat().st_mtime))
    return found[0], "local-asr", None


def pick_candidate(sample_dir: Path) -> Optional[Path]:
    candidate, _source_kind, _source_record = pick_scored_source(sample_dir)
    return candidate


def parse_language(candidate: Path, sample_dir: Path) -> Optional[str]:
    m = LANG_RE.search(candidate.name)
    if m:
        return normalized_language_code(m.group(1))
    m = SUBTITLE_LANG_RE.search(candidate.name)
    if m:
        return normalized_language_code(m.group(1))
    return None


def parse_window(name: str) -> Optional[Tuple[float, float]]:
    m = WINDOW_RE.search(name)
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


def find_human_reference(sample_dir: Path, language: Optional[str]) -> Optional[Path]:
    candidates = [p for p in sorted(sample_dir.glob("*.clean.srt")) if p.is_file() and _clean(p.name)]
    if language:
        lang_match = [p for p in candidates if f".{language}." in p.name or f".{language}.clean" in p.name]
        if lang_match:
            return lang_match[0]
    return candidates[0] if candidates else None


def load_human_word_reference(sample_dir: Path, window: Optional[Tuple[float, float]]) -> Optional[str]:
    patterns: List[str] = []
    if window:
        wtag = f"{int(window[0])}-{int(window[1])}"
        patterns.append(f"srt_words.{wtag}.human.json")
    patterns.append("srt_words*.human.json")
    for pattern in patterns:
        for path in sorted(sample_dir.glob(pattern)):
            if not _clean(path.name):
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            words = data.get("words") if isinstance(data, dict) else data
            if not isinstance(words, list):
                continue
            texts: List[str] = []
            for word in words:
                if not isinstance(word, dict):
                    continue
                if window:
                    try:
                        start = float(word.get("start"))
                        end = float(word.get("end"))
                    except (TypeError, ValueError):
                        continue
                    lo, hi = window
                    if end <= lo or start >= hi:
                        continue
                text = str(word.get("text", "")).strip()
                if text:
                    texts.append(text)
            if texts:
                return "\n".join(texts)
    return None


def _is_manual_platform_caption_kind(value: Any) -> bool:
    return isinstance(value, str) and value.strip().lower() in MANUAL_PLATFORM_CAPTION_KINDS


def has_manual_platform_provenance(source_record: Optional[Dict[str, Any]]) -> bool:
    if not isinstance(source_record, dict):
        return False
    if source_record.get("isManual") is True or source_record.get("manual") is True:
        return True
    raw_kind = source_record.get("captionKind") or source_record.get("subtitleKind") or source_record.get("trackKind")
    if _is_manual_platform_caption_kind(raw_kind):
        return True
    provenance = source_record.get("provenance")
    if isinstance(provenance, dict):
        if provenance.get("isManual") is True or provenance.get("manual") is True:
            return True
        raw_kind = provenance.get("captionKind") or provenance.get("subtitleKind") or provenance.get("trackKind")
        if _is_manual_platform_caption_kind(raw_kind):
            return True
    return False


def _has_url_evidence(entry: Dict[str, Any]) -> bool:
    source_url = entry.get("sourceUrl")
    if isinstance(source_url, str) and source_url.strip().startswith(("http://", "https://")):
        return True
    source_urls = entry.get("sourceUrls")
    if isinstance(source_urls, list) and any(str(url).strip().startswith(("http://", "https://")) for url in source_urls):
        return True
    evidence = entry.get("evidence")
    if isinstance(evidence, list) and any("http://" in str(item) or "https://" in str(item) for item in evidence):
        return True
    return False


def _source_path_matches(candidate_path: Path, sample_dir: Path, raw_source_path: Any) -> bool:
    if not isinstance(raw_source_path, str) or not raw_source_path.strip():
        return False
    raw = raw_source_path.strip()
    path = Path(raw)
    candidates = [path] if path.is_absolute() else [sample_dir / path, ROOT / path]
    for expected in candidates:
        try:
            if expected.resolve() == candidate_path.resolve():
                return True
        except OSError:
            if expected == candidate_path:
                return True
    return len(path.parts) == 1 and path.name == candidate_path.name


def merge_platform_caption_provenance_backfill(
    source_record: Optional[Dict[str, Any]],
    sample_id: str,
    source_path: Path,
    sample_dir: Path,
    backfills: Optional[Dict[str, Dict[str, Any]]],
) -> Optional[Dict[str, Any]]:
    if not isinstance(source_record, dict) or not backfills:
        return source_record
    entry = backfills.get(sample_id)
    if not isinstance(entry, dict) or not has_manual_platform_provenance(entry):
        return source_record
    raw_path = entry.get("sourcePath") or entry.get("source_path") or entry.get("path")
    if not _source_path_matches(source_path, sample_dir, raw_path):
        return source_record

    merged = dict(source_record)
    provenance = dict(merged.get("provenance")) if isinstance(merged.get("provenance"), dict) else {}
    for key in [
        "captionKind",
        "subtitleKind",
        "trackKind",
        "isManual",
        "manual",
        "sourceUrl",
        "sourceUrls",
        "evidence",
        "checkedAt",
        "method",
    ]:
        if key in entry:
            provenance[key] = entry[key]
            if key in {"captionKind", "subtitleKind", "trackKind", "isManual", "manual"}:
                merged.setdefault(key, entry[key])
    merged["provenance"] = provenance
    return merged


def find_words(sample_dir: Path, window: Optional[Tuple[float, float]]) -> Optional[List[Dict[str, Any]]]:
    patterns = ["local-asr.words.json"]
    if window:
        wtag = f"{int(window[0])}-{int(window[1])}"
        patterns += [f"asr_words.{wtag}.whisper-cpp.json", f"asr_words.{wtag}.json"]
    patterns += ["asr_words.json", "asr_words.whisper-cpp.json", "*.words.json"]
    for pattern in patterns:
        for path in sorted(sample_dir.glob(pattern)):
            if not _clean(path.name) or "seg" in path.name:
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            words = data.get("words") if isinstance(data, dict) else data
            if isinstance(words, list) and _has_timed_words(words):
                return words
    return None


def platform_vtt_words(path: Path) -> Optional[List[Dict[str, Any]]]:
    if path.suffix.lower() != ".vtt":
        return None
    raw = path.read_text(encoding="utf-8", errors="replace")
    if not VTT_INLINE_TIME_RE.search(raw):
        return None
    words = [
        {"start": word.start, "end": word.end, "text": word.text}
        for word in parse_vtt_word_timestamps(raw)
        if word.text.strip()
    ]
    return words or None


def _has_timed_words(words: List[Any]) -> bool:
    for word in words:
        if not isinstance(word, dict):
            continue
        try:
            start = float(word.get("start"))
            end = float(word.get("end"))
        except (TypeError, ValueError):
            continue
        if start <= end:
            return True
    return False


def find_translated(sample_dir: Path, source_path: Optional[Path] = None) -> Optional[Path]:
    for name in ["translated.srt", "translated.zh-Hans.srt", "translated.zh.srt"]:
        path = sample_dir / name
        if path.is_file() and path.stat().st_size > 0:
            # 防陈旧:译文若早于其源(源已重新生成)则视为过期产物,不计分——避免拿旧乱码源的译文
            # 污染翻译认证(实测群青/浮夸 translated.srt 比重生成的 local-asr 旧 2-5 小时)。
            if source_path is not None and path.stat().st_mtime < source_path.stat().st_mtime:
                print(f"[stale translation skipped] {sample_dir.name}: translated older than source", file=sys.stderr)
                return None
            return path
    return None


def load_agent_judge(sample_dir: Path, name: str) -> Optional[Dict[str, Any]]:
    path = sample_dir / name
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def load_source_report_evidence_risks(sample_dir: Path) -> List[str]:
    path = sample_dir / "source_report.json"
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, dict):
        return []

    risks: List[str] = []
    if data.get("fallback_used") is True:
        risks.append("sourceReport:localFallbackUsed")
    source_quality = data.get("source_quality")
    if isinstance(source_quality, dict) and source_quality.get("usable") is False:
        reasons = source_quality.get("reasons")
        suffix = ""
        if isinstance(reasons, list):
            clean_reasons = [str(reason).strip() for reason in reasons[:3] if str(reason).strip()]
            if clean_reasons:
                suffix = ":" + ",".join(clean_reasons)
        risks.append("sourceReport:sourceQualityUnusable" + suffix)
    final_source_issues = data.get("final_source_issues")
    if isinstance(final_source_issues, list) and final_source_issues:
        risks.append("sourceReport:finalSourceIssues")
    return risks


def load_batch_recognition_judges(path: Optional[Path]) -> Dict[str, Dict[str, Any]]:
    if path is None or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

    entries: List[Dict[str, Any]] = []
    if isinstance(data, dict) and isinstance(data.get("judges"), list):
        entries = [entry for entry in data["judges"] if isinstance(entry, dict)]
    elif isinstance(data, list):
        entries = [entry for entry in data if isinstance(entry, dict)]
    elif isinstance(data, dict):
        for sample_id, value in data.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("sample_id", sample_id)
                entries.append(entry)

    judges: Dict[str, Dict[str, Any]] = {}
    for entry in entries:
        raw_sample_id = entry.get("sample_id") or entry.get("sampleId") or entry.get("id")
        if not isinstance(raw_sample_id, str) or not raw_sample_id.strip():
            continue
        sample_id = raw_sample_id.strip()
        judges.setdefault(sample_id, entry)
    return judges


def load_recognition_judge_source_backfills(path: Optional[Path]) -> Dict[str, Dict[str, Any]]:
    if path is None or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

    entries: List[Dict[str, Any]] = []
    if isinstance(data, dict) and isinstance(data.get("backfills"), list):
        entries = [entry for entry in data["backfills"] if isinstance(entry, dict)]
    elif isinstance(data, list):
        entries = [entry for entry in data if isinstance(entry, dict)]
    elif isinstance(data, dict):
        for sample_id, value in data.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("sample_id", sample_id)
                entries.append(entry)

    backfills: Dict[str, Dict[str, Any]] = {}
    for entry in entries:
        raw_sample_id = entry.get("sample_id") or entry.get("sampleId") or entry.get("id")
        if not isinstance(raw_sample_id, str) or not raw_sample_id.strip():
            continue
        source_urls = entry.get("sourceUrls")
        evidence = entry.get("evidence")
        has_source_urls = isinstance(source_urls, list) and any(str(url).strip() for url in source_urls)
        has_evidence_urls = isinstance(evidence, list) and any(
            "http://" in str(item) or "https://" in str(item)
            for item in evidence
        )
        if not has_source_urls and not has_evidence_urls:
            continue
        backfills.setdefault(raw_sample_id.strip(), entry)
    return backfills


def load_recognition_reference_acquisition(path: Optional[Path]) -> List[Dict[str, Any]]:
    if path is None or not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []

    entries: List[Dict[str, Any]] = []
    if isinstance(data, dict) and isinstance(data.get("attempts"), list):
        entries = [entry for entry in data["attempts"] if isinstance(entry, dict)]
    elif isinstance(data, list):
        entries = [entry for entry in data if isinstance(entry, dict)]
    elif isinstance(data, dict):
        for sample_id, value in data.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("sample_id", sample_id)
                entries.append(entry)

    allowed_keys = {
        "sample_id",
        "language_code",
        "status",
        "sourceUrl",
        "sourceUrls",
        "checkedAt",
        "nextAction",
        "evidence",
    }
    attempts: List[Dict[str, Any]] = []
    for entry in entries:
        raw_sample_id = entry.get("sample_id") or entry.get("sampleId") or entry.get("id")
        raw_status = entry.get("status")
        if not isinstance(raw_sample_id, str) or not raw_sample_id.strip():
            continue
        if not isinstance(raw_status, str) or not raw_status.strip():
            continue
        attempt = {key: entry[key] for key in allowed_keys if key in entry}
        attempt["sample_id"] = raw_sample_id.strip()
        attempt["status"] = raw_status.strip()
        attempts.append(attempt)
    return attempts


def recognition_reference_acquisition_risks(
    attempts: List[Dict[str, Any]],
) -> Dict[str, List[str]]:
    risks: Dict[str, List[str]] = {}
    for attempt in attempts:
        sample_id = attempt.get("sample_id")
        status = attempt.get("status")
        if not isinstance(sample_id, str) or not sample_id.strip():
            continue
        if not isinstance(status, str) or not status.strip():
            continue
        normalized_status = re.sub(r"[^A-Za-z0-9_.-]+", "_", status.strip())
        if not normalized_status or normalized_status.startswith("acquired_"):
            continue
        risk = f"referenceAcquisition:{normalized_status}"
        bucket = risks.setdefault(sample_id.strip(), [])
        if risk not in bucket:
            bucket.append(risk)
    return risks


def load_platform_caption_provenance_backfills(path: Optional[Path]) -> Dict[str, Dict[str, Any]]:
    if path is None or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

    entries: List[Dict[str, Any]] = []
    if isinstance(data, dict) and isinstance(data.get("backfills"), list):
        entries = [entry for entry in data["backfills"] if isinstance(entry, dict)]
    elif isinstance(data, list):
        entries = [entry for entry in data if isinstance(entry, dict)]
    elif isinstance(data, dict):
        for sample_id, value in data.items():
            if isinstance(value, dict):
                entry = dict(value)
                entry.setdefault("sample_id", sample_id)
                entries.append(entry)

    backfills: Dict[str, Dict[str, Any]] = {}
    for entry in entries:
        raw_sample_id = entry.get("sample_id") or entry.get("sampleId") or entry.get("id")
        if not isinstance(raw_sample_id, str) or not raw_sample_id.strip():
            continue
        raw_source_path = entry.get("sourcePath") or entry.get("source_path") or entry.get("path")
        if not isinstance(raw_source_path, str) or not raw_source_path.strip():
            continue
        if not has_manual_platform_provenance(entry) or not _has_url_evidence(entry):
            continue
        backfills.setdefault(raw_sample_id.strip(), entry)
    return backfills


def merge_recognition_judge_source_backfill(
    judge: Optional[Dict[str, Any]],
    sample_id: str,
    backfills: Optional[Dict[str, Dict[str, Any]]],
) -> Optional[Dict[str, Any]]:
    if not isinstance(judge, dict) or not backfills:
        return judge
    backfill = backfills.get(sample_id)
    if not isinstance(backfill, dict):
        return judge

    merged = dict(judge)
    if not _has_nonempty_list(merged.get("sourceUrls")) and _has_nonempty_list(backfill.get("sourceUrls")):
        merged["sourceUrls"] = backfill["sourceUrls"]
    if not _has_nonempty_list(merged.get("evidence")) and _has_nonempty_list(backfill.get("evidence")):
        merged["evidence"] = backfill["evidence"]
    return merged


def _has_nonempty_list(value: Any) -> bool:
    return isinstance(value, list) and any(str(item).strip() for item in value)


def _judge_score(
    judge: Optional[Dict[str, Any]],
    key: str,
    *,
    allow_pass_fallback: bool = True,
) -> Optional[float]:
    if not judge:
        return None
    value = judge.get(key)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        score = float(value)
        return score if math.isfinite(score) else None
    # pass/blocking 形式回退：pass 且无 blocking → 90，有 blocking → 40
    if allow_pass_fallback and isinstance(judge.get("pass"), bool):
        blocking = judge.get("blockingIssues") or []
        return 40.0 if blocking else (90.0 if judge["pass"] else 50.0)
    return None


def recognition_judge_evidence_notes(judge: Optional[Dict[str, Any]]) -> List[str]:
    if not isinstance(judge, dict):
        return []
    source_urls = judge.get("sourceUrls")
    if isinstance(source_urls, list) and any(str(url).strip() for url in source_urls):
        return ["judgeEvidence:sourceUrls"]
    evidence = judge.get("evidence")
    if isinstance(evidence, list):
        for item in evidence:
            text = str(item)
            if "http://" in text or "https://" in text:
                return ["judgeEvidence:evidenceUrls"]
    return ["judgeEvidence:sourceUrlsMissing"]


def clip_cues(cues: List[Cue], window: Optional[Tuple[float, float]]) -> List[Cue]:
    if not window:
        return cues
    lo, hi = window
    return [c for c in cues if c.end > lo and c.start < hi]


def _seconds_from_duration_match(match: re.Match[str]) -> float:
    hours = int(match.group(1))
    minutes = int(match.group(2))
    seconds = float(match.group(3))
    return hours * 3600 + minutes * 60 + seconds


def merge_speech_segments(
    *segment_groups: Optional[List[Dict[str, float]]],
    merge_gap_seconds: float = 0.40,
) -> List[Dict[str, float]]:
    segments: List[Dict[str, float]] = []
    for group in segment_groups:
        if not group:
            continue
        for segment in group:
            try:
                start = float(segment.get("start"))
                end = float(segment.get("end"))
            except (TypeError, ValueError):
                continue
            if math.isfinite(start) and math.isfinite(end) and end > start:
                segments.append({"start": start, "end": end})
    if not segments:
        return []
    segments.sort(key=lambda s: (s["start"], s["end"]))
    merged: List[Dict[str, float]] = []
    for segment in segments:
        if merged and segment["start"] - merged[-1]["end"] <= merge_gap_seconds:
            merged[-1]["end"] = max(merged[-1]["end"], segment["end"])
        else:
            merged.append(dict(segment))
    return merged


def speech_segments_from_silencedetect_log(log_text: str) -> List[Dict[str, float]]:
    duration: Optional[float] = None
    silence_ranges: List[Tuple[float, float]] = []
    pending_start: Optional[float] = None
    for line in log_text.splitlines():
        if duration is None:
            duration_match = DURATION_RE.search(line)
            if duration_match:
                duration = _seconds_from_duration_match(duration_match)
        start_match = SILENCE_START_RE.search(line)
        if start_match:
            pending_start = float(start_match.group(1))
        end_match = SILENCE_END_RE.search(line)
        if end_match:
            end = float(end_match.group(1))
            start = pending_start
            if start is None:
                duration_match = SILENCE_DURATION_RE.search(line)
                if duration_match:
                    start = end - float(duration_match.group(1))
            if start is not None and end > start:
                silence_ranges.append((max(0.0, start), end))
            pending_start = None
    if pending_start is not None and duration is not None and duration > pending_start:
        silence_ranges.append((pending_start, duration))
    if not silence_ranges:
        return []
    if duration is None:
        duration = max(end for _start, end in silence_ranges)

    speech_segments: List[Dict[str, float]] = []
    cursor = 0.0
    for start, end in sorted(silence_ranges):
        start = max(0.0, min(start, duration))
        end = max(start, min(end, duration))
        if start > cursor:
            speech_segments.append({"start": cursor, "end": start})
        cursor = max(cursor, end)
    if duration > cursor:
        speech_segments.append({"start": cursor, "end": duration})
    return merge_speech_segments(speech_segments)


def load_silencedetect_speech_segments(sample_dir: Path) -> List[Dict[str, float]]:
    for name in ["local-asr.silencedetect.log"]:
        path = sample_dir / name
        if path.is_file() and _clean(path.name):
            return speech_segments_from_silencedetect_log(path.read_text(encoding="utf-8", errors="ignore"))
    return []


def maybe_speech_segments(sample_dir: Path, enable: bool) -> Optional[List[Dict[str, float]]]:
    if not enable:
        return None
    wav = None
    for name in ["local-asr.wav"]:
        path = sample_dir / name
        if path.is_file() and _clean(path.name):
            wav = path
            break
    if wav is None:
        wavs = [p for p in sorted(sample_dir.glob("*.wav")) if _clean(p.name) and "whisper-cpp" not in p.name]
        wav = wavs[0] if wavs else None
    if wav is None:
        return None
    silence_segments = load_silencedetect_speech_segments(sample_dir)
    try:
        from subtitle_timing_eval.vad import detect_speech_file
        payload = detect_speech_file(str(wav), str(sample_dir / "scorecard.speech.json"))
        return merge_speech_segments(payload.get("segments"), silence_segments) or None
    except Exception as exc:  # noqa: BLE001 - acoustic is best-effort
        print(f"[acoustic skipped] {sample_dir.name}: {exc}", file=sys.stderr)
        return silence_segments or None


def score_sample(
    sample_dir: Path,
    *,
    acoustic: bool,
    batch_recognition_judges: Optional[Dict[str, Dict[str, Any]]] = None,
    recognition_judge_source_backfills: Optional[Dict[str, Dict[str, Any]]] = None,
    recognition_reference_acquisition_risks: Optional[Dict[str, List[str]]] = None,
    platform_caption_provenance_backfills: Optional[Dict[str, Dict[str, Any]]] = None,
) -> Optional[sc.SampleScorecard]:
    candidate, source_kind, source_record = pick_scored_source(sample_dir)
    if candidate is None:
        return None
    if source_kind != "local-asr":
        source_record = merge_platform_caption_provenance_backfill(
            source_record,
            sample_dir.name,
            candidate,
            sample_dir,
            platform_caption_provenance_backfills,
        )
    language = parse_language(candidate, sample_dir)
    window = parse_window(candidate.name)
    candidate_cues = load_subtitle_cues(candidate)
    if not candidate_cues:
        return None

    local_words = find_words(sample_dir, window)
    platform_words = platform_vtt_words(candidate) if source_kind != "local-asr" else None
    segmentation_words = local_words if source_kind == "local-asr" else platform_words
    rec_judge = load_agent_judge(sample_dir, "agent_recognition_judge.json")
    rec_judge_source: Optional[str] = "file" if rec_judge is not None else None
    if rec_judge is None and batch_recognition_judges:
        rec_judge = batch_recognition_judges.get(sample_dir.name)
        rec_judge_source = "batch" if rec_judge is not None else None
    rec_judge = merge_recognition_judge_source_backfill(
        rec_judge,
        sample_dir.name,
        recognition_judge_source_backfills,
    )

    reference_path = find_human_reference(sample_dir, language)
    reference_text: Optional[str] = None
    reference_seg_report: Optional[Dict[str, Any]] = None
    if reference_path:
        ref_cues = clip_cues(load_subtitle_cues(reference_path), window)
        if ref_cues:
            reference_text = "\n".join(c.text for c in ref_cues)
            reference_seg_report = evaluate_segmentation(
                candidate_cues, ref_cues, sample_dir.name,
                window_start=window[0] if window else None,
                window_end=window[1] if window else None,
            )
    if reference_text is None:
        reference_text = load_human_word_reference(sample_dir, window)
    manual_platform_reference = False
    explicit_manual_platform = source_kind != "local-asr" and has_manual_platform_provenance(source_record)
    if reference_text is None and explicit_manual_platform:
        reference_text = "\n".join(c.text for c in candidate_cues)
        manual_platform_reference = True

    rec_llm_accuracy_score = _judge_score(
        rec_judge,
        "accuracyScore",
        allow_pass_fallback=False,
    )
    recognition = sc.recognition_score(
        candidate_cues=candidate_cues,
        language_code=language,
        words=local_words if source_kind == "local-asr" else None,
        reference_text=reference_text,
        llm_accuracy_score=rec_llm_accuracy_score,
    )
    if rec_judge is not None and rec_llm_accuracy_score is None:
        ignored_note = (
            "ignored:batch_recognition_judge:unscored"
            if rec_judge_source == "batch"
            else "ignored:agent_recognition_judge:unscored"
        )
        recognition = replace(
            recognition,
            notes=[*recognition.notes, ignored_note],
        )
    elif rec_judge_source == "batch":
        recognition = replace(
            recognition,
            notes=[*recognition.notes, "judge:batch"],
        )
    elif manual_platform_reference:
        recognition = replace(
            recognition,
            notes=[*recognition.notes, "reference:manualPlatformSource"],
        )
    elif rec_judge is None and (sample_dir / "llm_quality_judge.json").is_file():
        recognition = replace(
            recognition,
            notes=[*recognition.notes, "ignored:llm_quality_judge:holistic"],
        )
    if rec_llm_accuracy_score is not None:
        recognition = replace(
            recognition,
            notes=[*recognition.notes, *recognition_judge_evidence_notes(rec_judge)],
        )

    evidence_risks = load_source_report_evidence_risks(sample_dir)
    if recognition_reference_acquisition_risks:
        for risk in recognition_reference_acquisition_risks.get(sample_dir.name, []):
            if risk not in evidence_risks:
                evidence_risks.append(risk)
    if source_kind != "local-asr" and not explicit_manual_platform:
        evidence_risks.append("platform:manualProvenanceMissing")
    if rec_judge is None and (sample_dir / "llm_quality_judge.json").is_file():
        evidence_risks.append("recognition:holisticJudgeIgnored")

    segmentation = sc.segmentation_score(
        candidate_cues=candidate_cues,
        language_code=language,
        reference_report=reference_seg_report,
        speech_segments=maybe_speech_segments(sample_dir, acoustic),
        words=segmentation_words,
        allow_speech_first_onset=source_kind == "local-asr",
    )

    translated = find_translated(sample_dir, source_path=candidate)
    translation: Optional[sc.DimensionScore] = None
    if translated:
        tr_judge = load_agent_judge(sample_dir, "agent_translation_judge.json")
        translation = sc.translation_score(
            source_cues=candidate_cues,
            translated_cues=load_subtitle_cues(translated),
            llm_translation_score=_judge_score(tr_judge, "score"),
        )

    dimensions = {"recognition": recognition, "segmentation": segmentation}
    if translation is not None:
        dimensions["translation"] = translation
    return sc.SampleScorecard(
        sample_id=sample_dir.name,
        language_code=language or "unknown",
        category=_infer_category(sample_dir.name),
        dimensions=dimensions,
        scored_source_kind=source_kind,
        scored_source_path=str(candidate),
        audio_review_paths=recognition_audio_review_paths(str(candidate)),
        evidence_risks=evidence_risks,
    )


def _infer_category(name: str) -> str:
    low = name.lower()
    if any(t in low for t in ["song", "yoasobi", "ado", "lyric", "gunjou", "lemon", "gurenge", "music", "mv", "jpop"]):
        return "music"
    if any(t in low for t in ["anime", "animation", "koupen"]):
        return "anime"
    if any(t in low for t in ["ted", "talk", "lecture", "tutorial", "interview", "self_study"]):
        return "talk"
    if "vlog" in low:
        return "vlog"
    return "other"


def build_agent_recognition_prompt(
    sample: sc.SampleScorecard,
    source_cues: List[Cue],
    *,
    max_cues: int = 80,
) -> str:
    recognition = sample.dimensions.get("recognition")
    components = recognition.components if recognition else {}
    notes = recognition.notes if recognition else []
    rows = "\n".join(
        f"{cue.index}. {cue.start:.2f}-{cue.end:.2f} | {cue.text}"
        for cue in source_cues[:max_cues]
    ) or "(no source cues)"
    audio_paths = sample.audio_review_paths or recognition_audio_review_paths(sample.scored_source_path)
    audio_rows = "\n".join(f"- {path}" for path in audio_paths) or "- none found"
    return (
        "你是 Moongate 的识别准确率评审。目标是判断最终源字幕是否真的把音频内容转写对了，"
        "不是判断分段、翻译或 UI。\n"
        "优先证据：人工字幕/官方歌词/可靠转写；没有可靠参考时，可以听音频或做保守语言一致性判断，"
        "但证据不足就不要硬给分。\n"
        "重点抓自信乱码、错词、错语言、漏掉关键句、罗马音/音近义错；不要因为轻微断行或标点差异降大分。\n"
        "reference_acquisition_checklist:\n"
        "1. 先找人工字幕、官方歌词页、平台手动字幕 provenance、或可靠逐字稿，并在 sourceUrls 里记录 URL/文件路径。\n"
        "2. 若只能看到本地 ASR 文本、Whisper 置信度、结构分、或 holistic viewing-quality judge，不足以给 numeric 分。\n"
        "3. 没有可靠参考或音频复核时 accuracyScore 必须为 null；不要为了补 coverage 猜一个通过分。\n"
        "4. 可以引用少量关键错词/漏词作为 evidence，但不要复制整段歌词或大段字幕。\n"
        "只输出 JSON，建议写入 agent_recognition_judge.json，schema 固定为：\n"
        "{\"accuracyScore\": number|null, \"issues\": [string], \"notes\": string, "
        "\"judgedBy\": \"agent\", \"language\": string, \"evidence\": [string], "
        "\"confidence\": \"low|medium|high\", \"sourceUrls\": [string]}\n\n"
        f"sample_id: {sample.sample_id}\n"
        f"language_code: {sample.language_code}\n"
        f"category: {sample.category}\n"
        f"source_kind: {sample.scored_source_kind}\n"
        f"source_path: {sample.scored_source_path or 'unknown'}\n"
        f"recognition_score: {recognition.score if recognition else 'unknown'}\n"
        f"recognition_components: {json.dumps(components, ensure_ascii=False, sort_keys=True)}\n"
        f"recognition_notes: {json.dumps(notes, ensure_ascii=False)}\n"
        f"evidence_risks: {json.dumps(sample.evidence_risks, ensure_ascii=False)}\n\n"
        "audio_review_paths:\n"
        f"{audio_rows}\n\n"
        "source_cues:\n"
        f"{rows}\n"
    )


def recognition_audio_review_paths(source_path: Optional[str]) -> List[str]:
    if not source_path:
        return []
    path = Path(source_path)
    base = path.parent if path.parent != Path("") else Path(".")
    candidates: List[Path] = []
    for name in ["local-asr.wav", "clip.wav"]:
        candidate = base / name
        if candidate.is_file() and _clean(candidate.name):
            candidates.append(candidate)
    for folder_name in ["source", "local-asr-media"]:
        folder = base / folder_name
        if not folder.is_dir():
            continue
        for pattern in ["*.webm", "*.mp4", "*.m4a", "*.mp3", "*.wav"]:
            for candidate in sorted(folder.glob(pattern)):
                if candidate.is_file() and _clean(candidate.name):
                    candidates.append(candidate)
    unique: List[str] = []
    seen = set()
    for candidate in candidates:
        text = str(candidate)
        if text in seen:
            continue
        seen.add(text)
        unique.append(text)
    return unique


def write_agent_recognition_prompts(samples: List[sc.SampleScorecard], *, limit: int = 0) -> List[Path]:
    written: List[Path] = []
    for sample in samples:
        recognition = sample.dimensions.get("recognition")
        if recognition is None or recognition.verified:
            continue
        if not sample.scored_source_path:
            continue
        source_path = Path(sample.scored_source_path)
        if not source_path.is_file():
            continue
        source_cues = load_subtitle_cues(source_path)
        if not source_cues:
            continue
        prompt_path = source_path.parent / "agent_recognition.prompt.md"
        prompt_path.write_text(build_agent_recognition_prompt(sample, source_cues), encoding="utf-8")
        written.append(prompt_path)
        if limit > 0 and len(written) >= limit:
            break
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Moongate subtitle quality scorecard baseline.")
    parser.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS)
    parser.add_argument("--roots", nargs="*", help="Only score these subdirectories (names under --artifacts).")
    parser.add_argument("--acoustic", action="store_true", help="Also compute energy-VAD acoustic boundary agreement (needs ffmpeg).")
    parser.add_argument("--scenarios", type=Path, default=ROOT / "tools/subtitle_timing_eval/source_decision_scenarios.json")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_ARTIFACTS / "scorecard")
    parser.add_argument("--write-recognition-prompts", action="store_true", help="Write agent_recognition.prompt.md for unverified recognition samples.")
    parser.add_argument("--recognition-prompt-limit", type=int, default=0, help="Limit prompt files written; 0 means no limit.")
    parser.add_argument("--recognition-judges", type=Path, help="Optional batch JSON file of recognition judges keyed by sample_id.")
    parser.add_argument(
        "--recognition-judge-source-backfills",
        type=Path,
        help="Optional JSON file of sourceUrls/evidence to merge into existing numeric recognition judges by sample_id.",
    )
    parser.add_argument(
        "--recognition-reference-acquisition",
        type=Path,
        help="Optional JSON file of reference acquisition attempts for the planning report; never used for scoring.",
    )
    parser.add_argument(
        "--platform-caption-provenance-backfills",
        type=Path,
        help="Optional JSON file of explicit uploaded/manual platform subtitle provenance to merge into selected source candidates.",
    )
    args = parser.parse_args()

    if args.roots:
        sample_dirs = [args.artifacts / r for r in args.roots]
    else:
        sample_dirs = [p for p in sorted(args.artifacts.iterdir()) if p.is_dir()]
        # 也下钻一层(viewing_quality/<song> 这种嵌套)
        nested: List[Path] = []
        for d in sample_dirs:
            if pick_candidate(d) is None:
                nested.extend([c for c in sorted(d.iterdir()) if c.is_dir()])
        sample_dirs.extend(nested)

    batch_recognition_judges = load_batch_recognition_judges(args.recognition_judges)
    recognition_judge_source_backfills = load_recognition_judge_source_backfills(
        args.recognition_judge_source_backfills
    )
    recognition_reference_acquisition = load_recognition_reference_acquisition(
        args.recognition_reference_acquisition
    )
    reference_acquisition_risks = recognition_reference_acquisition_risks(
        recognition_reference_acquisition
    )
    platform_caption_provenance_backfills = load_platform_caption_provenance_backfills(
        args.platform_caption_provenance_backfills
    )
    samples: List[sc.SampleScorecard] = []
    for sample_dir in sample_dirs:
        if not sample_dir.is_dir():
            continue
        try:
            result = score_sample(
                sample_dir,
                acoustic=args.acoustic,
                batch_recognition_judges=batch_recognition_judges,
                recognition_judge_source_backfills=recognition_judge_source_backfills,
                recognition_reference_acquisition_risks=reference_acquisition_risks,
                platform_caption_provenance_backfills=platform_caption_provenance_backfills,
            )
        except Exception as exc:  # noqa: BLE001 - one bad sample shouldn't kill the suite
            print(f"[scorecard error] {sample_dir.name}: {exc}", file=sys.stderr)
            continue
        if result is not None:
            samples.append(result)

    # 嵌套扫描可能让同一 sample_id 出现多次(如 viewing_quality/<song> 与 songs30/<song>)；
    # 按 sample_id 去重,保留维度更全(含翻译)的那条。严格 `>` 确保平分时保留先见者(sample_dirs 已排序→确定性)。
    def _richness(s: sc.SampleScorecard) -> int:
        return len(s.dimensions) + sum(1 for d in s.dimensions.values() if d.verified)
    deduped: Dict[str, sc.SampleScorecard] = {}
    for s in samples:
        existing = deduped.get(s.sample_id)
        if existing is None or _richness(s) > _richness(existing):
            deduped[s.sample_id] = s
    samples = sorted(deduped.values(), key=lambda s: s.sample_id)

    scenarios: List[Dict[str, Any]] = []
    if args.scenarios.is_file():
        scenarios = json.loads(args.scenarios.read_text(encoding="utf-8")).get("scenarios", [])
    source_decision = sc.source_decision_score(scenarios) if scenarios else None

    summary = sc.suite_summary(samples, source_decision)
    backlog = sc.quality_backlog(samples, source_decision)
    recognition_queue = sc.recognition_review_queue(samples)
    recognition_evidence_plan = sc.recognition_evidence_plan(samples)
    if recognition_reference_acquisition:
        recognition_evidence_plan["reference_acquisition_attempts"] = recognition_reference_acquisition
    if args.write_recognition_prompts:
        prompt_paths = write_agent_recognition_prompts(samples, limit=max(0, args.recognition_prompt_limit))
        print(f"wrote {len(prompt_paths)} recognition prompt(s)", file=sys.stderr)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "summary": summary,
        "backlog": backlog,
        "recognition_review_queue": recognition_queue,
        "recognition_evidence_plan": recognition_evidence_plan,
        "source_decision": {
            "score": source_decision.score if source_decision else None,
            "notes": source_decision.notes if source_decision else [],
            "verified": source_decision.verified if source_decision else False,
        },
        "samples": [
            {
                "sample_id": s.sample_id,
                "language_code": s.language_code,
                "category": s.category,
                "scored_source_kind": s.scored_source_kind,
                "scored_source_path": s.scored_source_path,
                "evidence_risks": s.evidence_risks,
                "dimensions": {
                    name: {
                        "score": dim.score,
                        "components": dim.components,
                        "capped": dim.capped,
                        "notes": dim.notes,
                        "verified": dim.verified,
                    }
                    for name, dim in s.dimensions.items()
                },
            }
            for s in samples
        ],
    }
    (args.out_dir / "scorecard.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.out_dir / "scorecard.md").write_text(sc.render_markdown(samples, summary, source_decision), encoding="utf-8")
    (args.out_dir / "recognition_review_queue.md").write_text(
        sc.render_recognition_review_queue_markdown(recognition_queue),
        encoding="utf-8",
    )
    (args.out_dir / "recognition_evidence_plan.md").write_text(
        sc.render_recognition_evidence_plan_markdown(recognition_evidence_plan),
        encoding="utf-8",
    )
    (args.out_dir / "recognition_review_packet.md").write_text(
        sc.render_recognition_review_packet_markdown(recognition_evidence_plan),
        encoding="utf-8",
    )
    (args.out_dir / "recognition_review_packet.html").write_text(
        sc.render_recognition_review_packet_html(recognition_evidence_plan),
        encoding="utf-8",
    )
    (args.out_dir / "recognition_review_judge_templates.json").write_text(
        json.dumps(sc.recognition_review_judge_templates(recognition_evidence_plan), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\nwrote {args.out_dir / 'scorecard.json'}")
    print(f"wrote {args.out_dir / 'scorecard.md'}")
    print(f"wrote {args.out_dir / 'recognition_review_queue.md'}")
    print(f"wrote {args.out_dir / 'recognition_evidence_plan.md'}")
    print(f"wrote {args.out_dir / 'recognition_review_packet.md'}")
    print(f"wrote {args.out_dir / 'recognition_review_packet.html'}")
    print(f"wrote {args.out_dir / 'recognition_review_judge_templates.json'}")


if __name__ == "__main__":
    main()

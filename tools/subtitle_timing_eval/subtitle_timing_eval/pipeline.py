from __future__ import annotations

import html
import json
import os
import random
import subprocess
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence
from urllib.parse import quote

from .asr import transcribe_words, transcribe_words_whisper_cpp
from .comparison import compare_reports, summarize_suite
from .segmentation import (
    evaluate_segmentation,
    summarize_suite as summarize_segmentation_reports,
)
from .metrics import (
    ACCEPTED_END_MAX_MS,
    ACCEPTED_END_MIN_MS,
    ACCEPTED_START_MAX_MS,
    ACCEPTED_START_MIN_MS,
    cjk_singleton,
    cue_tokens,
    evaluate_cues,
    evaluate_cues_against_reference_cues,
    is_short_feedback,
    load_words_json,
    offset_words,
    summarize_report,
    weak_boundary,
)
from .srt import Cue, parse_srt, serialize_srt
from .vad import detect_speech_file
from .vtt import parse_vtt_cues, parse_vtt_word_timestamps

WINDOW_COVERAGE_MIN_RATIO = 0.9
WINDOW_COVERAGE_TOLERANCE_SECONDS = 5.0
READING_SPEED_P90_GATE = 24.0
HUMAN_VERDICT_SOURCES = {"human", "human_review", "manual", "manual_review"}
ITERATION_ISSUES: Dict[str, Dict[str, Any]] = {
    "accepted_ratio": {
        "priority": 10,
        "label": "90% timing gate",
        "suggested_action": "Improve the dominant timing/splitting failures before treating the sample as release-ready.",
    },
    "start_onset_drift": {
        "priority": 10,
        "label": "Cue appears too early or too late",
        "suggested_action": "Inspect ASR token timestamps, DTW/VAD offset handling, and long-audio drift before tuning segmentation.",
    },
    "end_offset_drift": {
        "priority": 10,
        "label": "Cue disappears too early or lingers too long",
        "suggested_action": "Tune retiming hold/guard only after confirming the candidate and reference boundaries are comparable.",
    },
    "early_cutoff": {
        "priority": 10,
        "label": "Subtitle cuts off before speech finishes",
        "suggested_action": "Favor holding through the acoustic end of the utterance and avoid clamping to the next cue too aggressively.",
    },
    "long_idle_hold": {
        "priority": 10,
        "label": "Subtitle stays after speech has clearly stopped",
        "suggested_action": "Trim long silent tails with speech-aware windows, especially after long pauses.",
    },
    "weak_boundary": {
        "priority": 10,
        "label": "Split lands on a weak semantic boundary",
        "suggested_action": "Merge orphan tails and avoid splitting after weak connector words or before particles.",
    },
    "cjk_singleton": {
        "priority": 10,
        "label": "CJK singleton or residual fragment",
        "suggested_action": "Drop residual kana/punctuation or merge short CJK fragments into neighboring phrases.",
    },
    "reading_speed": {
        "priority": 10,
        "label": "Reading speed is too high",
        "suggested_action": "Split dense cues at stronger phrase boundaries without creating orphan fragments.",
    },
    "missing_artifact": {
        "priority": 0,
        "label": "Sample has no usable comparison artifact",
        "suggested_action": "Run prepare, ASR/reference extraction, metrics, and compare before judging algorithm quality.",
    },
    "blocked_artifact": {
        "priority": 0,
        "label": "Sample is externally blocked",
        "suggested_action": "Refresh the source, retry after rate limits, or replace the sample with the same language/stressor coverage.",
    },
    "insufficient_window": {
        "priority": 0,
        "label": "Sample window is too short",
        "suggested_action": "Regenerate the comparison over the manifest window so smoke results cannot masquerade as full coverage.",
    },
}


def validate_manifest(data: Dict[str, Any]) -> None:
    errors: List[str] = []
    samples = data.get("samples")
    if not isinstance(samples, list):
        raise ValueError("manifest must contain a samples array")
    coverage_goal = data.get("coverage_goal") or {}
    required_groups = coverage_goal.get("required_language_groups") or []
    if not isinstance(required_groups, list) or not required_groups:
        errors.append("coverage_goal.required_language_groups must list the target language groups")

    seen_ids = set()
    language_groups = set()
    for index, sample in enumerate(samples):
        prefix = "samples[%d]" % index
        sample_id = sample.get("id")
        if not sample_id:
            errors.append("%s.id is required" % prefix)
        elif sample_id in seen_ids:
            errors.append("duplicate sample id: %s" % sample_id)
        else:
            seen_ids.add(sample_id)
        if not sample.get("source"):
            errors.append("%s.source is required" % prefix)
        language_group = sample.get("language_group")
        if not language_group:
            errors.append("%s.language_group is required" % prefix)
        else:
            language_groups.add(language_group)
        if not sample.get("subtitle_lang"):
            errors.append("%s.subtitle_lang is required" % prefix)
        spoken_languages = sample.get("spoken_languages")
        if not isinstance(spoken_languages, list) or not spoken_languages:
            errors.append("%s.spoken_languages must be a non-empty list" % prefix)
        section = sample.get("section") or {}
        duration = float(section.get("duration_seconds", 0))
        if duration < 60 or duration > 360:
            errors.append("%s.section.duration_seconds must be between 60 and 360" % prefix)
        if sample.get("category") == "auto_translate" and sample.get("alignment_mode") != "overlap":
            errors.append("%s auto_translate samples must use alignment_mode=overlap" % prefix)

    missing_groups = sorted(set(required_groups) - language_groups)
    if missing_groups:
        errors.append("missing required language groups: %s" % ", ".join(missing_groups))
    if errors:
        raise ValueError("; ".join(errors))


def load_manifest(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    validate_manifest(data)
    return data


def _is_manual_caption_sample(sample: Dict[str, Any]) -> bool:
    stressors = set(sample.get("stressors") or [])
    if "automatic_captions" in stressors or "app_translation_timing_proxy" in stressors:
        return False
    # For the manual-caption suite, the practical rule is broad: any normal
    # subtitle track is eligible unless YouTube marks it as auto-recognized.
    automatic_kinds = {
        "auto",
        "automatic",
        "automatic_captions",
        "auto-generated",
        "autogenerated",
        "asr",
        "youtube_auto",
        "youtube_automatic",
        "youtube_auto_generated",
        "yt_auto",
        "yt_asr",
    }
    if str(sample.get("caption_kind") or "").lower() in automatic_kinds:
        return False
    if str(sample.get("reference_kind") or "").lower() in automatic_kinds:
        return False
    subtitle_lang = str(sample.get("subtitle_lang") or "")
    if subtitle_lang.endswith("-orig"):
        return False
    return bool(subtitle_lang)


def _manual_suite_language(sample: Dict[str, Any]) -> str:
    override = sample.get("manual_suite_language")
    if override:
        return str(override)
    spoken = sample.get("spoken_languages") or []
    if spoken:
        return str(spoken[0])
    return str(sample.get("language_group", "unknown"))


def select_manual_caption_suite(
    manifest: Dict[str, Any],
    count: int = 10,
    seed: Optional[str] = None,
    excluded_sample_ids: Optional[Sequence[str]] = None,
) -> Dict[str, Any]:
    validate_manifest(manifest)
    if count <= 0:
        raise ValueError("count must be positive")
    rng = random.Random(seed)
    excluded = set(excluded_sample_ids or [])
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for sample in manifest["samples"]:
        if sample.get("id") in excluded:
            continue
        if not _is_manual_caption_sample(sample):
            continue
        grouped.setdefault(_manual_suite_language(sample), []).append(sample)

    available_groups = sorted(grouped)
    selected_groups = available_groups[:]
    rng.shuffle(selected_groups)
    selected_groups = selected_groups[:min(count, len(selected_groups))]
    selected: List[Dict[str, Any]] = []
    for group in selected_groups:
        candidates = sorted(grouped[group], key=lambda item: item["id"])
        sample = rng.choice(candidates)
        selected.append({
            "id": sample["id"],
            "language_group": sample.get("language_group", group),
            "suite_language": group,
            "title": sample.get("title", sample["id"]),
            "source": sample["source"],
            "subtitle_lang": sample.get("subtitle_lang"),
            "spoken_languages": sample.get("spoken_languages", []),
            "category": sample.get("category"),
            "section": sample.get("section", {}),
        })
    selected.sort(key=lambda item: item["suite_language"])
    missing = max(0, count - len(selected))
    ready = missing == 0
    return {
        "requested_count": count,
        "selected_count": len(selected),
        "ready": ready,
        "seed": seed,
        "requires_human_captions": True,
        "distinct_language_groups_required": True,
        "excluded_sample_ids": sorted(excluded),
        "available_manual_caption_sample_count": sum(len(items) for items in grouped.values()),
        "available_language_groups": available_groups,
        "missing_distinct_language_count": missing,
        "rejection_reason": None if ready else "not_enough_distinct_manual_caption_languages",
        "selected": selected,
    }


def audit_manual_caption_suite(
    manifest: Dict[str, Any],
    artifacts_root: str,
    seeds: Sequence[str],
    count: int = 10,
    excluded_sample_ids: Optional[Sequence[str]] = None,
) -> Dict[str, Any]:
    validate_manifest(manifest)
    if count <= 0:
        raise ValueError("count must be positive")
    if not seeds:
        raise ValueError("at least one seed is required")

    excluded = set(excluded_sample_ids or [])
    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for sample in manifest["samples"]:
        if sample.get("id") in excluded:
            continue
        if not _is_manual_caption_sample(sample):
            continue
        grouped.setdefault(_manual_suite_language(sample), []).append(sample)

    language_candidate_counts = {
        language: len(samples)
        for language, samples in sorted(grouped.items())
    }
    thin_language_groups = [
        language
        for language, sample_count in language_candidate_counts.items()
        if sample_count < 2
    ]
    selected_frequency: Dict[str, int] = {}
    seed_results: List[Dict[str, Any]] = []

    for seed in seeds:
        selection = select_manual_caption_suite(
            manifest,
            count=count,
            seed=seed,
            excluded_sample_ids=excluded_sample_ids,
        )
        status = collect_manual_suite_status(manifest, selection, artifacts_root)
        selected_ids = [item["id"] for item in selection.get("selected", [])]
        for sample_id in selected_ids:
            selected_frequency[sample_id] = selected_frequency.get(sample_id, 0) + 1
        seed_results.append({
            "seed": seed,
            "ready": selection["ready"],
            "selected_count": selection["selected_count"],
            "selected_sample_ids": selected_ids,
            "selected_language_groups": [item["suite_language"] for item in selection.get("selected", [])],
            "passes_manual_suite_gate": status["passes_manual_suite_gate"],
            "passes_strict_timing_gate": status["passes_strict_timing_gate"],
            "passes_sample_completion_gate": status["passes_sample_completion_gate"],
            "missing_samples": status["missing_samples"],
            "blocked_samples": status["blocked_samples"],
            "failing_samples": status["failing_samples"],
            "insufficient_window_samples": status["insufficient_window_samples"],
            "missing_strict_timing_language_groups": status["missing_strict_timing_language_groups"],
            "failing_strict_timing_language_groups": status["failing_strict_timing_language_groups"],
        })

    passing_seed_count = sum(1 for item in seed_results if item["passes_manual_suite_gate"])
    failing_seed_results = [item for item in seed_results if not item["passes_manual_suite_gate"]]
    return {
        "requested_count": count,
        "seed_count": len(seed_results),
        "passing_seed_count": passing_seed_count,
        "failing_seed_count": len(seed_results) - passing_seed_count,
        "passes_all_seed_gates": passing_seed_count == len(seed_results),
        "requires_human_captions": True,
        "distinct_language_groups_required": True,
        "excluded_sample_ids": sorted(excluded),
        "available_manual_caption_sample_count": sum(language_candidate_counts.values()),
        "available_language_groups": sorted(language_candidate_counts),
        "language_candidate_counts": language_candidate_counts,
        "thin_language_groups": thin_language_groups,
        "effective_random_language_groups": [
            language
            for language, sample_count in language_candidate_counts.items()
            if sample_count > 1
        ],
        "selected_sample_frequency": dict(sorted(selected_frequency.items())),
        "seed_results": seed_results,
        "failing_seed_results": failing_seed_results,
    }


def _manual_suite_filtered_manifest(manifest: Dict[str, Any], selection: Dict[str, Any]) -> Dict[str, Any]:
    manifest_samples = manifest.get("samples")
    if not isinstance(manifest_samples, list):
        raise ValueError("manifest must contain a samples array")
    samples_by_id = {sample["id"]: sample for sample in manifest_samples if sample.get("id")}
    filtered_samples: List[Dict[str, Any]] = []
    required_groups: List[str] = []
    for selected in selection.get("selected", []):
        sample_id = selected.get("id")
        if sample_id not in samples_by_id:
            raise ValueError("manual suite selected unknown sample id: %s" % sample_id)
        suite_language = str(selected.get("suite_language") or _manual_suite_language(samples_by_id[sample_id]))
        sample = dict(samples_by_id[sample_id])
        sample["language_group"] = suite_language
        sample["manual_suite_language"] = suite_language
        filtered_samples.append(sample)
        if suite_language not in required_groups:
            required_groups.append(suite_language)
    required_groups.sort()
    filtered_samples.sort(key=lambda item: item["id"])
    suite_manifest = {
        "coverage_goal": {"required_language_groups": required_groups},
        "samples": filtered_samples,
    }
    if filtered_samples:
        validate_manifest(suite_manifest)
    return suite_manifest


def collect_manual_suite_status(
    manifest: Dict[str, Any],
    selection: Dict[str, Any],
    artifacts_root: str,
) -> Dict[str, Any]:
    suite_manifest = _manual_suite_filtered_manifest(manifest, selection)
    selected_sample_ids = [sample["id"] for sample in suite_manifest["samples"]]
    if not selected_sample_ids:
        return {
            "required_language_groups": [],
            "covered_language_groups": [],
            "timing_language_groups": [],
            "preservation_language_groups": [],
            "missing_language_groups": [],
            "missing_strict_timing_language_groups": [],
            "failing_language_groups": [],
            "failing_strict_timing_language_groups": [],
            "passes_language_coverage_gate": False,
            "passes_strict_timing_gate": False,
            "passes_sample_completion_gate": False,
            "passes_timing_gate": False,
            "passes_manual_suite_gate": False,
            "requires_strict_timing_gate": True,
            "selection_ready": bool(selection.get("ready")),
            "requested_count": selection.get("requested_count"),
            "selected_count": 0,
            "selected_sample_ids": [],
            "sample_count": 0,
            "comparison_count": 0,
            "blocker_count": 0,
            "missing_samples": [],
            "blocked_samples": [],
            "failing_samples": [],
            "insufficient_window_samples": [],
            "samples": {},
        }

    status = collect_eval_status(suite_manifest, artifacts_root)
    scoped_comparison_count = sum(
        1 for sample in status["samples"].values() if sample.get("comparison")
    )
    status["artifact_comparison_count"] = status["comparison_count"]
    status["comparison_count"] = scoped_comparison_count
    status["selection_ready"] = bool(selection.get("ready"))
    status["requested_count"] = selection.get("requested_count")
    status["selected_count"] = len(selected_sample_ids)
    status["selected_sample_ids"] = selected_sample_ids
    status["requires_strict_timing_gate"] = True
    status["passes_manual_suite_gate"] = (
        status["selection_ready"]
        and status["passes_strict_timing_gate"]
        and status["passes_sample_completion_gate"]
    )
    return status


def _resolve_report_path(path_value: Any, comparison_path: str) -> Optional[Path]:
    if not path_value:
        return None
    path = Path(str(path_value))
    if path.is_absolute():
        return path
    comparison_dir = Path(comparison_path).parent
    candidates = [
        comparison_dir / path,
        comparison_dir.parent / path,
        path,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def _is_local_asr_candidate_path(path: Optional[Path]) -> bool:
    if path is None:
        return False
    name = path.name.lower()
    # Local-ASR source SRTs are written as "<stem>.local-asr.<lang>.srt" (Swift/C# WriteLocalAsrSourceSrt),
    # and eval candidates copy that "local-asr.<lang>.srt" tail. Require the local-asr marker and a
    # .srt extension; reject .vtt platform captions and anything without the marker.
    return "local-asr" in name and name.endswith(".srt")


def _is_human_reference_path(path: Optional[Path]) -> bool:
    # The only acceptable reference for local-ASR scoring is a human caption / lyric .srt — never a
    # platform .vtt auto-caption (that is the old self-referential evidence we are banning).
    if path is None:
        return False
    name = path.name.lower()
    if not name.endswith(".srt"):
        return False
    if "vtt" in name:
        return False
    # A local-asr candidate is not a human reference; scoring local-asr against itself is self-reference.
    return not _is_local_asr_candidate_path(path)


def _comparison_uses_local_asr(comparison: Dict[str, Any], sample: Dict[str, Any]) -> bool:
    comparison_path = comparison.get("_path")
    if not comparison_path:
        return False
    _, optimized_report = _load_reports_for_comparison(str(comparison_path))
    if not optimized_report:
        return False
    candidate = _resolve_report_path(optimized_report.get("candidate_path"), str(comparison_path))
    if not _is_local_asr_candidate_path(candidate):
        return False
    if candidate is not None and not candidate.exists():
        return False
    reference = _resolve_report_path(optimized_report.get("reference_path"), str(comparison_path))
    # Reference must be a human .srt that exists and is not the candidate itself (no self-reference).
    if reference is None or not reference.exists():
        return False
    if not _is_human_reference_path(reference):
        return False
    if candidate is not None and reference.resolve() == candidate.resolve():
        return False
    # If word-level evidence is recorded it must come from local-ASR, never the platform VTT words.
    words_path = _resolve_report_path(optimized_report.get("asr_words_path"), str(comparison_path))
    if words_path is not None:
        if not words_path.exists():
            return False
        if "vtt" in words_path.name.lower():
            return False
    return True


def _coverage_category(category: Optional[str], required_categories: List[str]) -> Optional[str]:
    """Map a sample's specific ``category`` tag onto a ``category_coverage_goal`` bucket.

    Most required categories (music_lyrics, japanese_talk, …) match a sample category verbatim, but a
    few are buckets: ``english_talk`` covers english_interview/lecture/tutorial/vlog, and ``animation``
    covers japanese_animation/chinese_animation. Direct matches win; otherwise apply the bucket rules.
    """
    if not category:
        return None
    if category in required_categories:
        return category
    if category.startswith("english_"):
        return "english_talk"
    if category == "animation" or category.endswith("_animation"):
        return "animation"
    return category


def _local_asr_artifacts_for_sample(sample_dir: Path) -> Dict[str, List[str]]:
    # Accept both the bare "local-asr*.srt" eval-copy tail and the full "<stem>.local-asr.<lang>.srt"
    # name Swift/C# WriteLocalAsrSourceSrt emits, so artifacts copied verbatim are still discovered.
    local_srts = sorted({
        str(path)
        for pattern in ("local-asr*.srt", "*.local-asr.*.srt")
        for path in sample_dir.glob(pattern)
    })
    asr_words = sorted(
        str(path)
        for path in sample_dir.glob("asr_words*.json")
        if "vtt" not in path.name.lower() and "srt" not in path.name.lower()
    )
    media = sorted(
        str(path)
        for pattern in ("*.m4a", "*.wav", "*.webm", "*.mp4")
        for path in sample_dir.glob(pattern)
    )
    return {
        "local_asr_srt": local_srts,
        "asr_words": asr_words,
        "media": media,
    }


def collect_local_asr_suite_status(
    manifest: Dict[str, Any],
    selection: Dict[str, Any],
    artifacts_root: str,
) -> Dict[str, Any]:
    suite_manifest = _manual_suite_filtered_manifest(manifest, selection)
    status = collect_eval_status(
        suite_manifest,
        artifacts_root,
        comparison_filter=_comparison_uses_local_asr,
    )
    selected_sample_ids = [sample["id"] for sample in suite_manifest["samples"]]
    category_goal = manifest.get("category_coverage_goal") or {}
    required_categories = list(category_goal.get("required_categories", []))
    covered_categories = set()
    root = Path(artifacts_root)
    missing_local_asr_samples: List[str] = []
    local_asr_groups = set()
    for sample in suite_manifest["samples"]:
        sample_id = sample["id"]
        sample_dir = root / sample_id
        artifacts = _local_asr_artifacts_for_sample(sample_dir)
        sample_status = status["samples"].setdefault(sample_id, {
            "status": "missing",
            "language_group": sample.get("language_group", "unknown"),
        })
        sample_status["local_asr_artifacts"] = artifacts
        comparison_path = sample_status.get("comparison")
        if comparison_path:
            _, optimized_report = _load_reports_for_comparison(str(comparison_path))
            candidate = _resolve_report_path((optimized_report or {}).get("candidate_path"), str(comparison_path))
            if candidate is not None:
                sample_status["local_asr_candidate"] = str(candidate)
        has_required_artifacts = bool(artifacts["local_asr_srt"]) and bool(artifacts["asr_words"]) and bool(artifacts["media"])
        if sample_status.get("status") == "pass" and has_required_artifacts:
            local_asr_groups.add(sample.get("language_group", "unknown"))
            covered = _coverage_category(sample.get("category"), required_categories)
            if covered is not None:
                covered_categories.add(covered)
        else:
            missing_local_asr_samples.append(sample_id)
            if sample_status.get("status") == "pass":
                sample_status["status"] = "missing_local_asr_artifacts"

    missing_local_asr_samples = sorted(set(missing_local_asr_samples + status.get("missing_samples", [])))
    missing_required_categories = sorted(c for c in required_categories if c not in covered_categories)
    status["selection_ready"] = bool(selection.get("ready"))
    status["requested_count"] = selection.get("requested_count")
    status["selected_count"] = len(selected_sample_ids)
    status["selected_sample_ids"] = selected_sample_ids
    status["requires_local_asr"] = True
    status["local_asr_language_groups"] = sorted(local_asr_groups)
    status["missing_local_asr_samples"] = missing_local_asr_samples
    status["required_categories"] = required_categories
    status["covered_categories"] = sorted(covered_categories)
    status["missing_required_categories"] = missing_required_categories
    status["passes_local_asr_suite_gate"] = (
        status["selection_ready"]
        and status["passes_strict_timing_gate"]
        and status["passes_sample_completion_gate"]
        and not missing_local_asr_samples
        and not missing_required_categories
        and len(local_asr_groups) >= len(status.get("required_language_groups", []))
    )
    return status


def _completion_requirement(
    requirement: str,
    passed: bool,
    evidence: Dict[str, Any],
    blocking: bool = True,
    note: Optional[str] = None,
) -> Dict[str, Any]:
    result = {
        "requirement": requirement,
        "status": "pass" if passed else ("fail" if blocking else "warning"),
        "passed": passed,
        "blocking": blocking,
        "evidence": evidence,
    }
    if note:
        result["note"] = note
    return result


def _qa_summary_covers_groups(
    summary: Optional[Dict[str, Any]],
    required_groups: Sequence[str],
    min_pass_per_group: int = 2,
    require_human_provenance: bool = False,
    require_text_risk_notes: bool = False,
) -> bool:
    if not summary or not summary.get("passes_qa_gate"):
        return False
    if require_human_provenance:
        input_type = summary.get("verdict_input_type")
        source_checked = bool(summary.get("requires_human_source"))
        if input_type != "markdown" and not source_checked:
            return False
    if require_text_risk_notes and not bool(summary.get("requires_text_risk_notes")):
        return False
    groups = summary.get("language_groups") or {}
    for language_group in required_groups:
        group = groups.get(language_group)
        if not group:
            return False
        if int(group.get("pass_count") or 0) < min_pass_per_group:
            return False
        if int(group.get("fail_count") or 0) != 0:
            return False
        if int(group.get("unchecked_count") or 0) != 0:
            return False
        if require_text_risk_notes and int(group.get("text_risk_pass_without_notes_count") or 0) != 0:
            return False
    return True


def build_completion_audit(
    manifest: Dict[str, Any],
    selection: Dict[str, Any],
    artifacts_root: str,
    audit: Optional[Dict[str, Any]] = None,
    auto_qa: Optional[Dict[str, Any]] = None,
    human_qa: Optional[Dict[str, Any]] = None,
    expected_count: int = 10,
    min_accepted_ratio: float = 0.90,
    min_pass_per_group: int = 2,
    require_text_risk_notes: bool = False,
) -> Dict[str, Any]:
    validate_manifest(manifest)
    if expected_count <= 0:
        raise ValueError("expected_count must be positive")

    status = collect_manual_suite_status(manifest, selection, artifacts_root)
    selected = list(selection.get("selected", []))
    samples_by_id = {sample["id"]: sample for sample in manifest.get("samples", [])}
    selected_languages = [
        str(item.get("suite_language") or item.get("language_group") or "")
        for item in selected
    ]
    distinct_languages = sorted(set(selected_languages))
    required_groups = sorted(status.get("required_language_groups", distinct_languages))
    selected_sample_ids = [str(item.get("id") or "") for item in selected]

    selected_count_ok = (
        bool(selection.get("ready"))
        and int(selection.get("selected_count") or len(selected)) >= expected_count
        and len(selected) >= expected_count
    )
    distinct_language_ok = (
        bool(selection.get("distinct_language_groups_required"))
        and len(distinct_languages) >= expected_count
        and len(distinct_languages) == len(selected_languages)
    )
    manual_caption_failures = [
        sample_id
        for sample_id in selected_sample_ids
        if sample_id not in samples_by_id or not _is_manual_caption_sample(samples_by_id[sample_id])
    ]
    manual_caption_ok = bool(selection.get("requires_human_captions")) and not manual_caption_failures

    sample_rows: List[Dict[str, Any]] = []
    ratio_failures: List[Dict[str, Any]] = []
    for sample_id in selected_sample_ids:
        sample_status = status.get("samples", {}).get(sample_id, {})
        accepted_ratio = sample_status.get("accepted_ratio")
        ratio_ok = accepted_ratio is not None and float(accepted_ratio) >= min_accepted_ratio
        if not ratio_ok:
            ratio_failures.append({
                "sample_id": sample_id,
                "accepted_ratio": accepted_ratio,
            })
        sample_rows.append({
            "sample_id": sample_id,
            "language_group": sample_status.get("language_group"),
            "gate_mode": sample_status.get("gate_mode"),
            "status": sample_status.get("status"),
            "accepted_ratio": accepted_ratio,
            "comparison": sample_status.get("comparison"),
            "passes_min_accepted_ratio": ratio_ok,
        })

    strict_status_ok = bool(status.get("passes_manual_suite_gate")) and not ratio_failures
    audit_ok = bool(audit and audit.get("passes_all_seed_gates"))
    auto_qa_ok = _qa_summary_covers_groups(auto_qa, required_groups, min_pass_per_group=min_pass_per_group)
    human_qa_ok = _qa_summary_covers_groups(
        human_qa,
        required_groups,
        min_pass_per_group=min_pass_per_group,
        require_human_provenance=True,
        require_text_risk_notes=require_text_risk_notes,
    )
    qa_packet = build_qa_packet(
        manifest,
        artifacts_root,
        max_segments_per_group=min_pass_per_group,
        selection=selection,
        segment_mode="representative",
    )
    text_quality_risks: List[Dict[str, Any]] = []
    for group in qa_packet.get("language_groups", []):
        language_group = str(group.get("language_group") or "unknown")
        for index, segment in enumerate(group.get("segments", []), start=1):
            flags = list(segment.get("text_quality_flags") or [])
            if not flags:
                continue
            text_quality_risks.append({
                "review_id": "%s:%s:%d" % (language_group, segment.get("sample_id", "sample"), index),
                "language_group": language_group,
                "sample_id": segment.get("sample_id"),
                "text_quality_flags": flags,
                "baseline_text": segment.get("baseline_text", ""),
                "optimized_text": segment.get("optimized_text", ""),
                "url": segment.get("url", ""),
            })

    requirements = [
        _completion_requirement(
            "random_manual_caption_suite_selected",
            selected_count_ok,
            {
                "expected_count": expected_count,
                "requested_count": selection.get("requested_count"),
                "selected_count": selection.get("selected_count", len(selected)),
                "ready": selection.get("ready"),
                "seed": selection.get("seed"),
            },
        ),
        _completion_requirement(
            "distinct_source_language_groups",
            distinct_language_ok,
            {
                "expected_count": expected_count,
                "selected_language_groups": selected_languages,
                "distinct_language_groups": distinct_languages,
            },
        ),
        _completion_requirement(
            "selected_tracks_are_non_auto_human_caption_sources",
            manual_caption_ok,
            {
                "requires_human_captions": selection.get("requires_human_captions"),
                "manual_caption_failure_sample_ids": manual_caption_failures,
            },
        ),
        _completion_requirement(
            "strict_timing_gate_reaches_90_percent_per_selected_sample",
            strict_status_ok,
            {
                "min_accepted_ratio": min_accepted_ratio,
                "passes_manual_suite_gate": status.get("passes_manual_suite_gate"),
                "passes_strict_timing_gate": status.get("passes_strict_timing_gate"),
                "passes_sample_completion_gate": status.get("passes_sample_completion_gate"),
                "missing_samples": status.get("missing_samples"),
                "blocked_samples": status.get("blocked_samples"),
                "failing_samples": status.get("failing_samples"),
                "insufficient_window_samples": status.get("insufficient_window_samples"),
                "ratio_failures": ratio_failures,
            },
        ),
        _completion_requirement(
            "multi_seed_anti_overfit_audit",
            audit_ok,
            {
                "provided": audit is not None,
                "passes_all_seed_gates": audit.get("passes_all_seed_gates") if audit else None,
                "passing_seed_count": audit.get("passing_seed_count") if audit else None,
                "seed_count": audit.get("seed_count") if audit else None,
                "thin_language_groups": audit.get("thin_language_groups") if audit else None,
                "effective_random_language_groups": audit.get("effective_random_language_groups") if audit else None,
            },
        ),
        _completion_requirement(
            "auto_reference_representative_qa_gate",
            auto_qa_ok,
            {
                "provided": auto_qa is not None,
                "passes_qa_gate": auto_qa.get("passes_qa_gate") if auto_qa else None,
                "min_pass_per_group": min_pass_per_group,
                "required_language_groups": required_groups,
                "failing_language_groups": auto_qa.get("failing_language_groups") if auto_qa else None,
            },
        ),
        _completion_requirement(
            "human_side_by_side_qa_gate",
            human_qa_ok,
            {
                "provided": human_qa is not None,
                "passes_qa_gate": human_qa.get("passes_qa_gate") if human_qa else None,
                "min_pass_per_group": min_pass_per_group,
                "requires_text_risk_notes": require_text_risk_notes,
                "summary_requires_text_risk_notes": human_qa.get("requires_text_risk_notes") if human_qa else None,
                "required_language_groups": required_groups,
                "failing_language_groups": human_qa.get("failing_language_groups") if human_qa else None,
                "text_risk_pass_without_notes": {
                    language_group: (human_qa.get("language_groups") or {}).get(language_group, {}).get("text_risk_pass_without_notes_count", 0)
                    for language_group in required_groups
                } if human_qa else None,
            },
        ),
    ]

    machine_requirement_names = {
        "random_manual_caption_suite_selected",
        "distinct_source_language_groups",
        "selected_tracks_are_non_auto_human_caption_sources",
        "strict_timing_gate_reaches_90_percent_per_selected_sample",
        "multi_seed_anti_overfit_audit",
        "auto_reference_representative_qa_gate",
    }
    machine_ready = all(
        item["passed"]
        for item in requirements
        if item["requirement"] in machine_requirement_names
    )
    goal_complete = machine_ready and human_qa_ok
    remaining_work: List[str] = []
    if not machine_ready:
        remaining_work.append("Complete the failing machine evidence gates before claiming the 90% target.")
    if not human_qa_ok:
        human_note = "Finish human side-by-side QA: at least %d PASS rows per selected language, 0 FAIL, 0 unchecked." % min_pass_per_group
        if require_text_risk_notes:
            human_note += " Text-risk PASS rows must include reviewer notes."
        remaining_work.append(human_note)

    return {
        "objective": "10 random non-auto human-caption videos in distinct source languages; compare timing evidence against human/manual references; reach >=90% without single-video overfitting.",
        "machine_ready": machine_ready,
        "human_verified": human_qa_ok,
        "goal_complete": goal_complete,
        "expected_count": expected_count,
        "min_accepted_ratio": min_accepted_ratio,
        "min_pass_per_group": min_pass_per_group,
        "requires_text_risk_notes": require_text_risk_notes,
        "required_language_groups": required_groups,
        "selected_sample_ids": selected_sample_ids,
        "sample_results": sample_rows,
        "text_quality_risk_count": len(text_quality_risks),
        "text_quality_risks": text_quality_risks,
        "requirements": requirements,
        "remaining_work": remaining_work,
        "status": status,
    }


def sample_workdir(root: str, sample_id: str) -> Path:
    directory = Path(root) / sample_id
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def run_command(args: List[str], dry_run: bool = False) -> None:
    print("+ " + " ".join(args))
    if dry_run:
        return
    subprocess.run(args, check=True)


def sample_section(sample: Dict[str, Any], duration_override_seconds: Optional[float] = None) -> tuple[float, float, float]:
    section = sample.get("section", {})
    start = float(section.get("start_seconds", 0))
    duration = float(duration_override_seconds or section.get("duration_seconds", 240))
    return start, start + duration, duration


def build_prepare_commands(
    sample: Dict[str, Any],
    output_template: str,
    duration_override_seconds: Optional[float] = None,
    cookies: Optional[str] = None,
) -> List[List[str]]:
    source = sample["source"]
    start, end, _ = sample_section(sample, duration_override_seconds)
    subtitle_lang = sample.get("subtitle_lang", "en")
    media_format = sample.get("media_format", "ba[ext=m4a]/ba/best")

    cookie_args = ["--cookies", cookies] if cookies else []
    common = [
        "yt-dlp",
        "--no-playlist",
        "--force-overwrites",
        *cookie_args,
        "--download-sections",
        "*%s-%s" % (start, end),
        "-o",
        output_template,
    ]
    subtitle_common = common + [
        "--sleep-requests",
        "0.75",
        "--sleep-subtitles",
        "2",
        "--retry-sleep",
        "http:exp=1:8",
    ]
    media_command = common + [
        "-f",
        media_format,
        source,
    ]
    converted_subtitle_command = subtitle_common + [
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        subtitle_lang,
        "--convert-subs",
        "srt",
        "--skip-download",
        source,
    ]
    subtitle_command = subtitle_common + [
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        subtitle_lang,
        "--skip-download",
        source,
    ]
    return [media_command, converted_subtitle_command, subtitle_command]


def _python_module_command() -> List[str]:
    return ["python3", "-m", "subtitle_timing_eval.cli"]


def sample_asr_language(sample: Dict[str, Any]) -> str:
    if sample.get("asr_language"):
        return str(sample["asr_language"])
    spoken_languages = sample.get("spoken_languages") or []
    if spoken_languages:
        language = str(spoken_languages[0])
        if language == "yue":
            return "zh"
        return language
    return str(sample.get("subtitle_lang", "en")).split("-")[0]


def build_sample_runbook(
    sample: Dict[str, Any],
    artifacts_root: str,
    model: str = "small",
    duration_override_seconds: Optional[float] = None,
    asr_engine: str = "faster-whisper",
    whisper_cli: str = "whisper-cli",
    model_path: Optional[str] = None,
    ffmpeg: str = "ffmpeg",
    whisper_cpp_no_gpu: bool = False,
) -> Dict[str, Any]:
    start, end, _ = sample_section(sample, duration_override_seconds)
    sample_id = sample["id"]
    workdir = "%s/%s" % (artifacts_root.rstrip("/"), sample_id)
    words_path = "%s/asr_words.json" % workdir
    local_asr_source_srt = "%s/local-asr.%s.srt" % (workdir, sample_asr_language(sample))
    baseline_report = "%s/baseline.report.json" % workdir
    optimized_report = "%s/optimized.report.json" % workdir
    comparison_path = "%s/comparison.json" % workdir
    alignment_mode = sample.get("alignment_mode", "text")
    base_command = _python_module_command()

    metrics_common = [
        "--asr-words",
        words_path,
        "--asr-offset-seconds",
        str(start),
        "--window-start-seconds",
        str(start),
        "--window-end-seconds",
        str(end),
        "--alignment-mode",
        alignment_mode,
    ]

    prepare = base_command + [
        "prepare",
        "--sample-id",
        sample_id,
        "--artifacts",
        artifacts_root,
    ]
    if duration_override_seconds is not None:
        prepare += ["--duration-seconds", str(duration_override_seconds)]

    asr_command = base_command + [
        "asr",
        "--audio",
        "%s/<downloaded-audio-or-section-wav>" % workdir,
        "--out",
        words_path,
        "--model",
        model,
        "--language",
        sample_asr_language(sample),
    ]
    if asr_engine == "whisper-cpp":
        asr_command += [
            "--engine",
            "whisper-cpp",
            "--whisper-cli",
            whisper_cli,
            "--model-path",
            model_path or "<ggml-model-path>",
            "--ffmpeg",
            ffmpeg,
        ]
        if whisper_cpp_no_gpu:
            asr_command.append("--no-gpu")

    return {
        "sample_id": sample_id,
        "language_group": sample.get("language_group", "unknown"),
        "alignment_mode": alignment_mode,
        "workdir": workdir,
        "artifacts": {
            "asr_words": words_path,
            "local_asr_source_srt": local_asr_source_srt,
            "baseline_report": baseline_report,
            "optimized_report": optimized_report,
            "comparison": comparison_path,
        },
        "commands": {
            "prepare": prepare,
            "asr": asr_command,
            "local_asr_srt": [
                "swift",
                "run",
                "moongate-cli",
                "local-asr-srt",
                "--asr-words",
                words_path,
                "--language",
                sample_asr_language(sample),
                "--out",
                local_asr_source_srt,
            ],
            "clean_srt": [
                "swift",
                "run",
                "moongate-cli",
                "clean-srt",
                "%s/<downloaded-source-subtitle.srt>" % workdir,
            ],
            "baseline_metrics": base_command + [
                "metrics",
                "--sample-id",
                sample_id,
                "--candidate",
                "%s/<downloaded-source-subtitle.srt-or-vtt>" % workdir,
                "--out",
                baseline_report,
            ] + metrics_common,
            "optimized_metrics": base_command + [
                "metrics",
                "--sample-id",
                sample_id,
                "--candidate",
                local_asr_source_srt,
                "--out",
                optimized_report,
                "--candidate-offset-seconds",
                str(start),
            ] + metrics_common,
            "compare": base_command + [
                "compare",
                "--baseline-report",
                baseline_report,
                "--optimized-report",
                optimized_report,
                "--language-group",
                sample.get("language_group", "unknown"),
                "--out",
                comparison_path,
            ],
        },
    }


def build_suite_runbook(
    manifest: Dict[str, Any],
    artifacts_root: str,
    model: str = "small",
    duration_override_seconds: Optional[float] = None,
    manifest_path: str = "tools/subtitle_timing_eval/samples.json",
    selection: Optional[Dict[str, Any]] = None,
    selection_path: Optional[str] = None,
    only_incomplete: bool = False,
    asr_engine: str = "faster-whisper",
    whisper_cli: str = "whisper-cli",
    model_path: Optional[str] = None,
    ffmpeg: str = "ffmpeg",
    whisper_cpp_no_gpu: bool = False,
) -> Dict[str, Any]:
    if selection is not None:
        scoped_manifest = _manual_suite_filtered_manifest(manifest, selection)
        runbook_scope = "manual_suite"
        status_for_scope = collect_eval_status(scoped_manifest, artifacts_root)
    else:
        validate_manifest(manifest)
        scoped_manifest = manifest
        runbook_scope = "manifest"
        status_for_scope = None

    filtered_out_sample_ids: List[str] = []
    if only_incomplete:
        statuses = status_for_scope or collect_eval_status(scoped_manifest, artifacts_root)
        incomplete_ids = {
            sample_id
            for sample_id, sample_status in statuses["samples"].items()
            if sample_status.get("status") != "pass"
            or (selection is not None and sample_status.get("gate_mode") != "timing")
        }
        original_samples = list(scoped_manifest["samples"])
        scoped_manifest = {
            "coverage_goal": scoped_manifest["coverage_goal"],
            "samples": [
                sample for sample in original_samples if sample["id"] in incomplete_ids
            ],
        }
        filtered_out_sample_ids = sorted(
            sample["id"] for sample in original_samples if sample["id"] not in incomplete_ids
        )
        runbook_scope = "%s_incomplete" % runbook_scope

    samples = [
        build_sample_runbook(
            sample,
            artifacts_root=artifacts_root,
            model=model,
            duration_override_seconds=duration_override_seconds,
            asr_engine=asr_engine,
            whisper_cli=whisper_cli,
            model_path=model_path,
            ffmpeg=ffmpeg,
            whisper_cpp_no_gpu=whisper_cpp_no_gpu,
        )
        for sample in scoped_manifest["samples"]
    ]
    comparison_paths = [sample["artifacts"]["comparison"] for sample in samples]
    suite_command = _python_module_command() + ["suite"]
    for path in comparison_paths:
        suite_command += ["--comparison", path]
    suite_command += [
        "--require-manifest-coverage",
        "--out",
        "%s/suite.summary.json" % artifacts_root.rstrip("/"),
    ]
    if selection is not None and selection_path:
        status_completion_command = _python_module_command() + [
            "manual-suite-status",
            "--manifest",
            manifest_path,
            "--selection",
            selection_path,
            "--artifacts",
            artifacts_root,
            "--out",
            "%s/manual-suite-status.current.json" % artifacts_root.rstrip("/"),
            "--require-ready",
        ]
    else:
        status_completion_command = _python_module_command() + [
            "status",
            "--manifest",
            manifest_path,
            "--artifacts",
            artifacts_root,
            "--out",
            "%s/status.current.json" % artifacts_root.rstrip("/"),
            "--require-sample-completion",
        ]

    return {
        "runbook_scope": runbook_scope,
        "required_language_groups": scoped_manifest["coverage_goal"]["required_language_groups"],
        "sample_count": len(samples),
        "filtered_out_sample_ids": filtered_out_sample_ids,
        "samples": samples,
        "suite_command": suite_command,
        "status_completion_command": status_completion_command,
    }


def _load_all_comparison_files(artifacts_root: str) -> Dict[str, List[Dict[str, Any]]]:
    comparisons: Dict[str, List[Dict[str, Any]]] = {}
    root = Path(artifacts_root)
    if not root.exists():
        return comparisons
    for path in sorted(root.rglob("comparison*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        sample_id = payload.get("sample_id")
        if not sample_id or "optimized" not in payload:
            continue
        payload["_path"] = str(path)
        payload["_mtime"] = path.stat().st_mtime
        comparisons.setdefault(str(sample_id), []).append(payload)
    return comparisons


def _load_comparison_files(artifacts_root: str) -> Dict[str, Dict[str, Any]]:
    comparisons: Dict[str, Dict[str, Any]] = {}
    for sample_id, candidates in _load_all_comparison_files(artifacts_root).items():
        latest = max(candidates, key=lambda item: float(item.get("_mtime") or 0.0))
        comparisons[sample_id] = latest
    return comparisons


def _load_blocker_files(artifacts_root: str) -> Dict[str, Dict[str, Any]]:
    blockers: Dict[str, Dict[str, Any]] = {}
    root = Path(artifacts_root)
    if not root.exists():
        return blockers
    for path in sorted(root.rglob("blocker*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        sample_id = payload.get("sample_id")
        reason = payload.get("reason")
        if not sample_id or not reason:
            continue
        previous = blockers.get(sample_id)
        if previous is None or path.stat().st_mtime > Path(previous["_path"]).stat().st_mtime:
            payload["_path"] = str(path)
            blockers[sample_id] = payload
    return blockers


def _float_or_none(value: Any) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _report_window_seconds(report: Optional[Dict[str, Any]]) -> Optional[float]:
    if not report:
        return None
    window_start = _float_or_none(report.get("window_start_seconds"))
    window_end = _float_or_none(report.get("window_end_seconds"))
    if window_start is not None and window_end is not None and window_end > window_start:
        return window_end - window_start

    starts: List[float] = []
    ends: List[float] = []
    for cue in report.get("cues", []):
        start = _float_or_none(cue.get("start"))
        end = _float_or_none(cue.get("end"))
        if start is None or end is None or end < start:
            continue
        starts.append(start)
        ends.append(end)
    if not starts:
        return None
    return max(ends) - min(starts)


def _comparison_window_seconds(comparison_path: str) -> Optional[float]:
    baseline_report, optimized_report = _load_reports_for_comparison(comparison_path)
    durations = [
        duration
        for duration in (
            _report_window_seconds(baseline_report),
            _report_window_seconds(optimized_report),
        )
        if duration is not None
    ]
    if not durations:
        return None
    return max(durations)


def _has_sufficient_window_coverage(comparison_seconds: Optional[float], manifest_seconds: float) -> bool:
    if comparison_seconds is None:
        return True
    minimum_seconds = max(0.0, manifest_seconds * WINDOW_COVERAGE_MIN_RATIO - WINDOW_COVERAGE_TOLERANCE_SECONDS)
    return comparison_seconds >= minimum_seconds


def _comparison_window_for_sample(comparison: Dict[str, Any], sample: Dict[str, Any]) -> Optional[float]:
    comparison_path = comparison.get("_path")
    if not comparison_path:
        return None
    return _comparison_window_seconds(comparison_path)


def _choose_comparison_for_sample(
    candidates: Sequence[Dict[str, Any]],
    sample: Dict[str, Any],
) -> Optional[Dict[str, Any]]:
    if not candidates:
        return None
    _, _, manifest_window_seconds = sample_section(sample)

    def rank(comparison: Dict[str, Any]) -> tuple[int, float, float]:
        gate_mode = comparison.get("gate_mode", "timing")
        comparison_window_seconds = _comparison_window_for_sample(comparison, sample)
        sufficient = _has_sufficient_window_coverage(comparison_window_seconds, manifest_window_seconds)
        if sufficient and gate_mode == "timing":
            bucket = 3
        elif sufficient:
            bucket = 2
        elif gate_mode == "timing":
            bucket = 1
        else:
            bucket = 0
        return (
            bucket,
            comparison_window_seconds if comparison_window_seconds is not None else -1.0,
            float(comparison.get("_mtime") or 0.0),
        )

    return max(candidates, key=rank)


def collect_eval_status(
    manifest: Dict[str, Any],
    artifacts_root: str,
    comparison_filter: Optional[Callable[[Dict[str, Any], Dict[str, Any]], bool]] = None,
) -> Dict[str, Any]:
    validate_manifest(manifest)
    comparison_candidates = _load_all_comparison_files(artifacts_root)
    blockers = _load_blocker_files(artifacts_root)
    required_groups = list(manifest["coverage_goal"]["required_language_groups"])
    samples: Dict[str, Dict[str, Any]] = {}
    covered_groups = set()
    failing_groups = set()
    timing_groups = set()
    preservation_groups = set()
    failing_timing_groups = set()

    for sample in manifest["samples"]:
        sample_id = sample["id"]
        language_group = sample.get("language_group", "unknown")
        candidates = comparison_candidates.get(sample_id, [])
        if comparison_filter is not None:
            candidates = [comparison for comparison in candidates if comparison_filter(comparison, sample)]
        comparison = _choose_comparison_for_sample(candidates, sample)
        if comparison is None:
            blocker = blockers.get(sample_id)
            if blocker is not None:
                samples[sample_id] = {
                    "status": "blocked",
                    "language_group": language_group,
                    "blocker": blocker.get("_path"),
                    "blocker_stage": blocker.get("stage"),
                    "blocker_reason": blocker.get("reason"),
                    "blocker_message": blocker.get("message"),
                }
                continue
            samples[sample_id] = {
                "status": "missing",
                "language_group": language_group,
            }
            continue

        optimized = comparison.get("optimized", {})
        passes = bool(optimized.get("passes_timing_gate"))
        gate_mode = comparison.get("gate_mode", "timing")
        accepted_ratio = optimized.get("summary", {}).get("accepted_ratio")
        _, _, manifest_window_seconds = sample_section(sample)
        comparison_path = comparison.get("_path")
        comparison_window_seconds = _comparison_window_for_sample(comparison, sample)
        if not _has_sufficient_window_coverage(comparison_window_seconds, manifest_window_seconds):
            samples[sample_id] = {
                "status": "insufficient_window",
                "language_group": language_group,
                "comparison": comparison_path,
                "gate_mode": gate_mode,
                "accepted_ratio": accepted_ratio,
                "comparison_window_seconds": comparison_window_seconds,
                "manifest_window_seconds": manifest_window_seconds,
                "gate_failures": optimized.get("gate_failures", []),
            }
            continue
        covered_groups.add(language_group)
        if not passes:
            failing_groups.add(language_group)
            if gate_mode == "timing":
                failing_timing_groups.add(language_group)
        elif gate_mode == "timing":
            timing_groups.add(language_group)
        elif gate_mode == "preserve":
            preservation_groups.add(language_group)
        samples[sample_id] = {
            "status": "pass" if passes else "fail",
            "language_group": language_group,
            "comparison": comparison.get("_path"),
            "gate_mode": gate_mode,
            "accepted_ratio": accepted_ratio,
            "gate_failures": optimized.get("gate_failures", []),
        }

    missing_groups = sorted(set(required_groups) - covered_groups)
    missing_strict_timing_groups = sorted(set(required_groups) - timing_groups)
    failing_groups_list = sorted(failing_groups)
    failing_timing_groups_list = sorted(failing_timing_groups)
    missing_samples = sorted(
        sample_id for sample_id, item in samples.items() if item["status"] == "missing"
    )
    failing_samples = sorted(
        sample_id for sample_id, item in samples.items() if item["status"] == "fail"
    )
    blocked_samples = sorted(
        sample_id for sample_id, item in samples.items() if item["status"] == "blocked"
    )
    insufficient_window_samples = sorted(
        sample_id for sample_id, item in samples.items() if item["status"] == "insufficient_window"
    )

    passes_language_coverage_gate = not missing_groups and not failing_groups_list
    passes_strict_timing_gate = (
        not missing_strict_timing_groups
        and not failing_timing_groups_list
    )
    passes_sample_completion_gate = (
        not missing_samples
        and not failing_samples
        and not blocked_samples
        and not insufficient_window_samples
    )

    return {
        "required_language_groups": required_groups,
        "covered_language_groups": sorted(covered_groups),
        "timing_language_groups": sorted(timing_groups),
        "preservation_language_groups": sorted(preservation_groups),
        "missing_language_groups": missing_groups,
        "missing_strict_timing_language_groups": missing_strict_timing_groups,
        "failing_language_groups": failing_groups_list,
        "failing_strict_timing_language_groups": failing_timing_groups_list,
        "passes_language_coverage_gate": passes_language_coverage_gate,
        "passes_strict_timing_gate": passes_strict_timing_gate,
        "passes_sample_completion_gate": passes_sample_completion_gate,
        "passes_timing_gate": passes_strict_timing_gate,
        "sample_count": len(manifest["samples"]),
        "comparison_count": len(comparison_candidates),
        "blocker_count": len(blocked_samples),
        "missing_samples": missing_samples,
        "blocked_samples": blocked_samples,
        "failing_samples": failing_samples,
        "insufficient_window_samples": insufficient_window_samples,
        "samples": samples,
    }


def _ensure_iteration_issue(
    issues: Dict[str, Dict[str, Any]],
    issue: str,
    language_group: str,
    sample_id: str,
    occurrences: int = 1,
    severity: float = 0.0,
) -> None:
    definition = ITERATION_ISSUES.get(issue, {"priority": 10, "label": issue, "suggested_action": ""})
    item = issues.setdefault(issue, {
        "issue": issue,
        "priority": int(definition.get("priority", 10)),
        "label": definition["label"],
        "suggested_action": definition["suggested_action"],
        "sample_count": 0,
        "occurrence_count": 0,
        "max_severity": 0.0,
        "language_groups": [],
        "samples": [],
    })
    if sample_id not in item["samples"]:
        item["sample_count"] += 1
        item["samples"].append(sample_id)
    item["occurrence_count"] += max(1, int(occurrences))
    item["max_severity"] = max(float(item["max_severity"]), float(severity))
    if language_group not in item["language_groups"]:
        item["language_groups"].append(language_group)


def _iteration_issue_sort_key(issue: Dict[str, Any]) -> tuple:
    return (
        int(issue.get("priority", 10)),
        -int(issue.get("sample_count", 0)),
        -int(issue.get("occurrence_count", 0)),
        -float(issue.get("max_severity", 0.0)),
        str(issue.get("issue", "")),
    )


def _sorted_iteration_issues(issues: Dict[str, Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    ordered: Dict[str, Dict[str, Any]] = {}
    for issue in sorted(issues.values(), key=_iteration_issue_sort_key):
        issue["language_groups"] = sorted(issue["language_groups"])
        issue["samples"] = sorted(issue["samples"])
        ordered[issue["issue"]] = issue
    return ordered


def _issue_examples_from_rows(
    rows: Sequence[Dict[str, Any]],
    issue: str,
    sample_id: str,
    language_group: str,
    max_examples: int,
) -> List[Dict[str, Any]]:
    examples: List[Dict[str, Any]] = []
    for row in rows:
        start_error = _float_or_none(row.get("start_error_ms"))
        end_error = _float_or_none(row.get("end_error_ms"))
        row_matches = False
        score = 0.0
        if issue == "accepted_ratio":
            row_matches = row.get("accepted") is False
            score = max(abs(start_error or 0.0), abs(end_error or 0.0))
        elif issue == "start_onset_drift" and start_error is not None:
            row_matches = start_error < ACCEPTED_START_MIN_MS or start_error > ACCEPTED_START_MAX_MS
            score = max(0.0, start_error - ACCEPTED_START_MAX_MS, ACCEPTED_START_MIN_MS - start_error)
        elif issue == "end_offset_drift" and end_error is not None:
            row_matches = end_error < ACCEPTED_END_MIN_MS or end_error > ACCEPTED_END_MAX_MS
            score = max(0.0, end_error - ACCEPTED_END_MAX_MS, ACCEPTED_END_MIN_MS - end_error)
        elif issue == "early_cutoff":
            score = float(row.get("early_cutoff_ms") or 0.0)
            row_matches = score > 0
        elif issue == "long_idle_hold":
            score = float(row.get("long_idle_hold_ms") or 0.0)
            row_matches = score > 0
        elif issue == "weak_boundary":
            row_matches = bool(row.get("weak_boundary"))
            score = max(abs(start_error or 0.0), abs(end_error or 0.0), 1.0)
        elif issue == "cjk_singleton":
            row_matches = bool(row.get("cjk_singleton"))
            score = max(float(row.get("duration") or 0.0) * 1000.0, 1.0)
        elif issue == "reading_speed":
            speed = float(row.get("reading_speed_chars_per_second") or 0.0)
            row_matches = speed > READING_SPEED_P90_GATE
            score = speed
        if not row_matches:
            continue
        examples.append({
            "sample_id": sample_id,
            "language_group": language_group,
            "index": row.get("index"),
            "start": row.get("start"),
            "end": row.get("end"),
            "text": row.get("text", ""),
            "start_error_ms": row.get("start_error_ms"),
            "end_error_ms": row.get("end_error_ms"),
            "early_cutoff_ms": row.get("early_cutoff_ms"),
            "long_idle_hold_ms": row.get("long_idle_hold_ms"),
            "weak_boundary": bool(row.get("weak_boundary")),
            "cjk_singleton": bool(row.get("cjk_singleton")),
            "reading_speed_chars_per_second": row.get("reading_speed_chars_per_second"),
            "score": score,
        })
    examples.sort(key=lambda item: float(item.get("score") or 0.0), reverse=True)
    return examples[:max_examples]


def _sample_iteration_issues(summary: Dict[str, Any], gate_failures: Sequence[str]) -> List[tuple[str, int, float]]:
    issues: List[tuple[str, int, float]] = []
    accepted_ratio = float(summary.get("accepted_ratio") or 0.0)
    if accepted_ratio < 0.90 or "accepted_ratio" in gate_failures:
        issues.append(("accepted_ratio", 1, max(0.0, 0.90 - accepted_ratio)))
    p90_start = float(summary.get("p90_abs_start_error_ms") or 0.0)
    if p90_start > ACCEPTED_START_MAX_MS:
        issues.append(("start_onset_drift", 1, p90_start - ACCEPTED_START_MAX_MS))
    p90_end = float(summary.get("p90_abs_end_error_ms") or 0.0)
    if p90_end > ACCEPTED_END_MAX_MS:
        issues.append(("end_offset_drift", 1, p90_end - ACCEPTED_END_MAX_MS))
    early_cutoff = int(summary.get("early_cutoff_count") or 0)
    if early_cutoff > 0 or "early_cutoff" in gate_failures:
        issues.append(("early_cutoff", max(1, early_cutoff), float(early_cutoff)))
    long_idle = int(summary.get("long_idle_hold_count") or 0)
    if long_idle > 0 or "long_idle_hold" in gate_failures:
        issues.append(("long_idle_hold", max(1, long_idle), float(long_idle)))
    weak_boundary_count = int(summary.get("weak_boundary_count") or 0)
    if weak_boundary_count > 0:
        issues.append(("weak_boundary", weak_boundary_count, float(weak_boundary_count)))
    cjk_singleton_count = int(summary.get("cjk_singleton_count") or 0)
    if cjk_singleton_count > 0 or "cjk_singleton" in gate_failures:
        issues.append(("cjk_singleton", max(1, cjk_singleton_count), float(cjk_singleton_count)))
    p90_speed = float(summary.get("p90_reading_speed_chars_per_second") or 0.0)
    if p90_speed > READING_SPEED_P90_GATE:
        issues.append(("reading_speed", 1, p90_speed - READING_SPEED_P90_GATE))
    return issues


def build_iteration_report(
    manifest: Dict[str, Any],
    artifacts_root: str,
    max_examples_per_issue: int = 3,
    selection: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Summarize the current eval run into a repeatable next-iteration backlog."""
    validate_manifest(manifest)
    scoped_manifest = manifest
    if selection is not None:
        scoped_manifest = _manual_suite_filtered_manifest(manifest, selection)
        status = collect_manual_suite_status(manifest, selection, artifacts_root)
    else:
        status = collect_eval_status(manifest, artifacts_root)
    comparisons = _load_comparison_files(artifacts_root)
    global_issues: Dict[str, Dict[str, Any]] = {}
    groups: Dict[str, Dict[str, Any]] = {}
    examples_by_issue: Dict[str, List[Dict[str, Any]]] = {}

    for sample in scoped_manifest["samples"]:
        sample_id = sample["id"]
        language_group = sample.get("language_group", "unknown")
        group = groups.setdefault(language_group, {
            "sample_count": 0,
            "passing_sample_count": 0,
            "failing_sample_count": 0,
            "issues": {},
            "samples": [],
        })
        group["sample_count"] += 1
        sample_status = status["samples"].get(sample_id, {"status": "missing"})
        comparison = comparisons.get(sample_id)
        sample_record: Dict[str, Any] = {
            "sample_id": sample_id,
            "status": sample_status.get("status"),
            "gate_mode": sample_status.get("gate_mode"),
            "accepted_ratio": sample_status.get("accepted_ratio"),
            "issues": [],
        }

        if sample_status.get("status") in {"missing", "blocked", "insufficient_window"}:
            issue = {
                "missing": "missing_artifact",
                "blocked": "blocked_artifact",
                "insufficient_window": "insufficient_window",
            }[sample_status["status"]]
            _ensure_iteration_issue(global_issues, issue, language_group, sample_id)
            _ensure_iteration_issue(group["issues"], issue, language_group, sample_id)
            sample_record["issues"].append(issue)
            group["failing_sample_count"] += 1
            group["samples"].append(sample_record)
            continue

        if sample_status.get("status") == "pass":
            group["passing_sample_count"] += 1
        else:
            group["failing_sample_count"] += 1

        optimized = (comparison or {}).get("optimized", {})
        summary = optimized.get("summary", {})
        gate_failures = optimized.get("gate_failures", [])
        gate_mode = (comparison or {}).get("gate_mode") or sample_status.get("gate_mode")
        if gate_mode == "preserve" and optimized.get("passes_timing_gate") and not gate_failures:
            sample_issues = []
        else:
            sample_issues = _sample_iteration_issues(summary, gate_failures)
        sample_record["issues"] = [issue for issue, _, _ in sample_issues]
        sample_record["accepted_ratio"] = summary.get("accepted_ratio", sample_record["accepted_ratio"])
        for issue, occurrences, severity in sample_issues:
            _ensure_iteration_issue(global_issues, issue, language_group, sample_id, occurrences, severity)
            _ensure_iteration_issue(group["issues"], issue, language_group, sample_id, occurrences, severity)

        comparison_path = (comparison or {}).get("_path")
        if comparison_path:
            _, optimized_report = _load_reports_for_comparison(comparison_path)
            rows = list((optimized_report or {}).get("cues", []))
            for issue, _, _ in sample_issues:
                current = examples_by_issue.setdefault(issue, [])
                current.extend(_issue_examples_from_rows(
                    rows,
                    issue,
                    sample_id,
                    language_group,
                    max_examples_per_issue,
                ))
                current.sort(key=lambda item: float(item.get("score") or 0.0), reverse=True)
                del current[max_examples_per_issue:]

        group["samples"].append(sample_record)

    for group in groups.values():
        group["issues"] = _sorted_iteration_issues(group["issues"])
        group["samples"].sort(key=lambda item: item["sample_id"])

    top_priorities = list(_sorted_iteration_issues(global_issues).values())
    ready_for_release = (
        status["passes_language_coverage_gate"]
        and status["passes_sample_completion_gate"]
        and not top_priorities
    )
    if selection is not None:
        ready_for_release = status["passes_manual_suite_gate"] and not top_priorities
    return {
        "ready_for_release": ready_for_release,
        "status": status,
        "report_scope": "manual_suite" if selection is not None else "manifest",
        "top_priorities": top_priorities,
        "language_groups": dict(sorted(groups.items())),
        "examples_by_issue": dict(sorted(examples_by_issue.items())),
        "iteration_rule": (
            "Do not tune for a single video. Address the highest-ranked issue across language groups, "
            "add/keep a fixture for that failure mode, rerun metrics/status/qa, then repeat until the "
            "mainstream manifest and human QA gates pass."
        ),
    }


def _report_paths_for_comparison(comparison_path: Path) -> tuple[Path, Path]:
    name = comparison_path.name
    prefix = "comparison"
    suffix = ".json"
    if not name.startswith(prefix) or not name.endswith(suffix):
        raise ValueError("not a comparison path: %s" % comparison_path)
    token = name[len(prefix):-len(suffix)]
    return (
        comparison_path.with_name("baseline%s.report.json" % token),
        comparison_path.with_name("optimized%s.report.json" % token),
    )


def _sample_timestamp_url(source: str, start_seconds: float) -> str:
    if "youtube.com/watch" not in source:
        return source
    separator = "&" if "?" in source else "?"
    return "%s%st=%ds" % (source, separator, int(max(0, start_seconds)))


def _qa_segment_score(row: Dict[str, Any]) -> float:
    return max(
        1000.0 if not row.get("accepted", False) else 0.0,
        abs(float(row.get("start_error_ms") or 0.0)),
        abs(float(row.get("end_error_ms") or 0.0)),
        abs(float(row.get("early_cutoff_ms") or 0.0)),
        abs(float(row.get("late_hold_ms") or 0.0)),
        abs(float(row.get("long_idle_hold_ms") or 0.0)),
        800.0 if row.get("weak_boundary") else 0.0,
    )


def _qa_representative_segment_score(row: Dict[str, Any]) -> float:
    risk = _qa_segment_score(row)
    if not row.get("accepted", False):
        risk += 10000.0
    duration = _float_or_none(row.get("duration"))
    duration_penalty = 0.0 if duration is None else abs(duration - 3.2) * 25.0
    start = _float_or_none(row.get("start")) or 0.0
    return risk + duration_penalty + (start % 1.0)


def _load_reports_for_comparison(comparison_path: str) -> tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    try:
        baseline_path, optimized_path = _report_paths_for_comparison(Path(comparison_path))
    except ValueError:
        return None, None
    baseline = None
    optimized = None
    if baseline_path.exists():
        try:
            baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            baseline = None
    if not optimized_path.exists():
        return baseline, None
    try:
        optimized = json.loads(optimized_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        optimized = None
    return baseline, optimized


def _cue_overlap_score(left: Dict[str, Any], right: Dict[str, Any]) -> float:
    left_start = float(left.get("start") or 0.0)
    left_end = float(left.get("end") or left_start)
    right_start = float(right.get("start") or 0.0)
    right_end = float(right.get("end") or right_start)
    return max(0.0, min(left_end, right_end) - max(left_start, right_start))


def _matching_baseline_row(row: Dict[str, Any], baseline_rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    if not baseline_rows:
        return {}
    best = max(baseline_rows, key=lambda candidate: _cue_overlap_score(row, candidate))
    if _cue_overlap_score(row, best) > 0:
        return best
    for candidate in baseline_rows:
        if candidate.get("index") == row.get("index"):
            return candidate
    return {}


def _text_script_family(text: str) -> str:
    has_cjk = any(
        "\u3400" <= character <= "\u4dbf"
        or "\u4e00" <= character <= "\u9fff"
        or "\u3040" <= character <= "\u30ff"
        or "\uac00" <= character <= "\ud7af"
        for character in text
    )
    has_latin = any(
        "A" <= character <= "Z"
        or "a" <= character <= "z"
        or "\u00c0" <= character <= "\u024f"
        for character in text
    )
    if has_cjk and has_latin:
        return "mixed"
    if has_cjk:
        return "cjk"
    if has_latin:
        return "latin"
    return "other"


def _text_quality_flags(baseline_text: str, optimized_text: str) -> List[str]:
    baseline = baseline_text.strip()
    optimized = optimized_text.strip()
    if not optimized:
        return ["empty_optimized_text"] if baseline else []
    if not baseline:
        return []

    baseline_family = _text_script_family(baseline)
    optimized_family = _text_script_family(optimized)
    if baseline_family != optimized_family or baseline_family == "other":
        return []

    flags: List[str] = []
    baseline_tokens = set(cue_tokens(baseline))
    optimized_tokens = set(cue_tokens(optimized))
    if len(baseline_tokens) >= 4 and len(optimized_tokens) >= 4:
        overlap_ratio = len(baseline_tokens & optimized_tokens) / max(len(baseline_tokens | optimized_tokens), 1)
        if overlap_ratio < 0.35:
            flags.append("low_text_overlap")

    if len(baseline) >= 16 and len(optimized) > max(len(baseline) * 1.8, len(baseline) + 24):
        flags.append("expanded_vs_reference")
    return flags


def build_qa_packet(
    manifest: Dict[str, Any],
    artifacts_root: str,
    max_segments_per_group: int = 8,
    selection: Optional[Dict[str, Any]] = None,
    segment_mode: str = "risk",
) -> Dict[str, Any]:
    if segment_mode not in {"risk", "representative"}:
        raise ValueError("segment_mode must be 'risk' or 'representative'")
    validate_manifest(manifest)
    if selection is not None:
        scoped_manifest = _manual_suite_filtered_manifest(manifest, selection)
        status = collect_manual_suite_status(manifest, selection, artifacts_root)
    else:
        scoped_manifest = manifest
        status = collect_eval_status(manifest, artifacts_root)
    samples_by_id = {sample["id"]: sample for sample in scoped_manifest["samples"]}
    groups: Dict[str, Dict[str, Any]] = {}

    for sample_id, sample_status in status["samples"].items():
        sample = samples_by_id.get(sample_id, {})
        language_group = sample_status.get("language_group", "unknown")
        group = groups.setdefault(language_group, {
            "language_group": language_group,
            "sample_count": 0,
            "samples": [],
            "segments": [],
        })
        if sample_status.get("status") != "pass":
            continue
        group["sample_count"] += 1
        summary = {
            "sample_id": sample_id,
            "title": sample.get("title", sample_id),
            "category": sample.get("category"),
            "gate_mode": sample_status.get("gate_mode"),
            "accepted_ratio": sample_status.get("accepted_ratio"),
            "comparison": sample_status.get("comparison"),
            "source": sample.get("source"),
            "section": sample.get("section", {}),
        }
        group["samples"].append(summary)

        baseline_report, optimized_report = _load_reports_for_comparison(sample_status.get("comparison", ""))
        if optimized_report is None:
            continue
        baseline_rows = list((baseline_report or {}).get("cues", []))
        rows = list(optimized_report.get("cues", []))
        if segment_mode == "representative":
            rows.sort(key=_qa_representative_segment_score)
        else:
            rows.sort(key=_qa_segment_score, reverse=True)
        for row in rows[:max_segments_per_group]:
            start = float(row.get("start") or sample.get("section", {}).get("start_seconds", 0))
            baseline_row = _matching_baseline_row(row, baseline_rows)
            baseline_text = str(baseline_row.get("text", ""))
            optimized_text = str(row.get("text", ""))
            group["segments"].append({
                "sample_id": sample_id,
                "title": sample.get("title", sample_id),
                "gate_mode": sample_status.get("gate_mode"),
                "comparison": sample_status.get("comparison"),
                "url": _sample_timestamp_url(str(sample.get("source", "")), start),
                "start": start,
                "end": row.get("end"),
                "baseline_start": baseline_row.get("start"),
                "baseline_end": baseline_row.get("end"),
                "optimized_start": row.get("start"),
                "optimized_end": row.get("end"),
                "text": optimized_text,
                "baseline_text": baseline_text,
                "optimized_text": optimized_text,
                "text_quality_flags": _text_quality_flags(baseline_text, optimized_text),
                "accepted": bool(row.get("accepted")),
                "start_error_ms": row.get("start_error_ms"),
                "end_error_ms": row.get("end_error_ms"),
                "early_cutoff_ms": row.get("early_cutoff_ms"),
                "late_hold_ms": row.get("late_hold_ms"),
                "long_idle_hold_ms": row.get("long_idle_hold_ms"),
                "weak_boundary": bool(row.get("weak_boundary")),
                "score": _qa_segment_score(row),
            })

    for group in groups.values():
        group["samples"].sort(key=lambda item: item["sample_id"])
        if segment_mode == "representative":
            group["segments"].sort(key=lambda item: (
                0 if item.get("accepted") else 1,
                abs(float(item.get("start_error_ms") or 0.0)),
                abs(float(item.get("end_error_ms") or 0.0)),
                float(item.get("start") or 0.0),
            ))
        else:
            group["segments"].sort(key=lambda item: item["score"], reverse=True)
        group["segments"] = group["segments"][:max_segments_per_group]

    return {
        "status": {
            "passes_timing_gate": status["passes_timing_gate"],
            "passes_manual_suite_gate": status.get("passes_manual_suite_gate"),
            "passes_sample_completion_gate": status["passes_sample_completion_gate"],
            "sample_count": status["sample_count"],
            "comparison_count": status["comparison_count"],
            "timing_language_groups": status["timing_language_groups"],
            "preservation_language_groups": status["preservation_language_groups"],
            "missing_samples": status["missing_samples"],
            "blocked_samples": status["blocked_samples"],
            "failing_samples": status["failing_samples"],
            "report_scope": "manual_suite" if selection is not None else "manifest",
            "selected_sample_ids": status.get("selected_sample_ids", []),
            "segment_mode": segment_mode,
        },
        "language_groups": sorted(groups.values(), key=lambda item: item["language_group"]),
    }


def _markdown_table_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("\n", " ").replace("|", "\\|")


def render_qa_markdown(packet: Dict[str, Any]) -> str:
    status = packet["status"]
    lines = [
        "# Subtitle Timing QA Packet",
        "",
        "- timing gate: `%s`" % status["passes_timing_gate"],
        "- sample completion gate: `%s`" % status["passes_sample_completion_gate"],
        "- samples: `%s`, comparisons: `%s`" % (status["sample_count"], status["comparison_count"]),
        "- timing language groups: `%s`" % ", ".join(status["timing_language_groups"]),
        "",
    ]
    for group in packet["language_groups"]:
        lines += [
            "## %s" % group["language_group"],
            "",
            "| Sample | Gate | Accepted | Source |",
            "| --- | --- | ---: | --- |",
        ]
        for sample in group["samples"]:
            section_start = sample.get("section", {}).get("start_seconds", 0)
            source = _sample_timestamp_url(str(sample.get("source") or ""), float(section_start))
            lines.append(
                "| %s | %s | %s | %s |"
                % (
                    _markdown_table_cell(sample["title"]),
                    _markdown_table_cell(sample["gate_mode"]),
                    _markdown_table_cell(sample["accepted_ratio"]),
                    _markdown_table_cell(source),
                )
            )
        lines += [
            "",
            "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |",
            "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |",
        ]
        for segment in group["segments"]:
            lines.append(
                "| %s | %s | %s | %s | %s | %s | %s | %s |  |  |"
                % (
                    _markdown_table_cell(segment["url"]),
                    _markdown_table_cell(segment["sample_id"]),
                    _markdown_table_cell(segment["accepted"]),
                    _markdown_table_cell(segment["start_error_ms"]),
                    _markdown_table_cell(segment["end_error_ms"]),
                    _markdown_table_cell(segment["late_hold_ms"]),
                    _markdown_table_cell(segment["baseline_text"]),
                    _markdown_table_cell(segment["optimized_text"]),
                )
            )
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def build_auto_reference_qa_records(
    packet: Dict[str, Any],
    verdict: str = "PASS",
    require_accepted: bool = True,
) -> Dict[str, Any]:
    records: List[Dict[str, Any]] = []
    skipped: List[Dict[str, Any]] = []
    normalized_verdict = verdict.strip().upper() or "PASS"
    for group in packet.get("language_groups", []):
        language_group = str(group.get("language_group") or "unknown")
        for index, segment in enumerate(group.get("segments", []), start=1):
            accepted = bool(segment.get("accepted"))
            if require_accepted and not accepted:
                skipped.append({
                    "language_group": language_group,
                    "sample_id": segment.get("sample_id"),
                    "reason": "segment_not_accepted",
                    "start_error_ms": segment.get("start_error_ms"),
                    "end_error_ms": segment.get("end_error_ms"),
                })
                continue
            records.append({
                "language_group": language_group,
                "sample_id": segment.get("sample_id"),
                "review_id": "%s:%s:%d" % (language_group, segment.get("sample_id", "sample"), index),
                "human_verdict": normalized_verdict,
                "verdict_source": "auto_reference",
                "notes": "Prefilled from strict timing/reference metrics; still suitable for human confirmation.",
                "accepted": accepted,
                "start_error_ms": segment.get("start_error_ms"),
                "end_error_ms": segment.get("end_error_ms"),
                "late_hold_ms": segment.get("late_hold_ms"),
                "long_idle_hold_ms": segment.get("long_idle_hold_ms"),
                "weak_boundary": bool(segment.get("weak_boundary")),
                "url": segment.get("url"),
            })
    return {
        "verdict_source": "auto_reference",
        "record_count": len(records),
        "skipped_count": len(skipped),
        "records": records,
        "skipped": skipped,
        "status": packet.get("status", {}),
    }


def _qa_records_from_payload(payload: Optional[Any]) -> List[Dict[str, Any]]:
    if isinstance(payload, dict):
        raw_records = payload.get("reviews") or payload.get("records") or []
        records = raw_records if isinstance(raw_records, list) else []
    elif isinstance(payload, list):
        records = payload
    else:
        records = []
    return [record for record in records if isinstance(record, dict)]


def _qa_prefill_indexes(prefill_reviews: Optional[Dict[str, Any]]) -> tuple[Dict[str, Dict[str, Any]], Dict[tuple[str, str], Dict[str, Any]]]:
    records = _qa_records_from_payload(prefill_reviews)
    by_id = {
        str(record.get("review_id")): record
        for record in records
        if record.get("review_id")
    }
    by_sample = {
        (str(record.get("language_group") or ""), str(record.get("sample_id") or "")): record
        for record in records
        if record.get("language_group") and record.get("sample_id")
    }
    return by_id, by_sample


def _qa_prefill_for_segment(
    language_group: str,
    segment: Dict[str, Any],
    review_id: str,
    prefill_by_id: Dict[str, Dict[str, Any]],
    prefill_by_sample: Dict[tuple[str, str], Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    return prefill_by_id.get(review_id) or prefill_by_sample.get((language_group, str(segment.get("sample_id") or "")))


def _qa_human_review_indexes(human_reviews: Optional[Any]) -> tuple[Dict[str, Dict[str, Any]], Dict[tuple[str, str, str], Dict[str, Any]]]:
    records = _qa_records_from_payload(human_reviews)
    by_id = {
        str(record.get("review_id")): record
        for record in records
        if record.get("review_id")
    }
    by_time = {
        (
            str(record.get("language_group") or ""),
            str(record.get("sample_id") or ""),
            str(record.get("review_time") or ""),
        ): record
        for record in records
        if record.get("language_group") and record.get("sample_id") and record.get("review_time")
    }
    return by_id, by_time


def _qa_human_review_for_segment(
    language_group: str,
    segment: Dict[str, Any],
    review_id: str,
    human_by_id: Dict[str, Dict[str, Any]],
    human_by_time: Dict[tuple[str, str, str], Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    return human_by_id.get(review_id) or human_by_time.get((
        language_group,
        str(segment.get("sample_id") or ""),
        str(segment.get("url") or ""),
    ))


def _qa_record_is_human_review(record: Optional[Dict[str, Any]]) -> bool:
    if not record:
        return False
    verdict = str(record.get("human_verdict") or record.get("verdict") or "").strip().upper()
    source = str(record.get("verdict_source") or record.get("source") or "").strip()
    return verdict in {"PASS", "FAIL"} and source in HUMAN_VERDICT_SOURCES


def render_qa_checklist_markdown(
    packet: Dict[str, Any],
    prefill_reviews: Optional[Dict[str, Any]] = None,
) -> str:
    status = packet["status"]
    prefill_by_id, prefill_by_sample = _qa_prefill_indexes(prefill_reviews)
    lines = [
        "# Subtitle Timing QA Checklist",
        "",
        "- timing gate: `%s`" % status["passes_timing_gate"],
        "- sample completion gate: `%s`" % status["passes_sample_completion_gate"],
        "- samples: `%s`, comparisons: `%s`" % (status["sample_count"], status["comparison_count"]),
        "- segment mode: `%s`" % status.get("segment_mode", ""),
        "",
        "Fill `Human Verdict` with `PASS` or `FAIL` after checking the linked time window. `Suggested` is machine evidence, not a human verdict.",
        "",
    ]
    for group in packet["language_groups"]:
        language_group = str(group["language_group"])
        lines += [
            "## %s" % language_group,
            "",
            "| Review ID | Review Time | Cue | Suggested | Text Risk | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |",
            "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |",
        ]
        for index, segment in enumerate(group["segments"], start=1):
            review_id = "%s:%s:%d" % (language_group, segment.get("sample_id", "sample"), index)
            prefill = _qa_prefill_for_segment(language_group, segment, review_id, prefill_by_id, prefill_by_sample)
            suggested = ""
            if prefill:
                source = prefill.get("verdict_source") or prefill.get("source") or "auto_reference"
                verdict = prefill.get("human_verdict") or prefill.get("verdict") or ""
                suggested = "%s:%s" % (source, verdict)
            lines.append(
                "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |  |  |"
                % (
                    _markdown_table_cell(review_id),
                    _markdown_table_cell(segment["url"]),
                    _markdown_table_cell(segment["sample_id"]),
                    _markdown_table_cell(suggested),
                    _markdown_table_cell(", ".join(segment.get("text_quality_flags") or [])),
                    _markdown_table_cell(segment["accepted"]),
                    _markdown_table_cell(segment["start_error_ms"]),
                    _markdown_table_cell(segment["end_error_ms"]),
                    _markdown_table_cell(segment["late_hold_ms"]),
                    _markdown_table_cell(segment["baseline_text"]),
                    _markdown_table_cell(segment["optimized_text"]),
                )
            )
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_qa_remaining_queue_markdown(
    packet: Dict[str, Any],
    prefill_reviews: Optional[Dict[str, Any]] = None,
    human_reviews: Optional[Dict[str, Any]] = None,
) -> str:
    prefill_by_id, prefill_by_sample = _qa_prefill_indexes(prefill_reviews)
    human_by_id, human_by_time = _qa_human_review_indexes(human_reviews)
    remaining_by_group: Dict[str, List[Dict[str, Any]]] = {}
    text_risk_review_ids: List[str] = []
    reviewed_count = 0
    total_count = 0

    for group in packet["language_groups"]:
        language_group = str(group["language_group"])
        for index, segment in enumerate(group["segments"], start=1):
            total_count += 1
            review_id = "%s:%s:%d" % (language_group, segment.get("sample_id", "sample"), index)
            human_record = _qa_human_review_for_segment(language_group, segment, review_id, human_by_id, human_by_time)
            if _qa_record_is_human_review(human_record):
                reviewed_count += 1
                continue
            prefill = _qa_prefill_for_segment(language_group, segment, review_id, prefill_by_id, prefill_by_sample)
            suggested = ""
            if prefill:
                source = prefill.get("verdict_source") or prefill.get("source") or "auto_reference"
                verdict = prefill.get("human_verdict") or prefill.get("verdict") or ""
                suggested = "%s:%s" % (source, verdict)
            row = dict(segment)
            row.update({
                "review_id": review_id,
                "suggested": suggested,
            })
            if row.get("text_quality_flags"):
                text_risk_review_ids.append(review_id)
            remaining_by_group.setdefault(language_group, []).append(row)

    remaining_count = total_count - reviewed_count
    lines = [
        "# Subtitle Timing QA Remaining Queue",
        "",
        "- total rows: `%d`" % total_count,
        "- human-reviewed rows: `%d`" % reviewed_count,
        "- remaining rows: `%d`" % remaining_count,
        "- text-risk rows: `%d`" % len(text_risk_review_ids),
    ]
    if text_risk_review_ids:
        lines.append("- text-risk review IDs: `%s`" % "`, `".join(text_risk_review_ids))
    lines += [
        "",
        "Only `human_review` / `manual_review` PASS or FAIL records count as reviewed. Machine suggestions below are review aids only.",
        "",
    ]
    for language_group in sorted(remaining_by_group):
        rows = remaining_by_group[language_group]
        lines += [
            "## %s" % language_group,
            "",
            "| Review ID | Review Time | Cue | Suggested | Text Risk | Start ms | End ms | Hold ms | Optimized | Human Verdict | Notes |",
            "| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- | --- | --- |",
        ]
        for row in rows:
            lines.append(
                "| %s | %s | %s | %s | %s | %s | %s | %s | %s |  |  |"
                % (
                    _markdown_table_cell(row.get("review_id", "")),
                    _markdown_table_cell(row["url"]),
                    _markdown_table_cell(row["sample_id"]),
                    _markdown_table_cell(row.get("suggested", "")),
                    _markdown_table_cell(", ".join(row.get("text_quality_flags") or [])),
                    _markdown_table_cell(row.get("start_error_ms")),
                    _markdown_table_cell(row.get("end_error_ms")),
                    _markdown_table_cell(row.get("late_hold_ms")),
                    _markdown_table_cell(row.get("optimized_text")),
                )
            )
        lines.append("")
    if not remaining_by_group:
        lines.append("All selected QA rows have human-source verdicts.\n")
    return "\n".join(lines).rstrip() + "\n"


def _url_path_for_html(path: Path, output_path: str) -> str:
    output_dir = Path(output_path).parent
    try:
        relative = os.path.relpath(path, output_dir)
    except ValueError:
        relative = str(path)
    normalized = relative.replace(os.sep, "/")
    return quote(normalized, safe="/:.-_#?=&,%")


def _media_candidates(sample_dir: Path) -> List[Path]:
    suffixes = {".wav", ".m4a", ".mp4", ".webm"}
    candidates = [path for path in sample_dir.iterdir() if path.is_file() and path.suffix.lower() in suffixes]

    def score(path: Path) -> tuple[int, str]:
        name = path.name.lower()
        if ".section." in name or name.endswith(".section.wav"):
            return (0, name)
        if ".full." in name:
            return (2, name)
        if path.suffix.lower() == ".wav":
            return (1, name)
        return (1, name)

    return sorted(candidates, key=score)


def _local_media_for_segment(
    sample: Dict[str, Any],
    artifacts_root: str,
    output_path: str,
    start: float,
    end: Optional[Any],
    comparison_path: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    search_dirs = [Path(artifacts_root) / str(sample.get("id", ""))]
    if comparison_path:
        search_dirs.append(Path(comparison_path).parent)
    candidates: List[Path] = []
    seen_dirs = set()
    for sample_dir in search_dirs:
        if sample_dir in seen_dirs or not sample_dir.exists():
            continue
        seen_dirs.add(sample_dir)
        candidates = _media_candidates(sample_dir)
        if candidates:
            break
    if not candidates:
        return None
    media_path = candidates[0]
    section = sample.get("section") or {}
    section_start = float(section.get("start_seconds", 0.0))
    name = media_path.name.lower()
    offset = 0.0 if ".full." in name else section_start
    local_start = max(0.0, float(start) - offset)
    local_end = None
    if end is not None:
        try:
            local_end = max(local_start, float(end) - offset)
        except (TypeError, ValueError):
            local_end = None
    url = _url_path_for_html(media_path, output_path)
    fragment = "%.3f" % local_start
    if local_end is not None:
        fragment += ",%.3f" % local_end
    return {
        "path": str(media_path),
        "url": url,
        "src": "%s#t=%s" % (url, fragment),
        "start": local_start,
        "end": local_end,
        "offset_seconds": offset,
    }


def _float_or_none(value: Any) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _qa_review_media_window(segment: Dict[str, Any]) -> tuple[float, Optional[float]]:
    starts = [
        value
        for value in [
            _float_or_none(segment.get("baseline_start")),
            _float_or_none(segment.get("optimized_start")),
            _float_or_none(segment.get("start")),
        ]
        if value is not None
    ]
    ends = [
        value
        for value in [
            _float_or_none(segment.get("baseline_end")),
            _float_or_none(segment.get("optimized_end")),
            _float_or_none(segment.get("end")),
        ]
        if value is not None
    ]
    if not starts:
        return 0.0, None
    start = max(0.0, min(starts) - 0.75)
    if not ends:
        return start, None
    return start, max(start, max(ends) + 0.75)


def _qa_review_data(
    packet: Dict[str, Any],
    manifest: Dict[str, Any],
    artifacts_root: str,
    output_path: str,
    prefill_reviews: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    samples_by_id = {sample["id"]: sample for sample in manifest.get("samples", [])}
    prefill_by_id, prefill_by_sample = _qa_prefill_indexes(prefill_reviews)
    groups = []
    for group in packet.get("language_groups", []):
        segments = []
        for index, segment in enumerate(group.get("segments", []), start=1):
            sample = samples_by_id.get(segment.get("sample_id"), {})
            start, end = _qa_review_media_window(segment)
            media = _local_media_for_segment(
                sample,
                artifacts_root,
                output_path,
                start,
                end,
                comparison_path=segment.get("comparison"),
            )
            review_id = "%s:%s:%d" % (group.get("language_group", "unknown"), segment.get("sample_id", "sample"), index)
            prefill = _qa_prefill_for_segment(
                str(group.get("language_group") or ""),
                segment,
                review_id,
                prefill_by_id,
                prefill_by_sample,
            )
            enriched = dict(segment)
            enriched.update({
                "review_id": review_id,
                "media": media,
            })
            if prefill:
                enriched.update({
                    "suggested_verdict": prefill.get("human_verdict") or prefill.get("verdict"),
                    "suggested_source": prefill.get("verdict_source") or prefill.get("source"),
                    "suggested_notes": prefill.get("notes"),
                })
            segments.append(enriched)
        next_group = dict(group)
        next_group["segments"] = segments
        groups.append(next_group)
    return {
        "status": packet.get("status", {}),
        "coverage_goal": manifest.get("coverage_goal", {}),
        "language_groups": groups,
    }


def _json_for_script(data: Dict[str, Any]) -> str:
    return json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")


def render_qa_review_html(
    packet: Dict[str, Any],
    manifest: Dict[str, Any],
    artifacts_root: str,
    output_path: str,
    prefill_reviews: Optional[Dict[str, Any]] = None,
) -> str:
    data = _qa_review_data(packet, manifest, artifacts_root, output_path, prefill_reviews=prefill_reviews)
    required_groups = ", ".join(data.get("coverage_goal", {}).get("required_language_groups", []))
    title = "Moongate Subtitle Timing QA"
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #f7f7f4;
      --fg: #171717;
      --muted: #666;
      --line: #d8d7d0;
      --panel: #ffffff;
      --accent: #0f766e;
      --bad: #b42318;
      --good: #137333;
    }}
    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #141414;
        --fg: #f4f1ea;
        --muted: #aaa;
        --line: #383838;
        --panel: #1e1e1e;
      }}
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--fg);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header {{
      position: sticky;
      top: 0;
      z-index: 5;
      border-bottom: 1px solid var(--line);
      background: color-mix(in srgb, var(--bg) 92%, transparent);
      backdrop-filter: blur(16px);
      padding: 14px 20px;
    }}
    h1 {{
      margin: 0 0 6px;
      font-size: 22px;
      font-weight: 700;
      letter-spacing: 0;
    }}
    .meta, .toolbar, .tabs {{
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }}
    .meta {{ color: var(--muted); }}
    .toolbar {{ margin-top: 12px; }}
    button, a.button {{
      border: 1px solid var(--line);
      background: var(--panel);
      color: var(--fg);
      border-radius: 6px;
      padding: 7px 10px;
      cursor: pointer;
      text-decoration: none;
      font: inherit;
    }}
    button[aria-pressed="true"] {{
      border-color: var(--accent);
      box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 25%, transparent);
    }}
    .pass[aria-pressed="true"] {{ color: var(--good); }}
    .fail[aria-pressed="true"] {{ color: var(--bad); }}
    main {{ padding: 18px 20px 48px; }}
    section.group {{ display: none; }}
    section.group.active {{ display: block; }}
    .grid {{
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      gap: 14px;
      max-width: 1180px;
    }}
    article {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 14px;
    }}
    .row {{
      display: grid;
      grid-template-columns: 170px minmax(0, 1fr);
      gap: 12px;
      align-items: start;
      margin-top: 10px;
    }}
    .label {{
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: .04em;
    }}
    .cue {{
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      border-left: 3px solid var(--line);
      padding-left: 10px;
    }}
    .metrics {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 8px;
      color: var(--muted);
    }}
    .metrics span {{
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 2px 8px;
    }}
    .suggestion {{
      margin-top: 8px;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border: 1px solid color-mix(in srgb, var(--accent) 40%, var(--line));
      border-radius: 6px;
      padding: 6px 8px;
      color: var(--muted);
    }}
    .suggestion strong {{
      color: var(--good);
      font-weight: 700;
    }}
    .caption-preview {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
      margin-top: 10px;
    }}
    .caption-lane {{
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px;
      min-height: 84px;
      opacity: .58;
      transition: opacity .12s ease, border-color .12s ease;
    }}
    .caption-lane.active {{
      border-color: var(--accent);
      opacity: 1;
      box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 18%, transparent);
    }}
    .caption-window {{
      margin-top: 4px;
      color: var(--muted);
      font-size: 12px;
    }}
    audio, video {{ width: 100%; margin-top: 8px; }}
    textarea {{
      width: 100%;
      min-height: 54px;
      resize: vertical;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: transparent;
      color: var(--fg);
      padding: 8px;
      font: inherit;
    }}
    @media (max-width: 700px) {{
      .row {{ grid-template-columns: 1fr; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>{title}</h1>
    <div class="meta">
      <span id="summary"></span>
      <span>Required groups: {required_groups}</span>
    </div>
    <div class="toolbar">
      <div class="tabs" id="tabs"></div>
      <button type="button" id="export-json">Export JSON</button>
      <button type="button" id="export-markdown">Export Markdown</button>
    </div>
  </header>
  <main id="app"></main>
  <script id="qa-data" type="application/json">{data_json}</script>
  <script>
    const data = JSON.parse(document.getElementById("qa-data").textContent);
    const stateKey = "moongate-subtitle-qa-review-v1";
    const state = JSON.parse(localStorage.getItem(stateKey) || "{{}}");
    const tabs = document.getElementById("tabs");
    const app = document.getElementById("app");

    function save() {{
      localStorage.setItem(stateKey, JSON.stringify(state));
      updateSummary();
    }}

    function entry(id) {{
      state[id] ||= {{ verdict: "", notes: "", verdict_source: "" }};
      return state[id];
    }}

    function esc(value) {{
      return String(value ?? "").replace(/[&<>"']/g, ch => ({{"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;"}}[ch]));
    }}

    function fmt(value) {{
      if (value === null || value === undefined || value === "") return "";
      const n = Number(value);
      return Number.isFinite(n) ? `${{Math.round(n)}}ms` : esc(value);
    }}

    function fmtSeconds(value) {{
      if (value === null || value === undefined || value === "") return "";
      const n = Number(value);
      return Number.isFinite(n) ? `${{n.toFixed(3)}}s` : esc(value);
    }}

    function mediaSrc(segment) {{
      if (!segment.media) return "";
      return segment.media.src || "";
    }}

    function inAbsoluteWindow(current, start, end) {{
      const s = Number(start);
      const e = Number(end);
      return Number.isFinite(s) && Number.isFinite(e) && current >= s && current <= e;
    }}

    function syncCaptionPreview(article, segment, currentAbsolute) {{
      const baseline = article.querySelector('[data-window="baseline"]');
      const optimized = article.querySelector('[data-window="optimized"]');
      if (baseline) baseline.classList.toggle("active", inAbsoluteWindow(currentAbsolute, segment.baseline_start, segment.baseline_end));
      if (optimized) optimized.classList.toggle("active", inAbsoluteWindow(currentAbsolute, segment.optimized_start, segment.optimized_end));
    }}

    function renderTabs(active) {{
      tabs.innerHTML = "";
      for (const group of data.language_groups) {{
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = group.language_group;
        button.setAttribute("aria-pressed", group.language_group === active ? "true" : "false");
        button.addEventListener("click", () => render(group.language_group));
        tabs.appendChild(button);
      }}
    }}

    function render(active) {{
      renderTabs(active);
      app.innerHTML = "";
      for (const group of data.language_groups) {{
        const section = document.createElement("section");
        section.className = `group${{group.language_group === active ? " active" : ""}}`;
        section.innerHTML = `<h2>${{esc(group.language_group)}}</h2><div class="grid"></div>`;
        const grid = section.querySelector(".grid");
        for (const segment of group.segments) {{
          const item = entry(segment.review_id);
          const source = mediaSrc(segment);
          const openLink = `<a class="button" target="_blank" rel="noreferrer" href="${{esc(segment.url)}}">Open YouTube</a>`;
          const media = source
            ? `<audio controls preload="metadata" src="${{esc(source)}}"></audio><div class="toolbar">${{openLink}}</div>`
            : openLink;
          const suggestion = segment.suggested_verdict
            ? `<div class="suggestion"><span>Suggested by ${{esc(segment.suggested_source || "auto-reference")}}: <strong>${{esc(segment.suggested_verdict)}}</strong></span><button type="button" data-suggested-verdict="${{esc(segment.suggested_verdict)}}">Use Suggestion</button></div>`
            : "";
          const article = document.createElement("article");
          article.dataset.reviewId = segment.review_id;
          article.dataset.sampleId = segment.sample_id;
          article.innerHTML = `
            <div class="label">${{esc(segment.sample_id)}} · ${{esc(segment.gate_mode)}} · ${{esc(segment.url)}}</div>
            ${{media}}
            <div class="metrics">
              <span>accepted ${{esc(segment.accepted)}}</span>
              <span>start ${{fmt(segment.start_error_ms)}}</span>
              <span>end ${{fmt(segment.end_error_ms)}}</span>
              <span>hold ${{fmt(segment.late_hold_ms)}}</span>
            </div>
            ${{suggestion}}
            <div class="caption-preview" data-role="caption-preview">
              <div class="caption-lane" data-window="baseline">
                <div class="label">Baseline Window</div>
                <div class="cue">${{esc(segment.baseline_text)}}</div>
                <div class="caption-window">${{fmtSeconds(segment.baseline_start)}} → ${{fmtSeconds(segment.baseline_end)}}</div>
              </div>
              <div class="caption-lane" data-window="optimized">
                <div class="label">Optimized Window</div>
                <div class="cue">${{esc(segment.optimized_text)}}</div>
                <div class="caption-window">${{fmtSeconds(segment.optimized_start)}} → ${{fmtSeconds(segment.optimized_end)}}</div>
              </div>
            </div>
            <div class="row"><div class="label">Baseline</div><div class="cue">${{esc(segment.baseline_text)}}</div></div>
            <div class="row"><div class="label">Optimized</div><div class="cue">${{esc(segment.optimized_text)}}</div></div>
            <div class="row">
              <div class="label">Human Verdict</div>
              <div>
                <button type="button" class="pass" data-verdict="PASS" aria-pressed="${{item.verdict === "PASS"}}">PASS</button>
                <button type="button" class="fail" data-verdict="FAIL" aria-pressed="${{item.verdict === "FAIL"}}">FAIL</button>
              </div>
            </div>
            <div class="row"><div class="label">Notes</div><textarea>${{esc(item.notes)}}</textarea></div>
          `;
          article.querySelectorAll("[data-verdict]").forEach(button => {{
            button.addEventListener("click", () => {{
              const item = entry(segment.review_id);
              const next = button.dataset.verdict;
              item.verdict = item.verdict === next ? "" : next;
              item.verdict_source = item.verdict ? "human_review" : "";
              save();
              render(active);
            }});
          }});
          article.querySelectorAll("[data-suggested-verdict]").forEach(button => {{
            button.addEventListener("click", () => {{
              const item = entry(segment.review_id);
              item.verdict = button.dataset.suggestedVerdict;
              item.verdict_source = "human_review";
              if (!item.notes && segment.suggested_notes) item.notes = segment.suggested_notes;
              save();
              render(active);
            }});
          }});
          article.querySelector("textarea").addEventListener("input", event => {{
            entry(segment.review_id).notes = event.target.value;
            save();
          }});
          const audio = article.querySelector("audio");
          if (audio && segment.media) {{
            const updatePreview = () => {{
              const currentAbsolute = audio.currentTime + Number(segment.media.offset_seconds || 0);
              syncCaptionPreview(article, segment, currentAbsolute);
            }};
            audio.addEventListener("timeupdate", updatePreview);
            audio.addEventListener("loadedmetadata", updatePreview);
            updatePreview();
          }}
          grid.appendChild(article);
        }}
        app.appendChild(section);
      }}
      updateSummary();
    }}

    function flattenedReviews() {{
      return data.language_groups.flatMap(group => group.segments.map(segment => ({{
        language_group: group.language_group,
        sample_id: segment.sample_id,
        review_time: segment.url,
        baseline_text: segment.baseline_text,
        optimized_text: segment.optimized_text,
        suggested_verdict: segment.suggested_verdict || "",
        suggested_source: segment.suggested_source || "",
        human_verdict: entry(segment.review_id).verdict,
        verdict_source: entry(segment.review_id).verdict ? (entry(segment.review_id).verdict_source || "human_review") : "",
        notes: entry(segment.review_id).notes,
      }})));
    }}

    function updateSummary() {{
      const reviews = flattenedReviews();
      const pass = reviews.filter(item => item.human_verdict === "PASS").length;
      const fail = reviews.filter(item => item.human_verdict === "FAIL").length;
      const unchecked = reviews.length - pass - fail;
      document.getElementById("summary").textContent = `${{pass}} PASS · ${{fail}} FAIL · ${{unchecked}} unchecked`;
    }}

    function download(name, text, type) {{
      const blob = new Blob([text], {{ type }});
      const link = document.createElement("a");
      link.href = URL.createObjectURL(blob);
      link.download = name;
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    }}

    document.getElementById("export-json").addEventListener("click", () => {{
      download("qa.verdicts.review.json", JSON.stringify({{ reviews: flattenedReviews() }}, null, 2), "application/json");
    }});
    document.getElementById("export-markdown").addEventListener("click", () => {{
      const lines = ["# Subtitle Timing QA Verdict Export", ""];
      for (const item of flattenedReviews()) {{
        lines.push(`- ${{item.language_group}} / ${{item.sample_id}} / ${{item.human_verdict || "UNCHECKED"}} / ${{item.review_time}}`);
        if (item.notes) lines.push(`  Notes: ${{item.notes}}`);
      }}
      download("qa.verdicts.review.md", lines.join("\\n") + "\\n", "text/markdown");
    }});

    render(data.language_groups[0]?.language_group || "");
  </script>
</body>
</html>
""".format(
        title=html.escape(title),
        required_groups=html.escape(required_groups),
        data_json=_json_for_script(data),
    )


def _split_markdown_cells(line: str) -> List[str]:
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    cells: List[str] = []
    current: List[str] = []
    escaped = False
    for character in text:
        if escaped:
            if character == "|":
                current.append("|")
            else:
                current.append("\\")
                current.append(character)
            escaped = False
            continue
        if character == "\\":
            escaped = True
            continue
        if character == "|":
            cells.append("".join(current).strip())
            current = []
            continue
        current.append(character)
    if escaped:
        current.append("\\")
    cells.append("".join(current).strip())
    return cells


def _is_markdown_separator(cells: Sequence[str]) -> bool:
    if not cells:
        return False
    for cell in cells:
        stripped = cell.strip()
        if not stripped or "-" not in stripped:
            return False
        if any(character not in "-:" for character in stripped):
            return False
    return True


def _empty_qa_group() -> Dict[str, Any]:
    return {
        "total_review_count": 0,
        "pass_count": 0,
        "fail_count": 0,
        "unchecked_count": 0,
        "text_risk_count": 0,
        "text_risk_pass_count": 0,
        "text_risk_fail_count": 0,
        "text_risk_unchecked_count": 0,
        "text_risk_pass_without_notes_count": 0,
        "text_risk_pass_without_notes": [],
        "non_human_source_count": 0,
        "non_human_sources": [],
        "unknown_verdicts": [],
        "passes_group_gate": False,
    }


def summarize_qa_verdict_records(
    records: Sequence[Dict[str, Any]],
    required_language_groups: Sequence[str],
    min_pass_per_group: int = 2,
    require_human_source: bool = False,
    require_text_risk_notes: bool = False,
) -> Dict[str, Any]:
    groups: Dict[str, Dict[str, Any]] = {}
    required = list(required_language_groups)
    human_sources = {"human", "human_review", "manual", "manual_review"}

    for record in records:
        language_group = str(record.get("language_group") or "unknown")
        group = groups.setdefault(language_group, _empty_qa_group())
        group["total_review_count"] += 1
        raw_verdict = str(record.get("human_verdict") or record.get("verdict") or "").strip()
        verdict = raw_verdict.upper()
        text_risk = str(record.get("text_risk") or record.get("text_quality_flags") or "").strip()
        if text_risk:
            group["text_risk_count"] += 1
            if verdict == "PASS":
                group["text_risk_pass_count"] += 1
                if not str(record.get("notes") or "").strip():
                    group["text_risk_pass_without_notes_count"] += 1
                    group["text_risk_pass_without_notes"].append({
                        "line": record.get("line"),
                        "review_id": record.get("review_id") or "",
                        "sample": record.get("sample_id") or record.get("sample") or "",
                        "text_risk": text_risk,
                    })
            elif verdict == "FAIL":
                group["text_risk_fail_count"] += 1
            else:
                group["text_risk_unchecked_count"] += 1
        if verdict == "PASS":
            group["pass_count"] += 1
        elif verdict == "FAIL":
            group["fail_count"] += 1
        else:
            group["unchecked_count"] += 1
            if raw_verdict:
                group["unknown_verdicts"].append({
                    "line": record.get("line"),
                    "sample": record.get("sample_id") or record.get("sample") or "",
                    "verdict": raw_verdict,
                })
        if require_human_source and verdict in {"PASS", "FAIL"}:
            source = str(record.get("verdict_source") or record.get("source") or "").strip()
            if source not in human_sources:
                group["non_human_source_count"] += 1
                group["non_human_sources"].append({
                    "line": record.get("line"),
                    "sample": record.get("sample_id") or record.get("sample") or "",
                    "verdict": raw_verdict,
                    "verdict_source": source,
                })

    for language_group in required:
        groups.setdefault(language_group, _empty_qa_group())

    failing_groups: List[str] = []
    for language_group in sorted(groups):
        group = groups[language_group]
        group["passes_group_gate"] = (
            group["pass_count"] >= min_pass_per_group
            and group["fail_count"] == 0
            and group["unchecked_count"] == 0
            and group["non_human_source_count"] == 0
            and (not require_text_risk_notes or group["text_risk_pass_without_notes_count"] == 0)
        )
        if language_group in required and not group["passes_group_gate"]:
            failing_groups.append(language_group)

    return {
        "passes_qa_gate": not failing_groups,
        "required_language_groups": required,
        "min_pass_per_group": min_pass_per_group,
        "requires_human_source": require_human_source,
        "requires_text_risk_notes": require_text_risk_notes,
        "failing_language_groups": failing_groups,
        "language_groups": groups,
    }


def extract_qa_verdict_records_from_markdown(markdown: str) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    current_group: Optional[str] = None
    review_header: Optional[Dict[str, int]] = None

    for line_number, raw_line in enumerate(markdown.splitlines(), start=1):
        line = raw_line.strip()
        if line.startswith("## "):
            current_group = line[3:].strip()
            review_header = None
            continue
        if not line.startswith("|"):
            continue
        cells = _split_markdown_cells(line)
        if "Human Verdict" in cells:
            review_header = {cell: index for index, cell in enumerate(cells)}
            continue
        if review_header is None or current_group is None or _is_markdown_separator(cells):
            continue

        verdict_index = review_header.get("Human Verdict")
        if verdict_index is None:
            continue
        sample_index = review_header.get("Cue")
        review_time_index = review_header.get("Review Time")
        review_id_index = review_header.get("Review ID")
        text_risk_index = review_header.get("Text Risk")
        notes_index = review_header.get("Notes")
        raw_verdict = cells[verdict_index].strip() if verdict_index < len(cells) else ""
        records.append({
            "review_id": cells[review_id_index] if review_id_index is not None and review_id_index < len(cells) else "",
            "language_group": current_group,
            "sample_id": cells[sample_index] if sample_index is not None and sample_index < len(cells) else "",
            "review_time": cells[review_time_index] if review_time_index is not None and review_time_index < len(cells) else "",
            "text_risk": cells[text_risk_index] if text_risk_index is not None and text_risk_index < len(cells) else "",
            "human_verdict": raw_verdict,
            "notes": cells[notes_index] if notes_index is not None and notes_index < len(cells) else "",
            "verdict_source": "human_review" if raw_verdict.upper() in {"PASS", "FAIL"} else "",
            "line": line_number,
        })
    return records


def summarize_qa_verdicts(
    markdown: str,
    required_language_groups: Sequence[str],
    min_pass_per_group: int = 2,
    require_text_risk_notes: bool = False,
) -> Dict[str, Any]:
    return summarize_qa_verdict_records(
        extract_qa_verdict_records_from_markdown(markdown),
        required_language_groups=required_language_groups,
        min_pass_per_group=min_pass_per_group,
        require_text_risk_notes=require_text_risk_notes,
    )


def _comparison_path_for_baseline(baseline_path: Path) -> Path:
    name = baseline_path.name
    prefix = "baseline"
    suffix = ".report.json"
    if not name.startswith(prefix) or not name.endswith(suffix):
        raise ValueError("not a baseline report path: %s" % baseline_path)
    token = name[len(prefix):-len(suffix)]
    return baseline_path.with_name("comparison%s.json" % token)


def _optimized_path_for_baseline(baseline_path: Path) -> Path:
    name = baseline_path.name
    prefix = "baseline"
    suffix = ".report.json"
    if not name.startswith(prefix) or not name.endswith(suffix):
        raise ValueError("not a baseline report path: %s" % baseline_path)
    token = name[len(prefix):-len(suffix)]
    return baseline_path.with_name("optimized%s.report.json" % token)


def materialize_existing_comparisons(manifest: Dict[str, Any], artifacts_root: str) -> Dict[str, Any]:
    validate_manifest(manifest)
    written: List[Dict[str, Any]] = []
    skipped: List[Dict[str, Any]] = []
    root = Path(artifacts_root)
    for sample in manifest["samples"]:
        sample_id = sample["id"]
        sample_dir = root / sample_id
        if not sample_dir.exists():
            skipped.append({"sample_id": sample_id, "reason": "missing_sample_directory"})
            continue
        baseline_paths = sorted(sample_dir.glob("baseline*.report.json"))
        if not baseline_paths:
            skipped.append({"sample_id": sample_id, "reason": "missing_baseline_report"})
            continue
        for baseline_path in baseline_paths:
            optimized_path = _optimized_path_for_baseline(baseline_path)
            if not optimized_path.exists():
                skipped.append({
                    "sample_id": sample_id,
                    "baseline_report": str(baseline_path),
                    "reason": "missing_optimized_report",
                })
                continue
            output_path = _comparison_path_for_baseline(baseline_path)
            gate_mode = "preserve" if _is_manual_caption_sample(sample) else "timing"
            comparison = compare_report_files(
                str(baseline_path),
                str(optimized_path),
                str(output_path),
                language_group=sample.get("language_group"),
                gate_mode=gate_mode,
            )
            written.append({
                "sample_id": sample_id,
                "language_group": comparison["language_group"],
                "comparison": str(output_path),
                "gate_mode": comparison["gate_mode"],
                "passes_timing_gate": comparison["optimized"]["passes_timing_gate"],
            })
    return {
        "written_count": len(written),
        "skipped_count": len(skipped),
        "written": written,
        "skipped": skipped,
    }


def build_converted_subtitle_command(
    sample: Dict[str, Any],
    output_template: str,
    duration_override_seconds: Optional[float] = None,
) -> List[str]:
    source = sample["source"]
    start, end, _ = sample_section(sample, duration_override_seconds)
    subtitle_lang = sample.get("subtitle_lang", "en")
    return [
        "yt-dlp",
        "--no-playlist",
        "--force-overwrites",
        "--download-sections",
        "*%s-%s" % (start, end),
        "--sleep-requests",
        "0.75",
        "--sleep-subtitles",
        "2",
        "--retry-sleep",
        "http:exp=1:8",
        "-o",
        output_template,
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        subtitle_lang,
        "--convert-subs",
        "srt",
        "--skip-download",
        source,
    ]


def build_full_media_fallback_command(sample: Dict[str, Any], workdir: Path, cookies: Optional[str] = None) -> List[str]:
    media_format = sample.get("media_format", "ba[ext=m4a]/ba/best")
    cookie_args = ["--cookies", cookies] if cookies else []
    return [
        "yt-dlp",
        "--no-playlist",
        "--force-overwrites",
        *cookie_args,
        "-f",
        media_format,
        "-o",
        str(workdir / ("%s.full.%%(ext)s" % sample["id"])),
        sample["source"],
    ]


def find_fallback_media_file(sample: Dict[str, Any], workdir: Path) -> Path:
    matches = sorted(workdir.glob("%s.full.*" % sample["id"]), key=lambda path: path.stat().st_mtime, reverse=True)
    if not matches:
        raise FileNotFoundError("fallback media download did not produce %s.full.*" % sample["id"])
    return matches[0]


def build_trim_fallback_command(input_path: Path, output_path: Path, start: float, duration: float) -> List[str]:
    return [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(input_path),
        "-ss",
        str(start),
        "-t",
        str(duration),
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        str(output_path),
    ]


def run_full_media_fallback(
    sample: Dict[str, Any],
    workdir: Path,
    dry_run: bool = False,
    duration_override_seconds: Optional[float] = None,
    cookies: Optional[str] = None,
) -> Path:
    start, _, duration = sample_section(sample, duration_override_seconds)
    run_command(build_full_media_fallback_command(sample, workdir, cookies=cookies), dry_run=dry_run)
    output_path = workdir / ("%s.section.wav" % sample["id"])
    if dry_run:
        run_command(build_trim_fallback_command(Path("<downloaded-full-media>"), output_path, start, duration), dry_run=True)
        return output_path
    input_path = find_fallback_media_file(sample, workdir)
    run_command(build_trim_fallback_command(input_path, output_path, start, duration), dry_run=dry_run)
    return output_path


def _command_error_message(error: subprocess.CalledProcessError) -> str:
    parts = []
    for value in (error.stderr, error.stdout):
        if isinstance(value, bytes):
            parts.append(value.decode("utf-8", errors="replace"))
        elif value:
            parts.append(str(value))
    if not parts:
        parts.append(str(error))
    return "\n".join(parts)


def _classify_prepare_failure(error: subprocess.CalledProcessError) -> str:
    message = _command_error_message(error).lower()
    if "not a bot" in message or "confirm you" in message or "cookies-from-browser" in message:
        return "youtube_bot_gate"
    if "429" in message or "too many requests" in message:
        return "youtube_rate_limited"
    return "external_download_failed"


def _write_prepare_blocker(sample: Dict[str, Any], workdir: Path, error: subprocess.CalledProcessError) -> None:
    payload = {
        "sample_id": sample["id"],
        "stage": "prepare",
        "reason": _classify_prepare_failure(error),
        "message": _command_error_message(error),
        "source": sample.get("source"),
    }
    path = workdir / "blocker.prepare.json"
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def prepare_sample(
    sample: Dict[str, Any],
    artifacts_root: str,
    dry_run: bool = False,
    duration_override_seconds: Optional[float] = None,
    cookies: Optional[str] = None,
) -> Path:
    workdir = sample_workdir(artifacts_root, sample["id"])
    output_template = str(workdir / "%(id)s.%(ext)s")
    media_command, converted_subtitle_command, subtitle_command = build_prepare_commands(
        sample,
        output_template,
        duration_override_seconds=duration_override_seconds,
        cookies=cookies,
    )
    try:
        run_command(media_command, dry_run=dry_run)
    except subprocess.CalledProcessError:
        print("section media download failed; falling back to full media download and local trim")
        try:
            run_full_media_fallback(
                sample,
                workdir,
                dry_run=dry_run,
                duration_override_seconds=duration_override_seconds,
                cookies=cookies,
            )
        except subprocess.CalledProcessError as error:
            _write_prepare_blocker(sample, workdir, error)
            raise
    try:
        run_command(converted_subtitle_command, dry_run=dry_run)
        run_command(subtitle_command, dry_run=dry_run)
    except subprocess.CalledProcessError as error:
        _write_prepare_blocker(sample, workdir, error)
        raise
    return workdir


def filter_cues_by_window(
    cues: Sequence[Cue],
    window_start: Optional[float],
    window_end: Optional[float],
) -> List[Cue]:
    if window_start is None and window_end is None:
        return list(cues)
    start = float("-inf") if window_start is None else window_start
    end = float("inf") if window_end is None else window_end
    return [cue for cue in cues if cue.start >= start and cue.end <= end]


def offset_cues(cues: Sequence[Cue], offset_seconds: float) -> List[Cue]:
    if offset_seconds == 0:
        return list(cues)
    return [
        Cue(
            index=cue.index,
            start=cue.start + offset_seconds,
            end=cue.end + offset_seconds,
            text=cue.text,
        )
        for cue in cues
    ]


def filter_words_by_window(
    words: Sequence[Dict[str, Any]],
    window_start: Optional[float],
    window_end: Optional[float],
) -> List[Dict[str, Any]]:
    if window_start is None and window_end is None:
        return list(words)
    start = float("-inf") if window_start is None else window_start
    end = float("inf") if window_end is None else window_end
    return [word for word in words if word["start"] >= start and word["end"] <= end]


def extract_vtt_words(raw_vtt: str) -> Dict[str, Any]:
    words = parse_vtt_word_timestamps(raw_vtt)
    return {"words": [asdict(word) for word in words]}


def extract_srt_words(raw_srt: str) -> Dict[str, Any]:
    words: List[Dict[str, Any]] = []
    for cue in parse_srt(raw_srt):
        tokens = cue.text.split()
        if not tokens:
            continue
        step = (cue.end - cue.start) / len(tokens)
        for index, token in enumerate(tokens):
            start = cue.start + step * index
            end = cue.start + step * (index + 1)
            words.append({"start": start, "end": end, "text": token})
    return {"words": words}


def extract_vtt_words_file(vtt_path: str, output_path: str) -> Dict[str, Any]:
    raw = Path(vtt_path).read_text(encoding="utf-8")
    payload = extract_vtt_words(raw)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def extract_srt_words_file(srt_path: str, output_path: str) -> Dict[str, Any]:
    raw = Path(srt_path).read_text(encoding="utf-8")
    payload = extract_srt_words(raw)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def build_translation_timing_proxy_srt(raw_srt: str, target_language: str = "zh-CN") -> str:
    cues = parse_srt(raw_srt)
    lower_language = target_language.lower()
    proxy_cues = []
    for position, cue in enumerate(cues, start=1):
        if lower_language.startswith(("zh", "yue")):
            text = "翻译字幕 CUE %04d。" % position
        else:
            text = "Translated subtitle CUE %04d." % position
        proxy_cues.append(Cue(index=cue.index, start=cue.start, end=cue.end, text=text))
    return serialize_srt(proxy_cues)


def write_translation_timing_proxy_file(source_srt_path: str, output_path: str, target_language: str = "zh-CN") -> Dict[str, Any]:
    raw = Path(source_srt_path).read_text(encoding="utf-8")
    proxy = build_translation_timing_proxy_srt(raw, target_language=target_language)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(proxy, encoding="utf-8")
    return {
        "source_srt": source_srt_path,
        "output_srt": output_path,
        "target_language": target_language,
        "cue_count": len(parse_srt(proxy)),
    }


def _load_subtitle_cues(path: str) -> List[Cue]:
    subtitle_path = Path(path)
    raw = subtitle_path.read_text(encoding="utf-8")
    if subtitle_path.suffix.lower() == ".vtt":
        return parse_vtt_cues(raw)
    return parse_srt(raw)


def evaluate_files(
    candidate_path: str,
    words_path: str,
    sample_id: str,
    output_path: str,
    asr_offset_seconds: float = 0.0,
    candidate_offset_seconds: float = 0.0,
    window_start: Optional[float] = None,
    window_end: Optional[float] = None,
    alignment_mode: str = "text",
    alignment_text_path: Optional[str] = None,
    reference_path: Optional[str] = None,
) -> Dict[str, Any]:
    cues = _load_subtitle_cues(candidate_path)
    cues = offset_cues(cues, candidate_offset_seconds)
    cues = filter_cues_by_window(cues, window_start, window_end)
    metric_cues = cues
    if alignment_text_path is not None:
        alignment_cues = _load_subtitle_cues(alignment_text_path)
        alignment_cues = offset_cues(alignment_cues, candidate_offset_seconds)
        alignment_cues = filter_cues_by_window(alignment_cues, window_start, window_end)
        if len(alignment_cues) != len(cues):
            raise ValueError(
                "alignment text cue count (%d) must match candidate cue count (%d)"
                % (len(alignment_cues), len(cues))
            )
        metric_cues = [
            Cue(index=cue.index, start=cue.start, end=cue.end, text=alignment_cue.text)
            for cue, alignment_cue in zip(cues, alignment_cues)
        ]
    words = filter_words_by_window(offset_words(load_words_json(words_path), asr_offset_seconds), window_start, window_end)
    report = evaluate_cues(metric_cues, words, sample_id=sample_id, alignment_mode=alignment_mode)
    report["candidate_path"] = candidate_path
    report["asr_words_path"] = words_path
    if reference_path is not None:
        report["reference_path"] = reference_path
    report["window_start_seconds"] = window_start
    report["window_end_seconds"] = window_end
    report["asr_offset_seconds"] = asr_offset_seconds
    report["candidate_offset_seconds"] = candidate_offset_seconds
    if alignment_text_path is not None:
        for index, (row, cue, alignment_cue) in enumerate(zip(report["cues"], cues, metric_cues)):
            row["alignment_text"] = alignment_cue.text
            row["text"] = cue.text
            row["reading_speed_chars_per_second"] = (
                len("".join(ch for ch in cue.text if not ch.isspace()))
                / max(0.001, cue.end - cue.start)
            )
            row["short_feedback"] = is_short_feedback(cue.text)
            row["weak_boundary"] = weak_boundary(cue, cues[index + 1] if index + 1 < len(cues) else None)
            row["cjk_singleton"] = cjk_singleton(cue)
    report["summary"] = summarize_report(report)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def evaluate_reference_files(
    candidate_path: str,
    reference_path: str,
    sample_id: str,
    output_path: str,
    candidate_offset_seconds: float = 0.0,
    reference_offset_seconds: float = 0.0,
    window_start: Optional[float] = None,
    window_end: Optional[float] = None,
) -> Dict[str, Any]:
    cues = offset_cues(_load_subtitle_cues(candidate_path), candidate_offset_seconds)
    cues = filter_cues_by_window(cues, window_start, window_end)
    reference_cues = offset_cues(_load_subtitle_cues(reference_path), reference_offset_seconds)
    reference_cues = filter_cues_by_window(reference_cues, window_start, window_end)
    report = evaluate_cues_against_reference_cues(cues, reference_cues, sample_id=sample_id)
    report["candidate_path"] = candidate_path
    report["reference_path"] = reference_path
    report["window_start_seconds"] = window_start
    report["window_end_seconds"] = window_end
    report["candidate_offset_seconds"] = candidate_offset_seconds
    report["reference_offset_seconds"] = reference_offset_seconds
    report["summary"] = summarize_report(report)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def evaluate_segmentation_files(
    candidate_path: str,
    reference_path: str,
    sample_id: str,
    output_path: str,
    candidate_offset_seconds: float = 0.0,
    reference_offset_seconds: float = 0.0,
    window_start: Optional[float] = None,
    window_end: Optional[float] = None,
    tolerance_seconds: float = 0.5,
    track: Optional[str] = None,
) -> Dict[str, Any]:
    """Score a candidate subtitle file's segmentation against a reference file."""
    candidate_cues = offset_cues(_load_subtitle_cues(candidate_path), candidate_offset_seconds)
    reference_cues = offset_cues(_load_subtitle_cues(reference_path), reference_offset_seconds)
    report = evaluate_segmentation(
        candidate_cues,
        reference_cues,
        sample_id=sample_id,
        window_start=window_start,
        window_end=window_end,
        tolerance=tolerance_seconds,
        track=track,
    )
    report["candidate_path"] = candidate_path
    report["reference_path"] = reference_path
    report["candidate_offset_seconds"] = candidate_offset_seconds
    report["reference_offset_seconds"] = reference_offset_seconds
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def summarize_segmentation_suite_files(
    report_paths: List[str],
    output_path: str,
) -> Dict[str, Any]:
    """Aggregate per-sample segmentation reports into a suite-level summary."""
    reports = []
    for path in report_paths:
        with open(path, "r", encoding="utf-8") as handle:
            reports.append(json.load(handle))
    summary = summarize_segmentation_reports(reports)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def compare_report_files(
    baseline_report_path: str,
    optimized_report_path: str,
    output_path: str,
    language_group: Optional[str] = None,
    gate_mode: str = "timing",
) -> Dict[str, Any]:
    with open(baseline_report_path, "r", encoding="utf-8") as handle:
        baseline = json.load(handle)
    with open(optimized_report_path, "r", encoding="utf-8") as handle:
        optimized = json.load(handle)
    comparison = compare_reports(baseline, optimized, language_group=language_group, gate_mode=gate_mode)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(comparison, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return comparison


def summarize_suite_files(
    comparison_paths: List[str],
    output_path: str,
    required_language_groups: Optional[List[str]] = None,
) -> Dict[str, Any]:
    comparisons = []
    for path in comparison_paths:
        with open(path, "r", encoding="utf-8") as handle:
            comparisons.append(json.load(handle))
    summary = summarize_suite(comparisons, required_language_groups=required_language_groups)
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary


def transcribe_file(
    audio_path: str,
    output_path: str,
    model_size: str,
    language: Optional[str],
    engine: str = "faster-whisper",
    whisper_cli: str = "whisper-cli",
    model_path: Optional[str] = None,
    ffmpeg: str = "ffmpeg",
    prompt: Optional[str] = None,
    whisper_cpp_no_gpu: bool = False,
) -> Dict[str, object]:
    if engine == "whisper-cpp":
        return transcribe_words_whisper_cpp(
            audio_path=audio_path,
            output_path=output_path,
            model_path=model_path or "",
            language=language,
            whisper_cli=whisper_cli,
            ffmpeg=ffmpeg,
            prompt=prompt,
            no_gpu=whisper_cpp_no_gpu,
        )
    return transcribe_words(audio_path=audio_path, output_path=output_path, model_size=model_size, language=language)


def vad_file(audio_path: str, output_path: str) -> Dict[str, object]:
    return detect_speech_file(audio_path=audio_path, output_path=output_path)

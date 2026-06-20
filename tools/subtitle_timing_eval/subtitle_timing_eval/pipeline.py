from __future__ import annotations

import html
import json
import os
import subprocess
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence
from urllib.parse import quote

from .asr import transcribe_words
from .comparison import compare_reports, summarize_suite
from .metrics import cjk_singleton, evaluate_cues, is_short_feedback, load_words_json, offset_words, summarize_report, weak_boundary
from .srt import Cue, parse_srt, serialize_srt
from .vad import detect_speech_file
from .vtt import parse_vtt_cues, parse_vtt_word_timestamps

WINDOW_COVERAGE_MIN_RATIO = 0.9
WINDOW_COVERAGE_TOLERANCE_SECONDS = 5.0


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
        if duration < 120 or duration > 360:
            errors.append("%s.section.duration_seconds must be between 120 and 360" % prefix)
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
) -> List[List[str]]:
    source = sample["source"]
    start, end, _ = sample_section(sample, duration_override_seconds)
    subtitle_lang = sample.get("subtitle_lang", "en")
    media_format = sample.get("media_format", "ba[ext=m4a]/ba/best")

    common = [
        "yt-dlp",
        "--no-playlist",
        "--force-overwrites",
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
) -> Dict[str, Any]:
    start, end, _ = sample_section(sample, duration_override_seconds)
    sample_id = sample["id"]
    workdir = "%s/%s" % (artifacts_root.rstrip("/"), sample_id)
    words_path = "%s/asr_words.json" % workdir
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

    return {
        "sample_id": sample_id,
        "language_group": sample.get("language_group", "unknown"),
        "alignment_mode": alignment_mode,
        "workdir": workdir,
        "artifacts": {
            "asr_words": words_path,
            "baseline_report": baseline_report,
            "optimized_report": optimized_report,
            "comparison": comparison_path,
        },
        "commands": {
            "prepare": prepare,
            "asr": base_command + [
                "asr",
                "--audio",
                "%s/<downloaded-audio-or-section-wav>" % workdir,
                "--out",
                words_path,
                "--model",
                model,
                "--language",
                sample_asr_language(sample),
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
                "%s/<optimized-or-cleaned-subtitle.srt>" % workdir,
                "--out",
                optimized_report,
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
) -> Dict[str, Any]:
    validate_manifest(manifest)
    samples = [
        build_sample_runbook(
            sample,
            artifacts_root=artifacts_root,
            model=model,
            duration_override_seconds=duration_override_seconds,
        )
        for sample in manifest["samples"]
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
        "required_language_groups": manifest["coverage_goal"]["required_language_groups"],
        "sample_count": len(samples),
        "samples": samples,
        "suite_command": suite_command,
        "status_completion_command": status_completion_command,
    }


def _load_comparison_files(artifacts_root: str) -> Dict[str, Dict[str, Any]]:
    comparisons: Dict[str, Dict[str, Any]] = {}
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
        previous = comparisons.get(sample_id)
        if previous is None or path.stat().st_mtime > Path(previous["_path"]).stat().st_mtime:
            payload["_path"] = str(path)
            comparisons[sample_id] = payload
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


def collect_eval_status(manifest: Dict[str, Any], artifacts_root: str) -> Dict[str, Any]:
    validate_manifest(manifest)
    comparisons = _load_comparison_files(artifacts_root)
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
        comparison = comparisons.get(sample_id)
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
        comparison_window_seconds = _comparison_window_seconds(comparison_path) if comparison_path else None
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
        "comparison_count": len(comparisons),
        "blocker_count": len(blocked_samples),
        "missing_samples": missing_samples,
        "blocked_samples": blocked_samples,
        "failing_samples": failing_samples,
        "insufficient_window_samples": insufficient_window_samples,
        "samples": samples,
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


def build_qa_packet(
    manifest: Dict[str, Any],
    artifacts_root: str,
    max_segments_per_group: int = 8,
) -> Dict[str, Any]:
    validate_manifest(manifest)
    status = collect_eval_status(manifest, artifacts_root)
    samples_by_id = {sample["id"]: sample for sample in manifest["samples"]}
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
        rows.sort(key=_qa_segment_score, reverse=True)
        for row in rows[:max_segments_per_group]:
            start = float(row.get("start") or sample.get("section", {}).get("start_seconds", 0))
            baseline_row = _matching_baseline_row(row, baseline_rows)
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
                "text": row.get("text", ""),
                "baseline_text": baseline_row.get("text", ""),
                "optimized_text": row.get("text", ""),
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
        group["segments"].sort(key=lambda item: item["score"], reverse=True)
        group["segments"] = group["segments"][:max_segments_per_group]

    return {
        "status": {
            "passes_timing_gate": status["passes_timing_gate"],
            "passes_sample_completion_gate": status["passes_sample_completion_gate"],
            "sample_count": status["sample_count"],
            "comparison_count": status["comparison_count"],
            "timing_language_groups": status["timing_language_groups"],
            "preservation_language_groups": status["preservation_language_groups"],
            "missing_samples": status["missing_samples"],
            "blocked_samples": status["blocked_samples"],
            "failing_samples": status["failing_samples"],
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
) -> Dict[str, Any]:
    samples_by_id = {sample["id"]: sample for sample in manifest.get("samples", [])}
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
            enriched = dict(segment)
            enriched.update({
                "review_id": review_id,
                "media": media,
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
) -> str:
    data = _qa_review_data(packet, manifest, artifacts_root, output_path)
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
      state[id] ||= {{ verdict: "", notes: "" }};
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
        human_verdict: entry(segment.review_id).verdict,
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
        "unknown_verdicts": [],
        "passes_group_gate": False,
    }


def summarize_qa_verdict_records(
    records: Sequence[Dict[str, Any]],
    required_language_groups: Sequence[str],
    min_pass_per_group: int = 2,
) -> Dict[str, Any]:
    groups: Dict[str, Dict[str, Any]] = {}
    required = list(required_language_groups)

    for record in records:
        language_group = str(record.get("language_group") or "unknown")
        group = groups.setdefault(language_group, _empty_qa_group())
        group["total_review_count"] += 1
        raw_verdict = str(record.get("human_verdict") or record.get("verdict") or "").strip()
        verdict = raw_verdict.upper()
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

    for language_group in required:
        groups.setdefault(language_group, _empty_qa_group())

    failing_groups: List[str] = []
    for language_group in sorted(groups):
        group = groups[language_group]
        group["passes_group_gate"] = (
            group["pass_count"] >= min_pass_per_group
            and group["fail_count"] == 0
            and group["unchecked_count"] == 0
        )
        if language_group in required and not group["passes_group_gate"]:
            failing_groups.append(language_group)

    return {
        "passes_qa_gate": not failing_groups,
        "required_language_groups": required,
        "min_pass_per_group": min_pass_per_group,
        "failing_language_groups": failing_groups,
        "language_groups": groups,
    }


def summarize_qa_verdicts(
    markdown: str,
    required_language_groups: Sequence[str],
    min_pass_per_group: int = 2,
) -> Dict[str, Any]:
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
        raw_verdict = cells[verdict_index].strip() if verdict_index < len(cells) else ""
        records.append({
            "language_group": current_group,
            "sample_id": cells[sample_index] if sample_index is not None and sample_index < len(cells) else "",
            "human_verdict": raw_verdict,
            "line": line_number,
        })

    return summarize_qa_verdict_records(
        records,
        required_language_groups=required_language_groups,
        min_pass_per_group=min_pass_per_group,
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
            gate_mode = "preserve" if "manual_captions" in sample.get("stressors", []) else "timing"
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


def build_full_media_fallback_command(sample: Dict[str, Any], workdir: Path) -> List[str]:
    media_format = sample.get("media_format", "ba[ext=m4a]/ba/best")
    return [
        "yt-dlp",
        "--no-playlist",
        "--force-overwrites",
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
) -> Path:
    start, _, duration = sample_section(sample, duration_override_seconds)
    run_command(build_full_media_fallback_command(sample, workdir), dry_run=dry_run)
    output_path = workdir / ("%s.section.wav" % sample["id"])
    if dry_run:
        run_command(build_trim_fallback_command(Path("<downloaded-full-media>"), output_path, start, duration), dry_run=True)
        return output_path
    input_path = find_fallback_media_file(sample, workdir)
    run_command(build_trim_fallback_command(input_path, output_path, start, duration), dry_run=dry_run)
    return output_path


def prepare_sample(
    sample: Dict[str, Any],
    artifacts_root: str,
    dry_run: bool = False,
    duration_override_seconds: Optional[float] = None,
) -> Path:
    workdir = sample_workdir(artifacts_root, sample["id"])
    output_template = str(workdir / "%(id)s.%(ext)s")
    media_command, converted_subtitle_command, subtitle_command = build_prepare_commands(
        sample,
        output_template,
        duration_override_seconds=duration_override_seconds,
    )
    try:
        run_command(media_command, dry_run=dry_run)
    except subprocess.CalledProcessError:
        print("section media download failed; falling back to full media download and local trim")
        run_full_media_fallback(
            sample,
            workdir,
            dry_run=dry_run,
            duration_override_seconds=duration_override_seconds,
        )
    run_command(converted_subtitle_command, dry_run=dry_run)
    run_command(subtitle_command, dry_run=dry_run)
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


def evaluate_files(
    candidate_path: str,
    words_path: str,
    sample_id: str,
    output_path: str,
    asr_offset_seconds: float = 0.0,
    window_start: Optional[float] = None,
    window_end: Optional[float] = None,
    alignment_mode: str = "text",
    alignment_text_path: Optional[str] = None,
) -> Dict[str, Any]:
    path = Path(candidate_path)
    raw = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".vtt":
        cues = parse_vtt_cues(raw)
    else:
        cues = parse_srt(raw)
    cues = filter_cues_by_window(cues, window_start, window_end)
    metric_cues = cues
    if alignment_text_path is not None:
        alignment_path = Path(alignment_text_path)
        alignment_raw = alignment_path.read_text(encoding="utf-8")
        if alignment_path.suffix.lower() == ".vtt":
            alignment_cues = parse_vtt_cues(alignment_raw)
        else:
            alignment_cues = parse_srt(alignment_raw)
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
    report["window_start_seconds"] = window_start
    report["window_end_seconds"] = window_end
    report["asr_offset_seconds"] = asr_offset_seconds
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


def transcribe_file(audio_path: str, output_path: str, model_size: str, language: Optional[str]) -> Dict[str, object]:
    return transcribe_words(audio_path=audio_path, output_path=output_path, model_size=model_size, language=language)


def vad_file(audio_path: str, output_path: str) -> Dict[str, object]:
    return detect_speech_file(audio_path=audio_path, output_path=output_path)

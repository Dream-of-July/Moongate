from __future__ import annotations

from statistics import mean
from typing import Any, Dict, Iterable, List, Sequence

from .metrics import summarize_report


ACCEPTED_RATIO_GATE = 0.90

DELTA_FIELDS = [
    "cue_count",
    "accepted_ratio",
    "avg_duration",
    "median_duration",
    "p90_duration",
    "p90_abs_start_error_ms",
    "p90_abs_end_error_ms",
    "early_cutoff_count",
    "late_hold_count",
    "long_idle_hold_count",
    "weak_boundary_count",
    "cjk_singleton_count",
    "avg_reading_speed_chars_per_second",
    "p90_reading_speed_chars_per_second",
]


def _report_with_gate(report: Dict[str, Any]) -> Dict[str, Any]:
    summary = report.get("summary") or summarize_report(report)
    failures = []
    if summary["accepted_ratio"] < ACCEPTED_RATIO_GATE:
        failures.append("accepted_ratio")
    if summary["early_cutoff_count"] > 0:
        failures.append("early_cutoff")
    if summary["long_idle_hold_count"] > 0:
        failures.append("long_idle_hold")
    if summary["cjk_singleton_count"] > 0:
        failures.append("cjk_singleton")
    return {
        "summary": summary,
        "passes_timing_gate": not failures,
        "gate_failures": failures,
    }


def _preservation_failures(delta: Dict[str, Any]) -> List[str]:
    failures = []
    if delta.get("cue_count", 0) > 0:
        failures.append("cue_count_regression")
    if delta.get("accepted_ratio", 0) < -0.001:
        failures.append("accepted_ratio_regression")
    if delta.get("early_cutoff_count", 0) > 0:
        failures.append("early_cutoff_regression")
    if delta.get("late_hold_count", 0) > 0:
        failures.append("late_hold_regression")
    if delta.get("long_idle_hold_count", 0) > 0:
        failures.append("long_idle_hold_regression")
    if delta.get("weak_boundary_count", 0) > 0:
        failures.append("weak_boundary_regression")
    if delta.get("cjk_singleton_count", 0) > 0:
        failures.append("cjk_singleton_regression")
    return failures


def compare_reports(
    baseline_report: Dict[str, Any],
    optimized_report: Dict[str, Any],
    language_group: str | None = None,
    gate_mode: str = "timing",
) -> Dict[str, Any]:
    if gate_mode not in {"timing", "preserve"}:
        raise ValueError("gate_mode must be 'timing' or 'preserve'")
    baseline = _report_with_gate(baseline_report)
    optimized = _report_with_gate(optimized_report)
    delta = {}
    for field in DELTA_FIELDS:
        baseline_value = baseline["summary"].get(field)
        optimized_value = optimized["summary"].get(field)
        if isinstance(baseline_value, (int, float)) and isinstance(optimized_value, (int, float)):
            delta[field] = optimized_value - baseline_value

    if gate_mode == "preserve":
        failures = _preservation_failures(delta)
        optimized["passes_timing_gate"] = not failures
        optimized["passes_preservation_gate"] = not failures
        optimized["gate_failures"] = failures

    return {
        "sample_id": optimized_report.get("sample_id") or baseline_report.get("sample_id"),
        "language_group": language_group or optimized_report.get("language_group") or baseline_report.get("language_group") or "unknown",
        "gate_mode": gate_mode,
        "baseline": baseline,
        "optimized": optimized,
        "delta": delta,
    }


def summarize_suite(
    comparisons: Iterable[Dict[str, Any]],
    required_language_groups: Sequence[str] | None = None,
) -> Dict[str, Any]:
    items = list(comparisons)
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for item in items:
        groups.setdefault(item.get("language_group") or "unknown", []).append(item)

    timing_groups = set()
    preservation_groups = set()
    failing_timing_groups = set()
    language_groups = {}
    for group, group_items in groups.items():
        ratios = [item["optimized"]["summary"]["accepted_ratio"] for item in group_items]
        passing_group_items = [
            item for item in group_items
            if item["optimized"]["passes_timing_gate"]
        ]
        timing_items = [
            item for item in passing_group_items
            if item.get("gate_mode", "timing") == "timing"
        ]
        preservation_items = [
            item for item in passing_group_items
            if item.get("gate_mode") == "preserve"
        ]
        if timing_items:
            timing_groups.add(group)
        if preservation_items:
            preservation_groups.add(group)
        if any(
            not item["optimized"]["passes_timing_gate"]
            and item.get("gate_mode", "timing") == "timing"
            for item in group_items
        ):
            failing_timing_groups.add(group)
        language_groups[group] = {
            "sample_count": len(group_items),
            "timing_sample_count": len(timing_items),
            "preservation_sample_count": len(preservation_items),
            "accepted_ratio": mean(ratios) if ratios else 0.0,
            "passes_timing_gate": all(item["optimized"]["passes_timing_gate"] for item in group_items),
            "failed_samples": [
                item["sample_id"]
                for item in group_items
                if not item["optimized"]["passes_timing_gate"]
            ],
        }

    required = list(required_language_groups or [])
    missing_groups = sorted(set(required) - set(language_groups.keys()))
    missing_strict_timing_groups = sorted(set(required) - timing_groups)
    failing_strict_timing_groups = sorted(failing_timing_groups)
    passes_language_coverage_gate = bool(items) and all(
        item["optimized"]["passes_timing_gate"] for item in items
    ) and all(
        group["passes_timing_gate"] for group in language_groups.values()
    ) and not missing_groups
    passes_strict_timing_gate = (
        passes_language_coverage_gate
        and not missing_strict_timing_groups
        and not failing_strict_timing_groups
    )

    return {
        "sample_count": len(items),
        "accepted_ratio": mean([item["optimized"]["summary"]["accepted_ratio"] for item in items]) if items else 0.0,
        "passes_language_coverage_gate": passes_language_coverage_gate,
        "passes_strict_timing_gate": passes_strict_timing_gate,
        "passes_timing_gate": passes_strict_timing_gate,
        "required_language_groups": required,
        "missing_language_groups": missing_groups,
        "missing_strict_timing_language_groups": missing_strict_timing_groups,
        "failing_strict_timing_language_groups": failing_strict_timing_groups,
        "timing_language_groups": sorted(timing_groups),
        "preservation_language_groups": sorted(preservation_groups),
        "language_groups": language_groups,
        "failed_samples": [
            item["sample_id"]
            for item in items
            if not item["optimized"]["passes_timing_gate"]
        ],
    }

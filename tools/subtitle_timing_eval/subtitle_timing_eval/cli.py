from __future__ import annotations

import argparse
import json
from pathlib import Path

from .pipeline import (
    _manual_suite_filtered_manifest,
    audit_manual_caption_suite,
    build_auto_reference_qa_records,
    build_completion_audit,
    build_suite_runbook,
    build_iteration_report,
    build_qa_packet,
    collect_eval_status,
    collect_manual_suite_status,
    compare_report_files,
    evaluate_files,
    evaluate_reference_files,
    extract_srt_words_file,
    extract_qa_verdict_records_from_markdown,
    extract_vtt_words_file,
    load_manifest,
    materialize_existing_comparisons,
    prepare_sample,
    render_qa_review_html,
    render_qa_checklist_markdown,
    render_qa_remaining_queue_markdown,
    render_qa_markdown,
    select_manual_caption_suite,
    summarize_qa_verdict_records,
    summarize_qa_verdicts,
    summarize_suite_files,
    transcribe_file,
    vad_file,
    write_translation_timing_proxy_file,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Evaluate Moongate subtitle timing against local ASR word timestamps.")
    sub = parser.add_subparsers(dest="command", required=True)

    validate = sub.add_parser("validate-manifest", help="Validate the sample manifest shape.")
    validate.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")

    prepare = sub.add_parser("prepare", help="Download a sample section and subtitle files with yt-dlp.")
    prepare.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    prepare.add_argument("--sample-id", required=True)
    prepare.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    prepare.add_argument("--duration-seconds", type=float, help="Override manifest duration for smoke runs.")
    prepare.add_argument("--dry-run", action="store_true")

    runbook = sub.add_parser("runbook", help="Generate a manifest-driven eval runbook without downloading media.")
    runbook.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    runbook.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    runbook.add_argument("--model", default="small")
    runbook.add_argument("--asr-engine", choices=["faster-whisper", "whisper-cpp"], default="faster-whisper")
    runbook.add_argument("--model-path", help="Local ggml model path when --asr-engine whisper-cpp is used.")
    runbook.add_argument("--whisper-cli", default="whisper-cli")
    runbook.add_argument("--ffmpeg", default="ffmpeg")
    runbook.add_argument("--no-gpu", action="store_true", help="Pass --no-gpu to whisper.cpp ASR commands.")
    runbook.add_argument("--duration-seconds", type=float, help="Override manifest duration for smoke run commands.")
    runbook.add_argument("--selection", help="Manual suite selection JSON; scopes the runbook to selected samples.")
    runbook.add_argument("--only-incomplete", action="store_true", help="When used with --selection, include only selected samples whose current status is not pass.")
    runbook.add_argument("--out")

    status = sub.add_parser("status", help="Summarize current eval artifacts against manifest coverage.")
    status.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    status.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    status.add_argument("--out")
    status.add_argument("--require-sample-completion", action="store_true", help="Exit non-zero when any manifest sample is missing, failing, or externally blocked.")

    qa_report = sub.add_parser("qa-report", help="Write a Markdown side-by-side QA packet from current eval artifacts.")
    qa_report.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_report.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_report.add_argument("--selection", help="Manual suite selection JSON; scopes QA to selected samples.")
    qa_report.add_argument("--out", required=True)
    qa_report.add_argument("--max-segments-per-group", type=int, default=8)
    qa_report.add_argument("--segment-mode", choices=["risk", "representative"], default="risk")

    qa_review = sub.add_parser("qa-review", help="Write a local HTML side-by-side review bundle for human subtitle timing QA.")
    qa_review.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_review.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_review.add_argument("--selection", help="Manual suite selection JSON; scopes QA to selected samples.")
    qa_review.add_argument("--out", required=True)
    qa_review.add_argument("--max-segments-per-group", type=int, default=8)
    qa_review.add_argument("--segment-mode", choices=["risk", "representative"], default="risk")
    qa_review.add_argument("--prefill-json", help="Optional qa-autofill/review JSON whose verdicts are shown as suggestions, not applied as human verdicts.")

    qa_checklist = sub.add_parser("qa-checklist", help="Write a compact Markdown checklist for final human PASS/FAIL review.")
    qa_checklist.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_checklist.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_checklist.add_argument("--selection", help="Manual suite selection JSON; scopes QA to selected samples.")
    qa_checklist.add_argument("--out", required=True)
    qa_checklist.add_argument("--max-segments-per-group", type=int, default=2)
    qa_checklist.add_argument("--segment-mode", choices=["risk", "representative"], default="representative")
    qa_checklist.add_argument("--prefill-json", help="Optional qa-autofill/review JSON whose verdicts are shown in the Suggested column.")

    qa_remaining = sub.add_parser("qa-remaining", help="Write a Markdown queue of QA rows still missing human-source verdicts.")
    qa_remaining.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_remaining.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_remaining.add_argument("--selection", help="Manual suite selection JSON; scopes QA to selected samples.")
    qa_remaining.add_argument("--out", required=True)
    qa_remaining.add_argument("--max-segments-per-group", type=int, default=2)
    qa_remaining.add_argument("--segment-mode", choices=["risk", "representative"], default="representative")
    qa_remaining.add_argument("--prefill-json", help="Optional qa-autofill/review JSON whose verdicts are shown in the Suggested column.")
    qa_remaining.add_argument("--human-review-json", help="Optional qa-review JSON export; only human_review/manual_review PASS/FAIL records count as reviewed.")
    qa_remaining.add_argument("--human-qa-report", help="Optional manually edited QA Markdown report; PASS/FAIL cells count as human_review rows.")

    qa_autofill = sub.add_parser("qa-autofill", help="Prefill review JSON from strict timing/reference metrics without claiming human review.")
    qa_autofill.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_autofill.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_autofill.add_argument("--selection", help="Manual suite selection JSON; scopes QA to selected samples.")
    qa_autofill.add_argument("--out", required=True)
    qa_autofill.add_argument("--max-segments-per-group", type=int, default=2)
    qa_autofill.add_argument("--segment-mode", choices=["risk", "representative"], default="representative")
    qa_autofill.add_argument("--include-rejected", action="store_true", help="Also write records for rejected timing rows.")

    qa_verdicts = sub.add_parser("qa-verdicts", help="Summarize human PASS/FAIL verdicts from a side-by-side QA packet.")
    qa_verdicts.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_verdicts.add_argument("--selection", help="Manual suite selection JSON; uses selected source languages as required QA groups.")
    qa_verdicts.add_argument("--qa-report", default="artifacts/subtitle_timing_eval/qa.side-by-side.md")
    qa_verdicts.add_argument("--review-json", help="JSON exported from qa-review HTML.")
    qa_verdicts.add_argument("--out")
    qa_verdicts.add_argument("--min-pass-per-group", type=int, default=2)
    qa_verdicts.add_argument("--required-language-group", action="append", default=[])
    qa_verdicts.add_argument("--require-human-source", action="store_true", help="For review JSON, require PASS/FAIL rows to have verdict_source=human_review/manual_review.")
    qa_verdicts.add_argument("--require-text-risk-notes", action="store_true", help="Require every PASS row with Text Risk flags to include reviewer notes.")
    qa_verdicts.add_argument("--require-pass", action="store_true", help="Exit non-zero when any required language group lacks enough PASS verdicts, has FAIL verdicts, or still has blank/unknown verdicts.")

    materialize = sub.add_parser("materialize-comparisons", help="Create comparison files from existing baseline/optimized report pairs.")
    materialize.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    materialize.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    materialize.add_argument("--out")

    iteration_report = sub.add_parser("iteration-report", help="Summarize current artifacts into the next subtitle-timing optimization backlog.")
    iteration_report.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    iteration_report.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    iteration_report.add_argument("--selection", help="Manual suite selection JSON; scopes the report to selected samples.")
    iteration_report.add_argument("--out", required=True)
    iteration_report.add_argument("--max-examples-per-issue", type=int, default=3)

    manual_suite = sub.add_parser("select-manual-suite", help="Select a seeded random suite of distinct-language human-caption samples.")
    manual_suite.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    manual_suite.add_argument("--count", type=int, default=10)
    manual_suite.add_argument("--seed", default="manual-caption-suite-v1")
    manual_suite.add_argument("--out", required=True)
    manual_suite.add_argument("--exclude-sample-id", action="append", default=[], help="Exclude a known blocked or unsuitable manifest sample before drawing the suite.")
    manual_suite.add_argument("--require-ready", action="store_true", help="Exit non-zero unless enough distinct manual-caption languages are available.")

    manual_suite_status = sub.add_parser("manual-suite-status", help="Summarize artifacts only for a selected human-caption language suite.")
    manual_suite_status.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    manual_suite_status.add_argument("--selection", required=True)
    manual_suite_status.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    manual_suite_status.add_argument("--out")
    manual_suite_status.add_argument("--require-ready", action="store_true", help="Exit non-zero unless the selected suite has complete passing artifacts.")

    manual_suite_audit = sub.add_parser("manual-suite-audit", help="Run several seeded manual-caption suite draws against current strict timing artifacts.")
    manual_suite_audit.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    manual_suite_audit.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    manual_suite_audit.add_argument("--count", type=int, default=10)
    manual_suite_audit.add_argument("--seed", action="append", default=[], help="Seed to audit. Repeat for multiple draws.")
    manual_suite_audit.add_argument("--seed-count", type=int, default=5, help="Number of generated seeds to use when --seed is omitted.")
    manual_suite_audit.add_argument("--seed-prefix", default="manual-caption-suite-audit")
    manual_suite_audit.add_argument("--exclude-sample-id", action="append", default=[], help="Exclude a known blocked or unsuitable manifest sample before each draw.")
    manual_suite_audit.add_argument("--out")
    manual_suite_audit.add_argument("--require-pass", action="store_true", help="Exit non-zero unless every audited seed passes the strict manual-suite gate.")

    completion_audit = sub.add_parser("completion-audit", help="Aggregate the 10-language manual-caption 90% evidence and remaining completion gaps.")
    completion_audit.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    completion_audit.add_argument("--selection", required=True)
    completion_audit.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    completion_audit.add_argument("--audit-json", help="manual-suite-audit JSON evidence.")
    completion_audit.add_argument("--auto-qa-json", help="qa-autofill/auto-reference verdict summary JSON evidence.")
    completion_audit.add_argument("--human-qa-json", help="human side-by-side qa-verdicts JSON evidence.")
    completion_audit.add_argument("--human-qa-report", help="Manually edited QA Markdown report; PASS/FAIL cells are summarized as human review evidence.")
    completion_audit.add_argument("--expected-count", type=int, default=10)
    completion_audit.add_argument("--min-accepted-ratio", type=float, default=0.90)
    completion_audit.add_argument("--min-pass-per-group", type=int, default=2)
    completion_audit.add_argument("--out", required=True)
    completion_audit.add_argument("--require-machine-ready", action="store_true", help="Exit non-zero unless automated evidence gates are satisfied.")
    completion_audit.add_argument("--require-text-risk-notes", action="store_true", help="Keep human QA open until PASS rows with Text Risk flags include reviewer notes.")
    completion_audit.add_argument("--require-complete", action="store_true", help="Exit non-zero unless automated evidence and human QA gates are both satisfied.")

    asr = sub.add_parser("asr", help="Run ASR and write word timestamps JSON.")
    asr.add_argument("--audio", required=True)
    asr.add_argument("--out", required=True)
    asr.add_argument("--model", default="small")
    asr.add_argument("--language")
    asr.add_argument("--engine", choices=["faster-whisper", "whisper-cpp"], default="faster-whisper")
    asr.add_argument("--model-path", help="Local ggml model path when --engine whisper-cpp is used.")
    asr.add_argument("--whisper-cli", default="whisper-cli")
    asr.add_argument("--ffmpeg", default="ffmpeg")
    asr.add_argument("--prompt")
    asr.add_argument("--no-gpu", action="store_true", help="Pass --no-gpu to whisper.cpp.")

    vad = sub.add_parser("vad", help="Extract speech activity segments from audio using local energy VAD.")
    vad.add_argument("--audio", required=True)
    vad.add_argument("--out", required=True)

    vtt_words = sub.add_parser("vtt-words", help="Extract YouTube inline VTT word timestamps to JSON.")
    vtt_words.add_argument("--vtt", required=True)
    vtt_words.add_argument("--out", required=True)

    srt_words = sub.add_parser("srt-words", help="Create cue-derived word timestamps from an SRT file.")
    srt_words.add_argument("--srt", required=True)
    srt_words.add_argument("--out", required=True)

    translation_proxy = sub.add_parser("translation-proxy-srt", help="Create a translated-output timing proxy SRT from source SRT cue times.")
    translation_proxy.add_argument("--source-srt", required=True)
    translation_proxy.add_argument("--out", required=True)
    translation_proxy.add_argument("--target-language", default="zh-CN")

    metrics = sub.add_parser("metrics", help="Compare an SRT/VTT file with ASR word timestamps.")
    metrics.add_argument("--candidate", required=True)
    metrics.add_argument("--asr-words", required=True)
    metrics.add_argument("--sample-id", required=True)
    metrics.add_argument("--out", required=True)
    metrics.add_argument("--asr-offset-seconds", type=float, default=0.0)
    metrics.add_argument("--candidate-offset-seconds", type=float, default=0.0)
    metrics.add_argument("--window-start-seconds", type=float)
    metrics.add_argument("--window-end-seconds", type=float)
    metrics.add_argument("--alignment-mode", choices=["text", "overlap", "speech"], default="text")
    metrics.add_argument("--alignment-text-candidate", help="Subtitle file whose text should be used only for ASR alignment while scoring candidate cue times.")

    reference_metrics = sub.add_parser("reference-metrics", help="Compare a candidate subtitle directly against human reference cue timings.")
    reference_metrics.add_argument("--candidate", required=True)
    reference_metrics.add_argument("--reference", required=True)
    reference_metrics.add_argument("--sample-id", required=True)
    reference_metrics.add_argument("--out", required=True)
    reference_metrics.add_argument("--candidate-offset-seconds", type=float, default=0.0)
    reference_metrics.add_argument("--reference-offset-seconds", type=float, default=0.0)
    reference_metrics.add_argument("--window-start-seconds", type=float)
    reference_metrics.add_argument("--window-end-seconds", type=float)

    compare = sub.add_parser("compare", help="Compare baseline and optimized timing reports.")
    compare.add_argument("--baseline-report", required=True)
    compare.add_argument("--optimized-report", required=True)
    compare.add_argument("--out", required=True)
    compare.add_argument("--language-group")
    compare.add_argument("--gate-mode", choices=["timing", "preserve"], default="timing")

    suite = sub.add_parser("suite", help="Summarize several baseline-vs-optimized comparisons.")
    suite.add_argument("--comparison", action="append", required=True)
    suite.add_argument("--out", required=True)
    suite.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    suite.add_argument("--require-manifest-coverage", action="store_true")
    suite.add_argument("--required-language-group", action="append", default=[])

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "validate-manifest":
        data = load_manifest(args.manifest)
        print("samples: %d" % len(data["samples"]))
        return

    if args.command == "prepare":
        data = load_manifest(args.manifest)
        sample = next((s for s in data["samples"] if s["id"] == args.sample_id), None)
        if sample is None:
            raise SystemExit("unknown sample id: %s" % args.sample_id)
        directory = prepare_sample(
            sample,
            artifacts_root=args.artifacts,
            dry_run=args.dry_run,
            duration_override_seconds=args.duration_seconds,
        )
        print(directory)
        return

    if args.command == "runbook":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        runbook_payload = build_suite_runbook(
            data,
            artifacts_root=args.artifacts,
            model=args.model,
            duration_override_seconds=args.duration_seconds,
            manifest_path=args.manifest,
            selection=selection,
            selection_path=args.selection,
            only_incomplete=args.only_incomplete,
            asr_engine=args.asr_engine,
            model_path=args.model_path,
            whisper_cli=args.whisper_cli,
            ffmpeg=args.ffmpeg,
            whisper_cpp_no_gpu=args.no_gpu,
        )
        raw = json.dumps(runbook_payload, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        return

    if args.command == "status":
        data = load_manifest(args.manifest)
        status_payload = collect_eval_status(data, args.artifacts)
        raw = json.dumps(status_payload, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        if args.require_sample_completion and not status_payload["passes_sample_completion_gate"]:
            raise SystemExit(
                "sample completion gate failed: missing_samples=%s blocked_samples=%s failing_samples=%s insufficient_window_samples=%s"
                % (
                    status_payload["missing_samples"],
                    status_payload["blocked_samples"],
                    status_payload["failing_samples"],
                    status_payload["insufficient_window_samples"],
                )
            )
        return

    if args.command == "qa-report":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        packet = build_qa_packet(
            data,
            args.artifacts,
            max_segments_per_group=args.max_segments_per_group,
            selection=selection,
            segment_mode=args.segment_mode,
        )
        raw = render_qa_markdown(packet)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-review":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        packet = build_qa_packet(
            data,
            args.artifacts,
            max_segments_per_group=args.max_segments_per_group,
            selection=selection,
            segment_mode=args.segment_mode,
        )
        manifest_for_review = _manual_suite_filtered_manifest(data, selection) if selection is not None else data
        prefill = json.loads(Path(args.prefill_json).read_text(encoding="utf-8")) if args.prefill_json else None
        raw = render_qa_review_html(packet, manifest_for_review, args.artifacts, args.out, prefill_reviews=prefill)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-checklist":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        packet = build_qa_packet(
            data,
            args.artifacts,
            max_segments_per_group=args.max_segments_per_group,
            selection=selection,
            segment_mode=args.segment_mode,
        )
        prefill = json.loads(Path(args.prefill_json).read_text(encoding="utf-8")) if args.prefill_json else None
        raw = render_qa_checklist_markdown(packet, prefill_reviews=prefill)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-remaining":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        packet = build_qa_packet(
            data,
            args.artifacts,
            max_segments_per_group=args.max_segments_per_group,
            selection=selection,
            segment_mode=args.segment_mode,
        )
        prefill = json.loads(Path(args.prefill_json).read_text(encoding="utf-8")) if args.prefill_json else None
        human_review_records = []
        if args.human_review_json:
            human_payload = json.loads(Path(args.human_review_json).read_text(encoding="utf-8"))
            if isinstance(human_payload, list):
                human_review_records.extend(human_payload)
            else:
                human_review_records.extend(human_payload.get("reviews") or human_payload.get("records") or [])
        if args.human_qa_report:
            human_review_records.extend(
                extract_qa_verdict_records_from_markdown(Path(args.human_qa_report).read_text(encoding="utf-8"))
            )
        human_reviews = {"reviews": human_review_records} if human_review_records else None
        raw = render_qa_remaining_queue_markdown(packet, prefill_reviews=prefill, human_reviews=human_reviews)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-autofill":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        packet = build_qa_packet(
            data,
            args.artifacts,
            max_segments_per_group=args.max_segments_per_group,
            selection=selection,
            segment_mode=args.segment_mode,
        )
        result = build_auto_reference_qa_records(packet, require_accepted=not args.include_rejected)
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw + "\n", encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-verdicts":
        data = load_manifest(args.manifest)
        if args.selection:
            selection = json.loads(Path(args.selection).read_text(encoding="utf-8"))
            required_language_groups = [
                str(item.get("suite_language") or item.get("language_group"))
                for item in selection.get("selected", [])
            ]
        else:
            required_language_groups = list(data.get("coverage_goal", {}).get("required_language_groups", []))
        required_language_groups.extend(args.required_language_group)
        required_language_groups = sorted(set(required_language_groups))
        if args.review_json:
            review_payload = json.loads(Path(args.review_json).read_text(encoding="utf-8"))
            if isinstance(review_payload, list):
                records = review_payload
            else:
                records = review_payload.get("reviews") or review_payload.get("records") or []
            summary = summarize_qa_verdict_records(
                records,
                required_language_groups=required_language_groups,
                min_pass_per_group=args.min_pass_per_group,
                require_human_source=args.require_human_source,
                require_text_risk_notes=args.require_text_risk_notes,
            )
            summary["verdict_input_type"] = "json"
        else:
            markdown = Path(args.qa_report).read_text(encoding="utf-8")
            summary = summarize_qa_verdicts(
                markdown,
                required_language_groups=required_language_groups,
                min_pass_per_group=args.min_pass_per_group,
                require_text_risk_notes=args.require_text_risk_notes,
            )
            summary["verdict_input_type"] = "markdown"
        raw = json.dumps(summary, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        if args.require_pass and not summary["passes_qa_gate"]:
            raise SystemExit(
                "qa verdict gate failed: failing_language_groups=%s"
                % summary["failing_language_groups"]
            )
        return

    if args.command == "materialize-comparisons":
        data = load_manifest(args.manifest)
        result = materialize_existing_comparisons(data, args.artifacts)
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        return

    if args.command == "iteration-report":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8")) if args.selection else None
        result = build_iteration_report(
            data,
            args.artifacts,
            max_examples_per_issue=args.max_examples_per_issue,
            selection=selection,
        )
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw + "\n", encoding="utf-8")
        print(args.out)
        return

    if args.command == "select-manual-suite":
        data = load_manifest(args.manifest)
        result = select_manual_caption_suite(
            data,
            count=args.count,
            seed=args.seed,
            excluded_sample_ids=args.exclude_sample_id,
        )
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw + "\n", encoding="utf-8")
        print(args.out)
        if args.require_ready and not result["ready"]:
            raise SystemExit(
                "manual suite is not ready: requested=%d selected=%d missing_distinct_language_count=%d"
                % (
                    result["requested_count"],
                    result["selected_count"],
                    result["missing_distinct_language_count"],
                )
            )
        return

    if args.command == "manual-suite-status":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8"))
        result = collect_manual_suite_status(data, selection, args.artifacts)
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        if args.require_ready and not result["passes_manual_suite_gate"]:
            raise SystemExit(
                "manual suite gate failed: missing_samples=%s blocked_samples=%s failing_samples=%s insufficient_window_samples=%s"
                % (
                    result["missing_samples"],
                    result["blocked_samples"],
                    result["failing_samples"],
                    result["insufficient_window_samples"],
                )
            )
        return

    if args.command == "manual-suite-audit":
        data = load_manifest(args.manifest)
        if args.seed:
            seeds = list(args.seed)
        else:
            if args.seed_count <= 0:
                raise SystemExit("--seed-count must be positive")
            seeds = ["%s-%02d" % (args.seed_prefix, index + 1) for index in range(args.seed_count)]
        result = audit_manual_caption_suite(
            data,
            artifacts_root=args.artifacts,
            seeds=seeds,
            count=args.count,
            excluded_sample_ids=args.exclude_sample_id,
        )
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        if args.out:
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(raw + "\n", encoding="utf-8")
            print(args.out)
        else:
            print(raw)
        if args.require_pass and not result["passes_all_seed_gates"]:
            raise SystemExit(
                "manual suite audit failed: passing_seed_count=%d seed_count=%d failing_seed_count=%d"
                % (
                    result["passing_seed_count"],
                    result["seed_count"],
                    result["failing_seed_count"],
                )
            )
        return

    if args.command == "completion-audit":
        data = load_manifest(args.manifest)
        selection = json.loads(Path(args.selection).read_text(encoding="utf-8"))
        audit = json.loads(Path(args.audit_json).read_text(encoding="utf-8")) if args.audit_json else None
        auto_qa = json.loads(Path(args.auto_qa_json).read_text(encoding="utf-8")) if args.auto_qa_json else None
        human_qa = json.loads(Path(args.human_qa_json).read_text(encoding="utf-8")) if args.human_qa_json else None
        if args.human_qa_report:
            markdown = Path(args.human_qa_report).read_text(encoding="utf-8")
            human_qa = summarize_qa_verdicts(
                markdown,
                required_language_groups=sorted({
                    str(item.get("suite_language") or item.get("language_group") or "")
                    for item in selection.get("selected", [])
                }),
                min_pass_per_group=args.min_pass_per_group,
                require_text_risk_notes=args.require_text_risk_notes,
            )
            human_qa["verdict_input_type"] = "markdown"
        result = build_completion_audit(
            data,
            selection,
            args.artifacts,
            audit=audit,
            auto_qa=auto_qa,
            human_qa=human_qa,
            expected_count=args.expected_count,
            min_accepted_ratio=args.min_accepted_ratio,
            min_pass_per_group=args.min_pass_per_group,
            require_text_risk_notes=args.require_text_risk_notes,
        )
        raw = json.dumps(result, ensure_ascii=False, indent=2)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw + "\n", encoding="utf-8")
        print(args.out)
        if args.require_complete and not result["goal_complete"]:
            raise SystemExit(
                "completion audit failed: machine_ready=%s human_verified=%s"
                % (result["machine_ready"], result["human_verified"])
            )
        if args.require_machine_ready and not result["machine_ready"]:
            raise SystemExit("machine evidence gate failed")
        return

    if args.command == "asr":
        payload = transcribe_file(
            args.audio,
            args.out,
            args.model,
            args.language,
            engine=args.engine,
            model_path=args.model_path,
            whisper_cli=args.whisper_cli,
            ffmpeg=args.ffmpeg,
            prompt=args.prompt,
            whisper_cpp_no_gpu=args.no_gpu,
        )
        print("words: %d" % len(payload["words"]))
        return

    if args.command == "vad":
        payload = vad_file(args.audio, args.out)
        print("segments: %d" % len(payload["segments"]))
        return

    if args.command == "vtt-words":
        payload = extract_vtt_words_file(args.vtt, args.out)
        print("words: %d" % len(payload["words"]))
        return

    if args.command == "srt-words":
        payload = extract_srt_words_file(args.srt, args.out)
        print("words: %d" % len(payload["words"]))
        return

    if args.command == "translation-proxy-srt":
        payload = write_translation_timing_proxy_file(args.source_srt, args.out, args.target_language)
        print("cues: %d" % payload["cue_count"])
        return

    if args.command == "metrics":
        report = evaluate_files(
            args.candidate,
            args.asr_words,
            args.sample_id,
            args.out,
            asr_offset_seconds=args.asr_offset_seconds,
            candidate_offset_seconds=args.candidate_offset_seconds,
            window_start=args.window_start_seconds,
            window_end=args.window_end_seconds,
            alignment_mode=args.alignment_mode,
            alignment_text_path=args.alignment_text_candidate,
        )
        print(json.dumps(report["summary"], ensure_ascii=False, indent=2))
        return

    if args.command == "reference-metrics":
        report = evaluate_reference_files(
            args.candidate,
            args.reference,
            args.sample_id,
            args.out,
            candidate_offset_seconds=args.candidate_offset_seconds,
            reference_offset_seconds=args.reference_offset_seconds,
            window_start=args.window_start_seconds,
            window_end=args.window_end_seconds,
        )
        print(json.dumps(report["summary"], ensure_ascii=False, indent=2))
        return

    if args.command == "compare":
        comparison = compare_report_files(
            args.baseline_report,
            args.optimized_report,
            args.out,
            language_group=args.language_group,
            gate_mode=args.gate_mode,
        )
        print(json.dumps({
            "sample_id": comparison["sample_id"],
            "language_group": comparison["language_group"],
            "baseline_passes": comparison["baseline"]["passes_timing_gate"],
            "optimized_passes": comparison["optimized"]["passes_timing_gate"],
            "delta": comparison["delta"],
        }, ensure_ascii=False, indent=2))
        return

    if args.command == "suite":
        required_language_groups = list(args.required_language_group)
        if args.require_manifest_coverage:
            data = load_manifest(args.manifest)
            required_language_groups.extend(data.get("coverage_goal", {}).get("required_language_groups", []))
        required_language_groups = sorted(set(required_language_groups))
        summary = summarize_suite_files(
            args.comparison,
            args.out,
            required_language_groups=required_language_groups,
        )
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return


if __name__ == "__main__":
    main()

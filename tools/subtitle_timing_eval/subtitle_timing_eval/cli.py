from __future__ import annotations

import argparse
import json
from pathlib import Path

from .pipeline import (
    build_suite_runbook,
    build_qa_packet,
    collect_eval_status,
    compare_report_files,
    evaluate_files,
    extract_srt_words_file,
    extract_vtt_words_file,
    load_manifest,
    materialize_existing_comparisons,
    prepare_sample,
    render_qa_review_html,
    render_qa_markdown,
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
    runbook.add_argument("--duration-seconds", type=float, help="Override manifest duration for smoke run commands.")
    runbook.add_argument("--out")

    status = sub.add_parser("status", help="Summarize current eval artifacts against manifest coverage.")
    status.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    status.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    status.add_argument("--out")
    status.add_argument("--require-sample-completion", action="store_true", help="Exit non-zero when any manifest sample is missing, failing, or externally blocked.")

    qa_report = sub.add_parser("qa-report", help="Write a Markdown side-by-side QA packet from current eval artifacts.")
    qa_report.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_report.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_report.add_argument("--out", required=True)
    qa_report.add_argument("--max-segments-per-group", type=int, default=8)

    qa_review = sub.add_parser("qa-review", help="Write a local HTML side-by-side review bundle for human subtitle timing QA.")
    qa_review.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_review.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    qa_review.add_argument("--out", required=True)
    qa_review.add_argument("--max-segments-per-group", type=int, default=8)

    qa_verdicts = sub.add_parser("qa-verdicts", help="Summarize human PASS/FAIL verdicts from a side-by-side QA packet.")
    qa_verdicts.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    qa_verdicts.add_argument("--qa-report", default="artifacts/subtitle_timing_eval/qa.side-by-side.md")
    qa_verdicts.add_argument("--review-json", help="JSON exported from qa-review HTML.")
    qa_verdicts.add_argument("--out")
    qa_verdicts.add_argument("--min-pass-per-group", type=int, default=2)
    qa_verdicts.add_argument("--required-language-group", action="append", default=[])
    qa_verdicts.add_argument("--require-pass", action="store_true", help="Exit non-zero when any required language group lacks enough PASS verdicts, has FAIL verdicts, or still has blank/unknown verdicts.")

    materialize = sub.add_parser("materialize-comparisons", help="Create comparison files from existing baseline/optimized report pairs.")
    materialize.add_argument("--manifest", default="tools/subtitle_timing_eval/samples.json")
    materialize.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    materialize.add_argument("--out")

    asr = sub.add_parser("asr", help="Run faster-whisper and write word timestamps JSON.")
    asr.add_argument("--audio", required=True)
    asr.add_argument("--out", required=True)
    asr.add_argument("--model", default="small")
    asr.add_argument("--language")

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
    metrics.add_argument("--window-start-seconds", type=float)
    metrics.add_argument("--window-end-seconds", type=float)
    metrics.add_argument("--alignment-mode", choices=["text", "overlap", "speech"], default="text")
    metrics.add_argument("--alignment-text-candidate", help="Subtitle file whose text should be used only for ASR alignment while scoring candidate cue times.")

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
        runbook_payload = build_suite_runbook(
            data,
            artifacts_root=args.artifacts,
            model=args.model,
            duration_override_seconds=args.duration_seconds,
            manifest_path=args.manifest,
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
        packet = build_qa_packet(data, args.artifacts, max_segments_per_group=args.max_segments_per_group)
        raw = render_qa_markdown(packet)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-review":
        data = load_manifest(args.manifest)
        packet = build_qa_packet(data, args.artifacts, max_segments_per_group=args.max_segments_per_group)
        raw = render_qa_review_html(packet, data, args.artifacts, args.out)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(raw, encoding="utf-8")
        print(args.out)
        return

    if args.command == "qa-verdicts":
        data = load_manifest(args.manifest)
        required_language_groups = list(data.get("coverage_goal", {}).get("required_language_groups", []))
        required_language_groups.extend(args.required_language_group)
        required_language_groups = sorted(set(required_language_groups))
        if args.review_json:
            review_payload = json.loads(Path(args.review_json).read_text(encoding="utf-8"))
            records = review_payload.get("reviews", review_payload if isinstance(review_payload, list) else [])
            summary = summarize_qa_verdict_records(
                records,
                required_language_groups=required_language_groups,
                min_pass_per_group=args.min_pass_per_group,
            )
        else:
            markdown = Path(args.qa_report).read_text(encoding="utf-8")
            summary = summarize_qa_verdicts(
                markdown,
                required_language_groups=required_language_groups,
                min_pass_per_group=args.min_pass_per_group,
            )
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

    if args.command == "asr":
        payload = transcribe_file(args.audio, args.out, args.model, args.language)
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
            window_start=args.window_start_seconds,
            window_end=args.window_end_seconds,
            alignment_mode=args.alignment_mode,
            alignment_text_path=args.alignment_text_candidate,
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

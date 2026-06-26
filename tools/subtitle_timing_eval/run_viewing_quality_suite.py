#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/subtitle_timing_eval"))

from subtitle_timing_eval.viewing_quality import (  # noqa: E402
    build_pipeline_advice,
    build_agent_translation_prompt,
    build_quality_judge_prompt,
    build_source_candidate_reports,
    build_quality_judge,
    build_viewing_sample_report,
    load_subtitle_cues,
    render_human_review,
    report_to_jsonable,
    source_quality_report,
)


DEFAULT_MODEL = Path.home() / "Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin"

DEFAULT_SAMPLES: List[Dict[str, Any]] = [
    {"id": "yoasobi-gunjou", "title": "YOASOBI - 群青 Official Music Video", "source": "https://www.youtube.com/watch?v=Y4nEEZwckuU", "category": "jpop_mv", "language": "ja"},
    {"id": "yoasobi-yasashii-suisei-live", "title": "YOASOBI - 優しい彗星 live", "source": "https://www.youtube.com/watch?v=sSmba3k5JZY", "category": "jpop_live", "language": "ja"},
    {"id": "yoasobi-yoru-ni-kakeru", "title": "YOASOBI - 夜に駆ける Official Music Video", "source": "ytsearch1:YOASOBI 夜に駆ける Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "yoasobi-idol", "title": "YOASOBI - アイドル Official Music Video", "source": "ytsearch1:YOASOBI アイドル Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "ado-usseewa", "title": "Ado - うっせぇわ", "source": "ytsearch1:Ado うっせぇわ Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "ado-new-genesis", "title": "Ado - 新時代", "source": "ytsearch1:Ado 新時代 Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "kenshi-yonezu-lemon", "title": "米津玄師 - Lemon", "source": "ytsearch1:米津玄師 Lemon MV", "category": "jpop_mv", "language": "ja"},
    {"id": "aimer-zankyosanka", "title": "Aimer - 残響散歌", "source": "ytsearch1:Aimer 残響散歌 MUSIC VIDEO", "category": "jpop_mv", "language": "ja"},
    {"id": "lisa-gurenge", "title": "LiSA - 紅蓮華", "source": "ytsearch1:LiSA 紅蓮華 MUSiC CLiP", "category": "jpop_mv", "language": "ja"},
    {"id": "king-gnu-hakujitsu", "title": "King Gnu - 白日", "source": "ytsearch1:King Gnu 白日 Official Video", "category": "jpop_mv", "language": "ja"},
    {"id": "koupen-chan-umeboshi", "title": "Koupen-chan episode 62", "source": "https://www.youtube.com/watch?v=q4Fgq49ivbA", "category": "japanese_anime", "language": "ja"},
    {"id": "koupen-chan-1-13", "title": "Koupen-chan episodes 1-13", "source": "https://www.youtube.com/watch?v=l5SmDtWczPM", "category": "japanese_anime", "language": "ja"},
    {"id": "koupen-chan-14-26", "title": "Koupen-chan episodes 14-26", "source": "https://www.youtube.com/watch?v=m7ofpXmAI5M", "category": "japanese_anime", "language": "ja"},
    {"id": "japanese-talk", "title": "Japanese talk manual captions", "source": "https://www.youtube.com/watch?v=SaalrFGgTIw", "category": "japanese_talk", "language": "ja"},
    {"id": "english-interview", "title": "Starship - Test Like You Fly", "source": "https://www.youtube.com/watch?v=ANe_HW4X8oc", "category": "english_interview", "language": "en"},
    {"id": "english-lecture", "title": "TED: Do schools kill creativity", "source": "https://www.youtube.com/watch?v=iG9CE55wbtY", "category": "english_lecture", "language": "en"},
    {"id": "english-tutorial", "title": "TEDx: The first 20 hours", "source": "https://www.youtube.com/watch?v=5MgBikgcWnY", "category": "english_tutorial", "language": "en"},
    {"id": "english-vlog", "title": "Me at the zoo", "source": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "category": "english_vlog", "language": "en", "review_seconds": 18.0},
    {"id": "chinese-song", "title": "Chinese song lyrics", "source": "ytsearch1:中文 歌曲 歌词 字幕 official MV", "category": "chinese_music", "language": "zh"},
    {"id": "chinese-animation", "title": "Chinese animation", "source": "ytsearch1:国创 动画 中文配音 字幕", "category": "chinese_animation", "language": "zh"},
    {"id": "cantonese-talk", "title": "Cantonese talk", "source": "https://www.youtube.com/watch?v=oc0uynThYDQ", "category": "cantonese_talk", "language": "yue"},
    {"id": "korean-music", "title": "Korean MV", "source": "ytsearch1:Korean official MV lyrics", "category": "korean_music", "language": "ko"},
    {"id": "korean-talk", "title": "Korean talk", "source": "https://www.youtube.com/watch?v=TBlTBDbpu2M", "category": "korean_talk", "language": "ko"},
    {"id": "korean-auto", "title": "Korean auto captions", "source": "https://www.youtube.com/watch?v=C4Vxt492DAc", "category": "korean_auto", "language": "ko"},
    {"id": "spanish-talk", "title": "Spanish talk", "source": "ytsearch1:charla español subtítulos TEDx", "category": "spanish_talk", "language": "es"},
    {"id": "french-talk", "title": "French talk", "source": "ytsearch1:conférence français sous titres TEDx", "category": "french_talk", "language": "fr"},
    {"id": "italian-talk", "title": "Italian talk", "source": "ytsearch1:conferenza italiano sottotitoli TEDx", "category": "italian_talk", "language": "it"},
    {"id": "short-social", "title": "Short social clip", "source": "ytsearch1:YouTube shorts subtitles funny", "category": "short_social", "language": "en"},
    {"id": "gaming-entertainment", "title": "Gaming entertainment", "source": "ytsearch1:gaming commentary subtitles", "category": "gaming", "language": "en"},
    {"id": "documentary-news", "title": "Documentary or news explainer", "source": "ytsearch1:documentary explainer subtitles", "category": "documentary_news", "language": "en"},
]

SONG_CATEGORY_GOAL: Dict[str, int] = {
    "jpop_mv": 8,
    "jpop_live": 4,
    "anime_game_song": 4,
    "kpop_music": 4,
    "chinese_yue_music": 4,
    "english_music": 3,
    "romance_music": 3,
}

SONG_SAMPLES: List[Dict[str, Any]] = [
    {"id": "yoasobi-gunjou", "title": "YOASOBI - 群青 Official Music Video", "source": "https://www.youtube.com/watch?v=Y4nEEZwckuU", "category": "jpop_mv", "language": "ja"},
    {"id": "yoasobi-yoru-ni-kakeru", "title": "YOASOBI - 夜に駆ける Official Music Video", "source": "ytsearch1:YOASOBI 夜に駆ける Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "yoasobi-idol", "title": "YOASOBI - アイドル Official Music Video", "source": "ytsearch1:YOASOBI アイドル Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "ado-usseewa", "title": "Ado - うっせぇわ Official Music Video", "source": "ytsearch1:Ado うっせぇわ Official Music Video", "category": "jpop_mv", "language": "ja"},
    {"id": "lisa-gurenge", "title": "LiSA - 紅蓮華", "source": "ytsearch1:LiSA 紅蓮華 MUSiC CLiP", "category": "jpop_mv", "language": "ja"},
    {"id": "kenshi-yonezu-lemon", "title": "米津玄師 - Lemon", "source": "ytsearch1:米津玄師 Lemon MV", "category": "jpop_mv", "language": "ja"},
    {"id": "aimer-zankyosanka", "title": "Aimer - 残響散歌", "source": "ytsearch1:Aimer 残響散歌 MUSIC VIDEO", "category": "jpop_mv", "language": "ja"},
    {"id": "king-gnu-hakujitsu", "title": "King Gnu - 白日", "source": "ytsearch1:King Gnu 白日 Official Video", "category": "jpop_mv", "language": "ja"},
    {"id": "yoasobi-yasashii-suisei-live", "title": "YOASOBI - 優しい彗星 live", "source": "https://www.youtube.com/watch?v=sSmba3k5JZY", "category": "jpop_live", "language": "ja"},
    {"id": "yoasobi-gunjou-live", "title": "YOASOBI - 群青 live", "source": "ytsearch1:YOASOBI 群青 live", "category": "jpop_live", "language": "ja"},
    {"id": "ado-usseewa-live", "title": "Ado - うっせぇわ live", "source": "ytsearch1:Ado うっせぇわ live", "category": "jpop_live", "language": "ja"},
    {"id": "kenshi-yonezu-live", "title": "米津玄師 live performance", "source": "ytsearch1:米津玄師 live Lemon", "category": "jpop_live", "language": "ja"},
    {"id": "eve-kaikai-kitan", "title": "Eve - 廻廻奇譚", "source": "ytsearch1:Eve 廻廻奇譚 official music video", "category": "anime_game_song", "language": "ja"},
    {"id": "higedan-cry-baby", "title": "Official髭男dism - Cry Baby", "source": "ytsearch1:Official髭男dism Cry Baby official video", "category": "anime_game_song", "language": "ja"},
    {"id": "radwimps-suzume", "title": "RADWIMPS - すずめ feat. 十明", "source": "ytsearch1:RADWIMPS すずめ feat 十明 official music video", "category": "anime_game_song", "language": "ja"},
    {"id": "kessoku-band-guitar", "title": "結束バンド - ギターと孤独と蒼い惑星", "source": "ytsearch1:結束バンド ギターと孤独と蒼い惑星 official", "category": "anime_game_song", "language": "ja"},
    {"id": "bts-dynamite", "title": "BTS - Dynamite", "source": "ytsearch1:BTS Dynamite official MV", "category": "kpop_music", "language": "en"},
    {"id": "blackpink-ddu-du", "title": "BLACKPINK - DDU-DU DDU-DU", "source": "ytsearch1:BLACKPINK DDU-DU DDU-DU official MV", "category": "kpop_music", "language": "ko"},
    {"id": "newjeans-omg", "title": "NewJeans - OMG", "source": "ytsearch1:NewJeans OMG official MV", "category": "kpop_music", "language": "ko"},
    {"id": "ive-i-am", "title": "IVE - I AM", "source": "ytsearch1:IVE I AM official MV", "category": "kpop_music", "language": "ko"},
    {"id": "jay-chou-blue-white-porcelain", "title": "周杰伦 - 青花瓷", "source": "ytsearch1:周杰伦 青花瓷 官方 MV", "category": "chinese_yue_music", "language": "zh"},
    {"id": "gem-light-years-away", "title": "G.E.M. - 光年之外", "source": "ytsearch1:G.E.M. 光年之外 官方 MV", "category": "chinese_yue_music", "language": "zh"},
    {"id": "mayday-stubborn", "title": "五月天 - 倔强", "source": "ytsearch1:五月天 倔强 官方 MV", "category": "chinese_yue_music", "language": "zh"},
    {"id": "eason-chan-exaggerated", "title": "陈奕迅 - 浮夸", "source": "ytsearch1:陈奕迅 浮夸 官方 MV", "category": "chinese_yue_music", "language": "yue"},
    {"id": "taylor-swift-anti-hero", "title": "Taylor Swift - Anti-Hero", "source": "ytsearch1:Taylor Swift Anti-Hero official music video", "category": "english_music", "language": "en"},
    {"id": "billie-eilish-birds", "title": "Billie Eilish - BIRDS OF A FEATHER", "source": "ytsearch1:Billie Eilish BIRDS OF A FEATHER official music video", "category": "english_music", "language": "en"},
    {"id": "adele-hello", "title": "Adele - Hello", "source": "ytsearch1:Adele Hello official music video", "category": "english_music", "language": "en"},
    {"id": "stromae-papaoutai", "title": "Stromae - Papaoutai", "source": "ytsearch1:Stromae Papaoutai official video", "category": "romance_music", "language": "fr"},
    {"id": "rosalia-despecha", "title": "ROSALIA - DESPECHA", "source": "ytsearch1:ROSALIA DESPECHA official video", "category": "romance_music", "language": "es"},
    {"id": "laura-pausini-la-solitudine", "title": "Laura Pausini - La Solitudine", "source": "ytsearch1:Laura Pausini La Solitudine official video", "category": "romance_music", "language": "it"},
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate user-visible subtitle quality review artifacts.")
    parser.add_argument("--artifacts", default="artifacts/subtitle_timing_eval/viewing_quality")
    parser.add_argument("--suite", choices=["default", "songs30"], default="default")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--sample-id", action="append", default=[])
    parser.add_argument("--download-subtitles", action="store_true")
    parser.add_argument("--yt-dlp", default="yt-dlp")
    parser.add_argument("--cookies", type=Path, help="Netscape cookies.txt copied to a temp file before yt-dlp uses it.")
    parser.add_argument("--cookies-from-browser")
    parser.add_argument("--local-asr-fallback", action="store_true", help="Generate a local-ASR source when the platform subtitle is missing or rejected.")
    parser.add_argument("--force-local-asr", action="store_true", help="Generate local-ASR artifacts even when the platform subtitle passes the quality gate.")
    parser.add_argument("--model-path", type=Path, default=DEFAULT_MODEL, help="whisper.cpp ggml model used for local-ASR fallback.")
    parser.add_argument("--whisper-cli", default="whisper-cli")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--no-gpu", action="store_true", help="Pass --no-gpu to whisper.cpp fallback.")
    parser.add_argument("--swift-scratch-path", type=Path, default=ROOT / ".build/codex-viewing-quality-cli")
    parser.add_argument("--fallback-duration-seconds", type=float, default=180.0)
    parser.add_argument("--preview-seconds", type=float, default=180.0, help="Default user-visible review window per sample.")
    parser.add_argument("--refresh-local-asr", action="store_true")
    parser.add_argument("--refresh-local-asr-srt", action="store_true", help="Regenerate local-ASR SRTs from existing word/silence artifacts without rerunning Whisper.")
    parser.add_argument("--translate-final", action="store_true", help="Translate the selected final source with moongate-cli and store translated.srt.")
    parser.add_argument("--translation-style", default="zh", help="moongate-cli translate --style value used with --translate-final.")
    parser.add_argument("--write-agent-llm-prompts", action="store_true", help="Write subagent-ready translation prompts for the selected final source.")
    parser.add_argument("--gunjou-source")
    parser.add_argument("--gunjou-translated")
    args = parser.parse_args()

    cookies_copy: Optional[Path] = None
    if args.cookies is not None:
        if not args.cookies.is_file():
            raise SystemExit(f"cookies file not found: {args.cookies}")
        fd, temp_name = tempfile.mkstemp(prefix="moongate-viewing-quality-cookies-", suffix=".txt")
        os.close(fd)
        Path(temp_name).unlink(missing_ok=True)
        cookies_copy = Path(temp_name)
        shutil.copyfile(args.cookies, cookies_copy)
        atexit.register(lambda path: path.exists() and path.unlink(), cookies_copy)

    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    sample_pool = SONG_SAMPLES if args.suite == "songs30" else DEFAULT_SAMPLES
    samples = [s for s in sample_pool if not args.sample_id or s["id"] in set(args.sample_id)]
    if args.limit is not None:
        samples = samples[: args.limit]

    reports = []
    agent_quality_judges: Dict[str, Dict[str, Any]] = {}
    invalid_agent_quality_judges: List[str] = []
    for sample in samples:
        sample_dir = artifacts / sample["id"]
        sample_dir.mkdir(parents=True, exist_ok=True)
        source_path: Optional[Path] = None
        local_asr_path: Optional[Path] = None
        translated_path: Optional[Path] = None
        translation_attempted = False
        preview_seconds = float(sample.get("review_seconds", args.preview_seconds))

        if sample["id"] == "yoasobi-gunjou" and args.gunjou_source:
            source_path = copy_artifact(Path(args.gunjou_source), sample_dir / ("source" + Path(args.gunjou_source).suffix))
        if sample["id"] == "yoasobi-gunjou" and args.gunjou_translated:
            translated_path = copy_artifact(Path(args.gunjou_translated), sample_dir / ("translated" + Path(args.gunjou_translated).suffix))

        if source_path is None and args.download_subtitles:
            source_path = download_subtitle_candidate(args, sample, sample_dir, cookies_copy)
        if source_path is None:
            source_path = find_existing_subtitle_candidate(sample, sample_dir)

        source_needed_fallback = platform_source_needs_fallback(source_path, sample)
        local_asr_attempted = False
        if args.local_asr_fallback and (source_needed_fallback or args.force_local_asr):
            local_asr_attempted = True
            local_asr_path = generate_local_asr_source(args, sample, sample_dir, cookies_copy)
        if local_asr_path is None:
            local_asr_path = find_existing_local_asr_source(sample, sample_dir)
        if translated_path is None:
            translated_path = find_existing_translated_candidate(sample_dir)

        report = build_viewing_sample_report(
            sample_id=sample["id"],
            title=sample["title"],
            category=sample["category"],
            source_path=source_path,
            local_asr_path=local_asr_path,
            translated_path=translated_path,
            source_language_code=sample["language"],
            target_language_code="zh-Hans",
            preview_seconds=preview_seconds,
        )
        if args.translate_final and translated_path is None and report.final_source_path:
            translation_attempted = True
            translated_path = translate_final_source(args, Path(report.final_source_path), sample_dir)
            report = build_viewing_sample_report(
                sample_id=sample["id"],
                title=sample["title"],
                category=sample["category"],
                source_path=source_path,
                local_asr_path=local_asr_path,
                translated_path=translated_path,
                source_language_code=sample["language"],
                target_language_code="zh-Hans",
                preview_seconds=preview_seconds,
                translation_attempted=translation_attempted,
            )
        (sample_dir / "source_report.json").write_text(
            json.dumps(report_to_jsonable(report), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        pipeline_advice = build_pipeline_advice(
            sample=sample,
            report=report,
            source_needed_fallback=source_needed_fallback,
            local_asr_attempted=local_asr_attempted,
            local_asr_available=local_asr_path is not None,
        )
        (sample_dir / "pipeline_advice.json").write_text(
            json.dumps(pipeline_advice, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (sample_dir / "source_candidates.json").write_text(
            json.dumps(build_source_candidate_reports(report), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (sample_dir / "llm_quality_judge.json").write_text(
            json.dumps(build_quality_judge(report), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (sample_dir / "llm_quality_judge.prompt.txt").write_text(
            build_quality_judge_prompt(report),
            encoding="utf-8",
        )
        if args.write_agent_llm_prompts:
            (sample_dir / "agent_translation.prompt.md").write_text(
                build_agent_translation_prompt(report, target_language_code="zh-Hans"),
                encoding="utf-8",
            )
        agent_judge, agent_judge_error = load_agent_quality_judge(sample_dir)
        if agent_judge is not None:
            agent_quality_judges[sample["id"]] = agent_judge
        elif agent_judge_error is not None:
            invalid_agent_quality_judges.append(sample["id"])
        reports.append(report)

    category_counts = sample_category_counts(samples)
    summary_goal = SONG_CATEGORY_GOAL if args.suite == "songs30" else {}
    (artifacts / "samples.manifest.json").write_text(
        json.dumps({
            "suite": args.suite,
            "category_goal": summary_goal,
            "category_counts": category_counts,
            "samples": samples,
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (artifacts / "human_review.md").write_text(render_human_review(reports), encoding="utf-8")
    summary = {
        "sample_count": len(reports),
        "blocking_count": sum(1 for report in reports if report.blocking_issue_count),
        "blocked_samples": [report.sample_id for report in reports if report.blocking_issue_count],
        "fallback_count": sum(1 for report in reports if report.fallback_used),
        "fallback_samples": [report.sample_id for report in reports if report.fallback_used],
        "missing_final_source_samples": [report.sample_id for report in reports if report.final_source_kind == "missing"],
        "category_counts": category_counts,
        "missing_song_categories": missing_song_categories(category_counts) if args.suite == "songs30" else [],
    }
    summary.update(summarize_agent_quality_judges(agent_quality_judges, invalid_agent_quality_judges))
    (artifacts / "suite.summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def copy_artifact(source: Path, destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return destination


def sample_category_counts(samples: List[Dict[str, Any]]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for sample in samples:
        category = str(sample.get("category") or "unknown")
        counts[category] = counts.get(category, 0) + 1
    return dict(sorted(counts.items()))


def missing_song_categories(category_counts: Dict[str, int]) -> List[str]:
    missing: List[str] = []
    for category, required in SONG_CATEGORY_GOAL.items():
        if category_counts.get(category, 0) < required:
            missing.append(category)
    return missing


def load_agent_quality_judge(sample_dir: Path) -> tuple[Optional[Dict[str, Any]], Optional[str]]:
    path = sample_dir / "agent_quality_judge.json"
    if not path.is_file():
        return None, None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)
    if not isinstance(payload, dict) or not isinstance(payload.get("pass"), bool):
        return None, "invalid agent quality judge shape"
    return payload, None


def summarize_agent_quality_judges(
    judges: Dict[str, Dict[str, Any]],
    invalid_samples: Optional[List[str]] = None,
) -> Dict[str, Any]:
    invalid_samples = invalid_samples or []
    blocking_samples: List[str] = []
    minor_samples: List[str] = []
    pass_samples: List[str] = []
    for sample_id, judge in sorted(judges.items()):
        blocking = judge.get("blockingIssues") or []
        minor = judge.get("minorIssues") or []
        if blocking:
            blocking_samples.append(sample_id)
        if minor:
            minor_samples.append(sample_id)
        if judge.get("pass") is True and not blocking:
            pass_samples.append(sample_id)
    return {
        "agent_quality_judge_count": len(judges),
        "agent_quality_pass_count": len(pass_samples),
        "agent_quality_pass_samples": pass_samples,
        "agent_quality_blocking_samples": blocking_samples,
        "agent_quality_minor_samples": minor_samples,
        "agent_quality_invalid_samples": sorted(invalid_samples),
    }


def download_subtitle_candidate(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    cookies: Optional[Path],
) -> Optional[Path]:
    output = sample_dir / "%(id)s.%(ext)s"
    command = [
        args.yt_dlp,
        "--skip-download",
        "--no-playlist",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs",
        sample["language"],
        "--sub-format",
        "vtt/srt/best",
        "-o",
        str(output),
        sample["source"],
    ]
    if cookies is not None:
        command[3:3] = ["--cookies", str(cookies)]
    if args.cookies_from_browser:
        command[3:3] = ["--cookies-from-browser", args.cookies_from_browser]
    try:
        subprocess.run(command, cwd=str(ROOT), check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    candidates = [
        path for path in (
            sorted(sample_dir.glob(f"*.{sample['language']}*.vtt"))
            + sorted(sample_dir.glob(f"*.{sample['language']}*.srt"))
        )
        if "local-asr" not in path.name
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def find_existing_subtitle_candidate(sample: Dict[str, Any], sample_dir: Path) -> Optional[Path]:
    language = str(sample.get("language") or "")
    patterns = [f"*.{language}*.vtt", f"*.{language}*.srt"] if language else ["*.vtt", "*.srt"]
    candidates: List[Path] = []
    for pattern in patterns:
        candidates.extend(sorted(sample_dir.glob(pattern)))
    candidates = [
        path for path in candidates
        if path.is_file()
        and "local-asr" not in path.name
        and path.name != "translated.srt"
    ]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_existing_local_asr_source(sample: Dict[str, Any], sample_dir: Path) -> Optional[Path]:
    language = str(sample.get("language") or "")
    patterns = [
        f"local-asr.{language}.srt",
        f"*.local-asr.{language}.srt",
        "local-asr*.srt",
        "*.local-asr.*.srt",
    ] if language else ["local-asr*.srt", "*.local-asr.*.srt"]
    candidates: List[Path] = []
    for pattern in patterns:
        candidates.extend(sorted(sample_dir.glob(pattern)))
    candidates = [
        path for path in dict.fromkeys(candidates)
        if path.is_file() and path.stat().st_size > 0
    ]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def find_existing_translated_candidate(sample_dir: Path) -> Optional[Path]:
    candidates = [
        path for path in [
            sample_dir / "translated.srt",
            sample_dir / "translated.zh-Hans.srt",
            sample_dir / "translated.zh.srt",
        ]
        if path.is_file() and path.stat().st_size > 0
    ]
    if not candidates:
        candidates = [
            path for path in sorted(sample_dir.glob("*zh-Hans*.srt")) + sorted(sample_dir.glob("*zh*.srt"))
            if path.is_file() and path.stat().st_size > 0 and "local-asr" not in path.name
        ]
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def platform_source_needs_fallback(source_path: Optional[Path], sample: Dict[str, Any]) -> bool:
    if source_path is None:
        return True
    try:
        cues = load_subtitle_cues(source_path)
    except OSError:
        return True
    report = source_quality_report(
        cues,
        requested_language_code=sample["language"],
        subtitle_language_code=sample["language"],
    )
    return not report.usable


def generate_local_asr_source(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    cookies: Optional[Path],
) -> Optional[Path]:
    if not args.model_path.is_file():
        print(f"[local-asr skipped] model not found for {sample['id']}: {args.model_path}", file=sys.stderr)
        return None

    srt_path = sample_dir / f"local-asr.{sample['language']}.srt"
    words_path = sample_dir / "local-asr.words.json"
    if args.refresh_local_asr:
        for path in [srt_path, words_path, sample_dir / "local-asr.wav", sample_dir / "local-asr.silencedetect.log"]:
            path.unlink(missing_ok=True)
    elif args.refresh_local_asr_srt:
        srt_path.unlink(missing_ok=True)
        silencedetect_log = sample_dir / "local-asr.silencedetect.log"
        if words_path.is_file() and words_path.stat().st_size > 0:
            return run_moongate_local_asr_srt(
                args,
                sample,
                sample_dir,
                words_path,
                srt_path,
                silencedetect_log if silencedetect_log.is_file() else None,
            )
    if srt_path.exists() and srt_path.stat().st_size > 0:
        return srt_path

    try:
        audio_path = download_audio_for_local_asr(args, sample, sample_dir, cookies)
        wav_path = clip_audio_for_local_asr(args, sample, sample_dir, audio_path)
        words = run_whisper_cpp_for_local_asr(args, sample, sample_dir, wav_path, words_path)
        silencedetect_log = run_silencedetect_for_local_asr(args, sample_dir, wav_path)
        return run_moongate_local_asr_srt(args, sample, sample_dir, words, srt_path, silencedetect_log)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"[local-asr failed] {sample['id']}: {exc}", file=sys.stderr)
        return None


def download_audio_for_local_asr(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    cookies: Optional[Path],
) -> Path:
    media_dir = sample_dir / "local-asr-media"
    media_dir.mkdir(parents=True, exist_ok=True)
    existing = [
        path for path in sorted(media_dir.iterdir())
        if path.is_file() and path.suffix.lower() not in {".json", ".part", ".temp"}
    ]
    if existing:
        return existing[0]

    command = [
        args.yt_dlp,
        "--no-playlist",
        "-f",
        "bestaudio/best",
        "-o",
        str(media_dir / "%(id)s.%(ext)s"),
        sample["source"],
    ]
    if cookies is not None:
        command[2:2] = ["--cookies", str(cookies)]
    if args.cookies_from_browser:
        command[2:2] = ["--cookies-from-browser", args.cookies_from_browser]
    subprocess.run(command, cwd=str(ROOT), check=True)

    files = [
        path for path in sorted(media_dir.iterdir())
        if path.is_file() and path.suffix.lower() not in {".json", ".part", ".temp"}
    ]
    if not files:
        raise RuntimeError("yt-dlp did not create an audio file")
    return files[0]


def clip_audio_for_local_asr(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    audio_path: Path,
) -> Path:
    wav_path = sample_dir / "local-asr.wav"
    if wav_path.exists() and wav_path.stat().st_size > 0:
        return wav_path
    subprocess.run(
        [
            args.ffmpeg,
            "-y",
            "-i",
            str(audio_path),
            "-t",
            f"{max(30.0, args.fallback_duration_seconds):.3f}",
            "-vn",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(wav_path),
        ],
        cwd=str(ROOT),
        check=True,
    )
    return wav_path


def run_whisper_cpp_for_local_asr(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    wav_path: Path,
    words_path: Path,
) -> Path:
    if words_path.exists() and words_path.stat().st_size > 0:
        return words_path
    command = [
        sys.executable,
        "-m",
        "subtitle_timing_eval.cli",
        "asr",
        "--audio",
        str(wav_path),
        "--out",
        str(words_path),
        "--engine",
        "whisper-cpp",
        "--model-path",
        str(args.model_path),
        "--whisper-cli",
        args.whisper_cli,
        "--ffmpeg",
        args.ffmpeg,
        "--language",
        whisper_language_code(sample["language"]),
        "--prompt",
        sample["title"],
    ]
    if should_disable_whisper_context(sample):
        command.extend(["--max-context", "0"])
    if args.no_gpu:
        command.append("--no-gpu")
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT / "tools/subtitle_timing_eval")
    subprocess.run(command, cwd=str(ROOT), env=env, check=True)
    return words_path


def run_silencedetect_for_local_asr(
    args: argparse.Namespace,
    sample_dir: Path,
    wav_path: Path,
) -> Path:
    log_path = sample_dir / "local-asr.silencedetect.log"
    if log_path.exists() and log_path.stat().st_size > 0:
        return log_path
    result = subprocess.run(
        [
            args.ffmpeg,
            "-hide_banner",
            "-nostats",
            "-i",
            str(wav_path),
            "-af",
            "silencedetect=noise=-35dB:d=0.2",
            "-f",
            "null",
            "-",
        ],
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        check=True,
    )
    log_path.write_text((result.stdout or "") + "\n" + (result.stderr or ""), encoding="utf-8")
    return log_path


def run_moongate_local_asr_srt(
    args: argparse.Namespace,
    sample: Dict[str, Any],
    sample_dir: Path,
    words_path: Path,
    srt_path: Path,
    silencedetect_log: Optional[Path] = None,
) -> Path:
    if srt_path.exists() and srt_path.stat().st_size > 0:
        return srt_path
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build/codex-module-cache-viewing-quality")
    subprocess.run(
        [
            "swift",
            "run",
            "--package-path",
            str(ROOT),
            "--scratch-path",
            str(args.swift_scratch_path),
            "--disable-sandbox",
            "moongate-cli",
            "local-asr-srt",
            "--asr-words",
            str(words_path),
            "--language",
            sample["language"],
            "--file-name",
            sample["title"],
            "--out",
            str(srt_path),
            "--timing-profile",
            sample_timing_profile(sample),
        ] + (["--silencedetect-log", str(silencedetect_log)] if silencedetect_log else []),
        cwd=str(ROOT),
        env=env,
        check=True,
    )
    return srt_path


def translate_final_source(args: argparse.Namespace, source_srt: Path, sample_dir: Path) -> Optional[Path]:
    translated = sample_dir / "translated.srt"
    if translated.exists() and translated.stat().st_size > 0:
        return translated
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build/codex-module-cache-viewing-quality")
    result = subprocess.run(
        [
            "swift",
            "run",
            "--package-path",
            str(ROOT),
            "--scratch-path",
            str(args.swift_scratch_path),
            "--disable-sandbox",
            "moongate-cli",
            "translate",
            str(source_srt),
            "--style",
            args.translation_style,
        ],
        cwd=str(ROOT),
        env=env,
        text=True,
        capture_output=True,
    )
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    if result.returncode != 0:
        print(f"[translate failed] {source_srt}: {output.strip()}", file=sys.stderr)
        return None
    translated_path = parse_translated_path_from_cli_output(output)
    if translated_path is None or not translated_path.is_file():
        print(f"[translate failed] translated path not found in moongate-cli output for {source_srt}", file=sys.stderr)
        return None
    return copy_artifact(translated_path, translated)


def parse_translated_path_from_cli_output(output: str) -> Optional[Path]:
    for line in output.splitlines():
        marker = "译文文件："
        if marker in line:
            value = line.split(marker, 1)[1].strip()
            if value:
                return Path(value)
    return None


def whisper_language_code(language: str) -> str:
    normalized = language.lower()
    if normalized in {"yue", "cmn"}:
        return "zh"
    return normalized


def should_disable_whisper_context(sample: Dict[str, Any]) -> bool:
    language = sample["language"].lower()
    category = sample["category"].lower()
    music_like = any(token in category for token in ["music", "song", "jpop", "mv", "live"])
    return language in {"ja", "zh", "yue", "ko"} and music_like


def sample_timing_profile(sample: Dict[str, Any]) -> str:
    language = sample["language"].lower()
    category = sample["category"].lower()
    music_like = any(token in category for token in ["music", "song", "jpop", "mv", "live"])
    anime_like = "anime" in category or "animation" in category
    if music_like and language == "ja":
        return "japaneseLyrics"
    if music_like:
        return "lyrics"
    if anime_like:
        return "anime"
    return "speech"


if __name__ == "__main__":
    main()

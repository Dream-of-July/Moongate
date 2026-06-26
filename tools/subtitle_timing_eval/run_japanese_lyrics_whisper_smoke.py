#!/usr/bin/env python3
from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ARTIFACTS = ROOT / "artifacts" / "subtitle_timing_eval" / "japanese_lyrics_whisper_smoke"
DEFAULT_MODEL = Path.home() / "Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin"


@dataclass(frozen=True)
class Sample:
    id: str
    title: str
    source: str
    start: float
    duration: float


SAMPLES: list[Sample] = [
    Sample("yoasobi-gunjou", "YOASOBI - 群青 Official Music Video", "ytsearch1:YOASOBI 群青 Official Music Video", 0, 130),
    Sample("yoasobi-yasashii-suisei-live", "YOASOBI - 優しい彗星 live", "ytsearch1:YOASOBI 優しい彗星 NICE TO MEET YOU 日本武道館", 105, 140),
    Sample("yoasobi-yoru-ni-kakeru", "YOASOBI - 夜に駆ける Official Music Video", "ytsearch1:YOASOBI 夜に駆ける Official Music Video", 0, 130),
    Sample("yoasobi-idol", "YOASOBI - アイドル Official Music Video", "ytsearch1:YOASOBI アイドル Official Music Video", 0, 130),
    Sample("ado-usseewa", "Ado - うっせぇわ", "ytsearch1:Ado うっせぇわ Official Music Video", 0, 130),
    Sample("ado-new-genesis", "Ado - 新時代", "ytsearch1:Ado 新時代 Official Music Video", 0, 130),
    Sample("kenshi-yonezu-lemon", "米津玄師 - Lemon", "ytsearch1:米津玄師 Lemon MV", 0, 130),
    Sample("kenshi-yonezu-kanden", "米津玄師 - 感電", "ytsearch1:米津玄師 感電 MV", 0, 130),
    Sample("aimer-zankyosanka", "Aimer - 残響散歌", "ytsearch1:Aimer 残響散歌 MUSIC VIDEO", 0, 130),
    Sample("lisa-gurenge", "LiSA - 紅蓮華", "ytsearch1:LiSA 紅蓮華 MUSiC CLiP", 0, 130),
    Sample("eve-kaikai-kitan", "Eve - 廻廻奇譚", "ytsearch1:Eve 廻廻奇譚 Music Video", 0, 130),
    Sample("higedan-pretender", "Official髭男dism - Pretender", "ytsearch1:Official髭男dism Pretender Official Video", 0, 130),
    Sample("king-gnu-hakujitsu", "King Gnu - 白日", "ytsearch1:King Gnu 白日 Official Video", 0, 130),
    Sample("aimyon-marigold", "あいみょん - マリーゴールド", "ytsearch1:あいみょん マリーゴールド Official Video", 0, 130),
    Sample("fuji-kaze-shinunoga-e-wa", "藤井風 - 死ぬのがいいわ", "ytsearch1:藤井風 死ぬのがいいわ Official Video", 0, 130),
    Sample("mrs-green-apple-inferno", "Mrs. GREEN APPLE - インフェルノ", "ytsearch1:Mrs. GREEN APPLE インフェルノ Official Music Video", 0, 130),
    Sample("vaundy-kaiju-no-hanauta", "Vaundy - 怪獣の花唄", "ytsearch1:Vaundy 怪獣の花唄 Official Music Video", 0, 130),
    Sample("back-number-christmas-song", "back number - クリスマスソング", "ytsearch1:back number クリスマスソング official music video", 0, 130),
    Sample("radwimps-zenzenzense", "RADWIMPS - 前前前世", "ytsearch1:RADWIMPS 前前前世 movie ver Official Music Video", 0, 130),
    Sample("bump-souvenir", "BUMP OF CHICKEN - SOUVENIR", "ytsearch1:BUMP OF CHICKEN SOUVENIR Official Music Video", 0, 130),
]


@dataclass
class Cue:
    index: int
    start: float
    end: float
    text: str

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


def run(cmd: list[str], cwd: Path = ROOT, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(cmd, cwd=str(cwd), env=merged_env, text=True, check=True)


def capture(cmd: list[str], cwd: Path = ROOT) -> str:
    return subprocess.check_output(cmd, cwd=str(cwd), text=True).strip()


def slug_path(path: Path) -> str:
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def ytdlp_auth_args(cookies: Path | None, cookies_from_browser: str | None) -> list[str]:
    args: list[str] = []
    if cookies is not None:
        args.extend(["--cookies", str(cookies)])
    if cookies_from_browser:
        args.extend(["--cookies-from-browser", cookies_from_browser])
    return args


def resolve_source(
    sample: Sample,
    cookies: Path | None,
    cookies_from_browser: str | None,
) -> dict[str, str]:
    template = "%(id)s\t%(title)s\t%(webpage_url)s\t%(duration)s"
    raw = capture([
        "yt-dlp",
        "--no-playlist",
        *ytdlp_auth_args(cookies, cookies_from_browser),
        "--print",
        template,
        sample.source,
    ])
    first = raw.splitlines()[0]
    parts = first.split("\t")
    while len(parts) < 4:
        parts.append("")
    return {
        "video_id": parts[0],
        "title": parts[1],
        "url": parts[2],
        "duration": parts[3],
    }


def download_audio(
    sample: Sample,
    resolved: dict[str, str],
    sample_dir: Path,
    cookies: Path | None,
    cookies_from_browser: str | None,
) -> Path:
    raw_dir = sample_dir / "source"
    raw_dir.mkdir(parents=True, exist_ok=True)
    marker = raw_dir / "download.json"
    existing = sorted(p for p in raw_dir.iterdir() if p.is_file() and p.name != marker.name)
    if existing:
        return existing[0]
    out = raw_dir / "%(id)s.%(ext)s"
    run([
        "yt-dlp",
        "--no-playlist",
        *ytdlp_auth_args(cookies, cookies_from_browser),
        "-f",
        "bestaudio/best",
        "-o",
        str(out),
        resolved["url"] or sample.source,
    ])
    files = sorted(p for p in raw_dir.iterdir() if p.is_file() and p.name != marker.name)
    if not files:
        raise RuntimeError("yt-dlp did not create an audio file")
    marker.write_text(json.dumps(resolved, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return files[0]


def clip_audio(source: Path, sample: Sample, sample_dir: Path, ffmpeg: str) -> Path:
    wav = sample_dir / "clip.wav"
    if wav.exists() and wav.stat().st_size > 0:
        return wav
    run([
        ffmpeg,
        "-y",
        "-ss",
        f"{sample.start:.3f}",
        "-i",
        str(source),
        "-t",
        f"{sample.duration:.3f}",
        "-vn",
        "-ar",
        "16000",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        str(wav),
    ])
    return wav


def run_asr(
    wav: Path,
    sample_dir: Path,
    model_path: Path,
    whisper_cli: str,
    ffmpeg: str,
    no_gpu: bool,
) -> Path:
    words = sample_dir / "asr_words.whisper-cpp.json"
    if words.exists() and words.stat().st_size > 0:
        return words
    cmd = [
        sys.executable,
        "-m",
        "subtitle_timing_eval.cli",
        "asr",
        "--audio",
        str(wav),
        "--out",
        str(words),
        "--engine",
        "whisper-cpp",
        "--model-path",
        str(model_path),
        "--whisper-cli",
        whisper_cli,
        "--ffmpeg",
        ffmpeg,
        "--language",
        "ja",
    ]
    if no_gpu:
        cmd.append("--no-gpu")
    run(cmd, env={"PYTHONPATH": str(ROOT / "tools/subtitle_timing_eval")})
    return words


def run_local_asr_srt(words: Path, sample: Sample, sample_dir: Path, swift_scratch_path: Path) -> Path:
    srt = sample_dir / "local-asr.ja.srt"
    if srt.exists() and srt.stat().st_size > 0:
        return srt
    run([
        "swift",
        "run",
        "--package-path",
        str(ROOT),
        "--scratch-path",
        str(swift_scratch_path),
        "--disable-sandbox",
        "moongate-cli",
        "local-asr-srt",
        "--asr-words",
        str(words),
        "--language",
        "ja",
        "--file-name",
        sample.title,
        "--out",
        str(srt),
    ], env={"CLANG_MODULE_CACHE_PATH": str(Path("/private/tmp/moongate-clang-cache"))})
    return srt


def srt_time_to_seconds(value: str) -> float:
    hh, mm, rest = value.replace(",", ".").split(":")
    return int(hh) * 3600 + int(mm) * 60 + float(rest)


def parse_srt(path: Path) -> list[Cue]:
    text = path.read_text(encoding="utf-8")
    blocks = re.split(r"\n\s*\n", text.strip())
    cues: list[Cue] = []
    for block in blocks:
        lines = [line.rstrip() for line in block.splitlines() if line.strip()]
        if len(lines) < 3 or "-->" not in lines[1]:
            continue
        try:
            index = int(lines[0])
            start_raw, end_raw = [part.strip() for part in lines[1].split("-->", 1)]
            cue_text = " ".join(lines[2:]).strip()
            cues.append(Cue(index, srt_time_to_seconds(start_raw), srt_time_to_seconds(end_raw), cue_text))
        except ValueError:
            continue
    return cues


def normalize_japanese(text: str) -> str:
    return "".join(ch for ch in text if (
        "\u3040" <= ch <= "\u309f"
        or "\u30a0" <= ch <= "\u30ff"
        or "\u4e00" <= ch <= "\u9fff"
    ))


def repeated_bigram_excess(text: str) -> int:
    if len(text) < 2:
        return 0
    counts: dict[str, int] = {}
    for i in range(len(text) - 1):
        key = text[i:i + 2]
        counts[key] = counts.get(key, 0) + 1
    return sum(max(0, count - 1) for count in counts.values())


LEADING_PROHIBITED = set("をがはにへとでものねよさわぞぜんっゃゅょぁぃぅぇぉゎー〜、。！？）」』")
RESIDUALS = {"っ", "ー", "〜", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ", "ん"}


def risk_flags(cues: list[Cue]) -> list[dict[str, object]]:
    flags: list[dict[str, object]] = []
    for cue in cues:
        normalized = normalize_japanese(cue.text)
        first = cue.text.strip()[:1]
        if cue.duration >= 7.0:
            flags.append({"kind": "long_cue", "index": cue.index, "detail": f"{cue.duration:.2f}s"})
        if cue.duration <= 0.45:
            flags.append({"kind": "flash_cue", "index": cue.index, "detail": f"{cue.duration:.2f}s"})
        if len(normalized) <= 2 and cue.duration >= 1.6:
            flags.append({"kind": "short_text_long_hold", "index": cue.index, "detail": f"{cue.duration:.2f}s {cue.text}"})
        if first in LEADING_PROHIBITED:
            flags.append({"kind": "leading_tail", "index": cue.index, "detail": cue.text})
        if cue.text.strip() in RESIDUALS:
            flags.append({"kind": "residual", "index": cue.index, "detail": cue.text})

    for i in range(len(cues) - 4):
        window = cues[i:i + 6]
        span = window[-1].end - window[0].start
        if span > 35:
            continue
        normalized = "".join(normalize_japanese(c.text) for c in window)
        if len(normalized) < 24:
            continue
        unique_ratio = len(set(normalized)) / len(normalized)
        if unique_ratio <= 0.42 and repeated_bigram_excess(normalized) >= 7:
            flags.append({
                "kind": "possible_loop",
                "index": window[0].index,
                "detail": f"{window[0].index}-{window[-1].index} unique={unique_ratio:.2f}",
            })

    seen: dict[str, list[Cue]] = {}
    for cue in cues:
        key = normalize_japanese(cue.text)
        if len(key) < 3:
            continue
        seen.setdefault(key, []).append(cue)
    for key, matches in seen.items():
        if len(matches) >= 4:
            span = matches[-1].end - matches[0].start
            flags.append({
                "kind": "repeated_exact_text",
                "index": matches[0].index,
                "detail": f"{matches[0].text} x{len(matches)} span={span:.1f}s",
            })
    for left, right in zip(cues, cues[1:]):
        gap = right.start - left.end
        if gap >= 8.0:
            flags.append({
                "kind": "large_gap",
                "index": left.index,
                "detail": f"{gap:.2f}s before cue {right.index}",
            })
    return flags


def render_review(results: list[dict[str, object]], out: Path) -> None:
    lines: list[str] = [
        "# Japanese Lyrics Whisper Smoke Review",
        "",
        "This is a local artifact. Media, ASR JSON, and generated SRT files are intentionally ignored.",
        "",
        "| sample | status | cues | flags | files |",
        "| --- | --- | ---: | ---: | --- |",
    ]
    for result in results:
        status = str(result["status"])
        files = result.get("files", {})
        file_text = ""
        if isinstance(files, dict) and files.get("srt"):
            file_text = f"[srt]({files['srt']})"
        lines.append(
            f"| {result['id']} | {status} | {result.get('cue_count', 0)} | "
            f"{len(result.get('flags', []))} | {file_text} |"
        )

    for result in results:
        lines.extend(["", f"## {result['id']}", ""])
        lines.append(f"- Title: {result.get('title', '')}")
        lines.append(f"- URL: {result.get('url', '')}")
        lines.append(f"- Window: {result.get('start', '')}s + {result.get('duration', '')}s")
        lines.append(f"- Status: {result['status']}")
        if result.get("error"):
            lines.append(f"- Error: `{result['error']}`")
        flags = result.get("flags", [])
        if flags:
            lines.append("")
            lines.append("Risk flags:")
            for flag in flags[:24]:
                lines.append(f"- cue {flag['index']}: {flag['kind']} - {flag['detail']}")
        cues = result.get("cues", [])
        if cues:
            lines.append("")
            lines.append("Cue excerpt:")
            for cue in cues:
                lines.append(f"- {cue['index']:>3} {cue['start']:.2f}-{cue['end']:.2f} `{cue['text']}`")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")


def cue_excerpt(cues: list[Cue], flags: list[dict[str, object]], limit: int) -> list[Cue]:
    if not cues:
        return []
    if len(cues) <= limit:
        return cues
    interesting: set[int] = set()
    for flag in flags:
        idx = int(flag["index"])
        for j in range(max(1, idx - 2), idx + 4):
            interesting.add(j)
    if not interesting:
        return cues[:limit]
    selected = [cue for cue in cues if cue.index in interesting]
    return selected[: max(limit, min(len(selected), limit * 2))]


def select_samples(limit: int | None, only: Iterable[str]) -> list[Sample]:
    only_set = set(only)
    samples = [sample for sample in SAMPLES if not only_set or sample.id in only_set]
    if limit is not None:
        samples = samples[:limit]
    return samples


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a 20-sample Japanese lyrics local-ASR smoke.")
    parser.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS)
    parser.add_argument("--model-path", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--whisper-cli", default="whisper-cli")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--no-gpu", action="store_true")
    parser.add_argument("--cookies", type=Path, help="Netscape cookies.txt copied to a system temp file before yt-dlp uses it.")
    parser.add_argument("--cookies-from-browser", help="Forwarded to yt-dlp, e.g. safari or chrome.")
    parser.add_argument("--swift-scratch-path", type=Path, default=ROOT / ".build/codex-jp-smoke-cli")
    parser.add_argument("--refresh", action="store_true", help="Delete per-sample ASR/SRT outputs before rerunning.")
    parser.add_argument("--refresh-srt", action="store_true", help="Regenerate SRT from cached ASR words without rerunning Whisper.")
    parser.add_argument("--review-limit", type=int, default=80)
    args = parser.parse_args()

    if not shutil.which("yt-dlp"):
        raise SystemExit("yt-dlp not found")
    if not shutil.which(args.ffmpeg):
        raise SystemExit(f"ffmpeg not found: {args.ffmpeg}")
    if not shutil.which(args.whisper_cli):
        raise SystemExit(f"whisper-cli not found: {args.whisper_cli}")
    if not args.model_path.is_file():
        raise SystemExit(f"model not found: {args.model_path}")
    args.artifacts.mkdir(parents=True, exist_ok=True)
    cookies_copy: Path | None = None
    if args.cookies is not None:
        if not args.cookies.is_file():
            raise SystemExit(f"cookies file not found: {args.cookies}")
        fd, temp_name = tempfile.mkstemp(prefix="moongate-ytdlp-cookies-", suffix=".txt")
        os.close(fd)
        cookies_copy = Path(temp_name)
        shutil.copyfile(args.cookies, cookies_copy)
        atexit.register(lambda path: path.exists() and path.unlink(), cookies_copy)

    samples = select_samples(args.limit, args.only)
    results: list[dict[str, object]] = []
    for offset, sample in enumerate(samples, start=1):
        sample_dir = args.artifacts / sample.id
        sample_dir.mkdir(parents=True, exist_ok=True)
        if args.refresh:
            for name in ["asr_words.whisper-cpp.json", "local-asr.ja.srt", "clip.wav"]:
                path = sample_dir / name
                if path.exists():
                    path.unlink()
        if args.refresh_srt:
            path = sample_dir / "local-asr.ja.srt"
            if path.exists():
                path.unlink()
        print(f"[{offset}/{len(samples)}] {sample.id}", flush=True)
        result: dict[str, object] = {
            "id": sample.id,
            "title": sample.title,
            "start": sample.start,
            "duration": sample.duration,
        }
        try:
            resolved = resolve_source(sample, cookies_copy, args.cookies_from_browser)
            result["url"] = resolved.get("url", "")
            audio = download_audio(sample, resolved, sample_dir, cookies_copy, args.cookies_from_browser)
            wav = clip_audio(audio, sample, sample_dir, args.ffmpeg)
            words = run_asr(wav, sample_dir, args.model_path, args.whisper_cli, args.ffmpeg, args.no_gpu)
            srt = run_local_asr_srt(words, sample, sample_dir, args.swift_scratch_path)
            cues = parse_srt(srt)
            flags = risk_flags(cues)
            result.update({
                "status": "ok",
                "cue_count": len(cues),
                "flags": flags,
                "files": {
                    "audio": slug_path(audio),
                    "wav": slug_path(wav),
                    "words": slug_path(words),
                    "srt": slug_path(srt),
                },
                "cues": [
                    {"index": cue.index, "start": cue.start, "end": cue.end, "text": cue.text}
                    for cue in cue_excerpt(cues, flags, args.review_limit)
                ],
            })
        except Exception as exc:  # noqa: BLE001 - smoke report should continue through blocked samples.
            result.update({"status": "error", "error": str(exc), "flags": [], "cues": []})
        results.append(result)
        (args.artifacts / "status.json").write_text(
            json.dumps(results, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        render_review(results, args.artifacts / "human_review.md")

    print(args.artifacts / "human_review.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

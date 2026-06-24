#!/usr/bin/env python3
"""Collect + transcribe segmentation eval samples end-to-end, then score.

For each manifest sample (Track A/B), this resumably:
  1. downloads the section audio + reference captions via yt-dlp using Moongate's
     YouTube cookie jar (a temp copy, so the master jar is never rewritten),
  2. runs whisper.cpp ASR on the section audio (CJK gets a punctuation-seed prompt,
     matching the product ASRPromptBuilder), writing asr_words.<start>-<end>.json.

Scoring is then done by run_segmentation_baseline.py, which finds the asr_words +
reference and generates/aligns the candidate segmentation.

Network access is rate-limited and resumable; copyright/region/login failures are
recorded as blocker.prepare.json by the pipeline and skipped (never bypassed).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from subtitle_timing_eval.pipeline import prepare_sample, sample_section  # noqa: E402

# CJK punctuation seed — mirrors Sources/MoongateCore/ASR.swift ASRPromptBuilder.
CJK_PROMPT = {
    "ja": "今日は、いい天気ですね。はい、そうです。",
    "ko": "안녕하세요. 오늘은 날씨가 좋네요. 네, 맞습니다.",
    "zh": "你好，今天天气不错。是的，没错。",
    "yue": "你好，今天天气不错。是的，没错。",
}


def _has_audio(d: Path) -> Path | None:
    for pat in ("*.m4a", "*.webm", "*.section.wav"):
        hits = [p for p in d.glob(pat) if ".part" not in p.name]
        if hits:
            return sorted(hits, key=lambda p: p.stat().st_size, reverse=True)[0]
    return None


def _has_reference(d: Path) -> bool:
    srt = [p for p in d.glob("*.srt") if not p.name.endswith(".clean.srt")
           and not p.name.startswith(("local-asr", "seg-candidate", "srt_words"))]
    return bool(srt or list(d.glob("*.vtt")))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", default="tools/subtitle_timing_eval/segmentation_samples.json")
    ap.add_argument("--artifacts", default="artifacts/subtitle_timing_eval")
    ap.add_argument("--cookies", default=os.path.expanduser(
        "~/Library/Application Support/月之门/cookies/youtube.txt"))
    ap.add_argument("--model-path", default=os.path.expanduser(
        "~/Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin"))
    ap.add_argument("--sleep-seconds", type=float, default=4.0, help="Rate-limit between downloads.")
    ap.add_argument("--limit", type=int, default=0, help="Max samples to process this run (0=all).")
    ap.add_argument("--tracks", default="A,B")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    tracks = set(args.tracks.split(","))
    art = Path(args.artifacts)
    processed = 0

    for sample in manifest["samples"]:
        if args.limit and processed >= args.limit:
            break
        track = sample.get("track")
        if track and track not in tracks:
            continue
        cat = sample.get("category", "")
        if "translate" in cat or "proxy" in cat:
            continue
        sid = sample["id"]
        d = art / sid
        d.mkdir(parents=True, exist_ok=True)
        start, end, duration = sample_section(sample, None)
        lang = (sample.get("subtitle_lang") or "und").split("-")[0]

        # 1) download section audio + reference captions (resumable)
        audio = _has_audio(d)
        if audio is None or not _has_reference(d):
            # use a temp cookie copy (yt-dlp rewrites --cookies on exit)
            tmp_cookie = None
            if args.cookies and os.path.exists(args.cookies):
                fd, tmp_cookie = tempfile.mkstemp(prefix="seg-cookies-", suffix=".txt")
                os.close(fd)
                shutil.copyfile(args.cookies, tmp_cookie)
            try:
                print("[prepare] %s" % sid, flush=True)
                prepare_sample(sample, artifacts_root=args.artifacts,
                               duration_override_seconds=duration, cookies=tmp_cookie)
            except subprocess.CalledProcessError:
                print("[skip] %s — download blocked (see blocker.prepare.json)" % sid, flush=True)
                time.sleep(args.sleep_seconds)
                continue
            finally:
                if tmp_cookie:
                    try:
                        os.remove(tmp_cookie)
                    except OSError:
                        pass
            time.sleep(args.sleep_seconds)
            audio = _has_audio(d)

        if audio is None or not _has_reference(d):
            print("[skip] %s — no audio/reference after prepare" % sid, flush=True)
            continue

        # 2) whisper.cpp ASR (resumable) → asr_words.<start>-<end>.json
        out_json = d / ("asr_words.%d-%d.seg.json" % (int(start), int(end)))
        if out_json.exists():
            print("[asr-cached] %s" % sid, flush=True)
            processed += 1
            continue
        wav = d / ("seg-asr-input.%d-%d.wav" % (int(start), int(end)))
        # the section m4a is 0-based; .full media would need trimming — section files only here
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(audio),
                        "-t", str(duration), "-ac", "1", "-ar", "16000",
                        "-c:a", "pcm_s16le", str(wav)], check=True)
        cmd = ["python3", "-m", "subtitle_timing_eval.cli", "asr",
               "--audio", str(wav), "--out", str(out_json),
               "--engine", "whisper-cpp", "--model-path", args.model_path, "--language", lang]
        prompt = CJK_PROMPT.get(lang)
        if prompt:
            cmd += ["--prompt", prompt]
        print("[asr] %s (lang=%s, prompt=%s)" % (sid, lang, "yes" if prompt else "no"), flush=True)
        r = subprocess.run(cmd, env={**os.environ, "PYTHONPATH": "tools/subtitle_timing_eval"},
                           capture_output=True, text=True)
        if r.returncode != 0 or not out_json.exists():
            print("[skip] %s — ASR failed: %s" % (sid, r.stderr.strip()[:160]), flush=True)
            continue
        processed += 1
        print("[done] %s" % sid, flush=True)

    print("processed=%d" % processed, flush=True)


if __name__ == "__main__":
    main()

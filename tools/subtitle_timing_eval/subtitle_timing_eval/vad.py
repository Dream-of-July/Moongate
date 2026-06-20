from __future__ import annotations

import array
import json
import math
import subprocess
from pathlib import Path
from typing import Dict, List, Sequence


def _frame_rms(samples: Sequence[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in samples) / len(samples))


def detect_speech_segments_from_samples(
    samples: Sequence[float],
    sample_rate: int,
    frame_ms: int = 30,
    threshold_ratio: float = 0.16,
    min_speech_ms: int = 180,
    merge_gap_ms: int = 220,
    pad_ms: int = 80,
) -> List[Dict[str, float]]:
    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    frame_size = max(1, int(sample_rate * frame_ms / 1000))
    frames: List[tuple[float, float, float]] = []
    for start in range(0, len(samples), frame_size):
        end = min(len(samples), start + frame_size)
        frames.append((start / sample_rate, end / sample_rate, _frame_rms(samples[start:end])))
    if not frames:
        return []

    max_rms = max(frame[2] for frame in frames)
    if max_rms <= 0:
        return []
    threshold = max_rms * threshold_ratio
    raw_segments: List[Dict[str, float]] = []
    active_start = None
    active_end = None
    for start, end, rms in frames:
        if rms >= threshold:
            if active_start is None:
                active_start = start
            active_end = end
        elif active_start is not None and active_end is not None:
            raw_segments.append({"start": active_start, "end": active_end})
            active_start = None
            active_end = None
    if active_start is not None and active_end is not None:
        raw_segments.append({"start": active_start, "end": active_end})

    min_duration = min_speech_ms / 1000.0
    merge_gap = merge_gap_ms / 1000.0
    pad = pad_ms / 1000.0
    merged: List[Dict[str, float]] = []
    for segment in raw_segments:
        if segment["end"] - segment["start"] < min_duration:
            continue
        if merged and segment["start"] - merged[-1]["end"] <= merge_gap:
            merged[-1]["end"] = segment["end"]
        else:
            merged.append(dict(segment))

    duration = len(samples) / sample_rate
    return [
        {
            "start": max(0.0, segment["start"] - pad),
            "end": min(duration, segment["end"] + pad),
        }
        for segment in merged
        if segment["end"] > segment["start"]
    ]


def _read_audio_samples(audio_path: str, sample_rate: int = 16000) -> List[float]:
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        audio_path,
        "-vn",
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-f",
        "s16le",
        "pipe:1",
    ]
    raw = subprocess.check_output(command)
    values = array.array("h")
    values.frombytes(raw)
    if values.itemsize != 2:
        raise RuntimeError("unexpected PCM sample size")
    return [value / 32768.0 for value in values]


def detect_speech_file(
    audio_path: str,
    output_path: str,
    sample_rate: int = 16000,
    frame_ms: int = 30,
    threshold_ratio: float = 0.16,
    min_speech_ms: int = 180,
    merge_gap_ms: int = 220,
    pad_ms: int = 80,
) -> Dict[str, object]:
    samples = _read_audio_samples(audio_path, sample_rate=sample_rate)
    segments = detect_speech_segments_from_samples(
        samples,
        sample_rate=sample_rate,
        frame_ms=frame_ms,
        threshold_ratio=threshold_ratio,
        min_speech_ms=min_speech_ms,
        merge_gap_ms=merge_gap_ms,
        pad_ms=pad_ms,
    )
    payload = {
        "audio": str(audio_path),
        "sample_rate": sample_rate,
        "frame_ms": frame_ms,
        "threshold_ratio": threshold_ratio,
        "min_speech_ms": min_speech_ms,
        "merge_gap_ms": merge_gap_ms,
        "pad_ms": pad_ms,
        "segments": segments,
    }
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload

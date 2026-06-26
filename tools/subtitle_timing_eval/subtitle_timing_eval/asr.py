from __future__ import annotations

import json
import math
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional


def transcribe_words(
    audio_path: str,
    output_path: str,
    model_size: str = "small",
    language: Optional[str] = None,
    device: str = "auto",
    compute_type: str = "default",
) -> Dict[str, object]:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise RuntimeError(
            "faster-whisper is not installed. Install with: "
            "python3 -m pip install -r tools/subtitle_timing_eval/requirements.txt"
        ) from exc

    actual_device = "cpu" if device == "auto" else device
    kwargs = {}
    if compute_type != "default":
        kwargs["compute_type"] = compute_type
    model = WhisperModel(model_size, device=actual_device, **kwargs)
    segments, info = model.transcribe(
        audio_path,
        language=language,
        beam_size=5,
        vad_filter=True,
        word_timestamps=True,
    )

    words: List[Dict[str, object]] = []
    for segment in segments:
        for word in segment.words or []:
            token = (word.word or "").strip()
            if not token:
                continue
            words.append({"start": float(word.start), "end": float(word.end), "text": token})

    payload = {
        "audio": str(audio_path),
        "model": model_size,
        "language": getattr(info, "language", language),
        "language_probability": getattr(info, "language_probability", None),
        "words": words,
    }
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def transcribe_words_whisper_cpp(
    audio_path: str,
    output_path: str,
    model_path: str,
    language: Optional[str] = None,
    whisper_cli: str = "whisper-cli",
    ffmpeg: str = "ffmpeg",
    prompt: Optional[str] = None,
    no_gpu: bool = False,
    max_context_tokens: Optional[int] = None,
) -> Dict[str, object]:
    if not model_path:
        raise RuntimeError("whisper.cpp ASR requires --model-path pointing to a local ggml model.")

    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    work_base = output.with_suffix("")
    wav_path = work_base.with_name(work_base.name + ".whisper-cpp.wav")
    whisper_output_base = work_base.with_name(work_base.name + ".whisper-cpp")
    whisper_json = Path(str(whisper_output_base) + ".json")

    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-i",
            audio_path,
            "-vn",
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(wav_path),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    args = [
        whisper_cli,
        "-m",
        model_path,
        "-f",
        str(wav_path),
        "-ojf",
        "-of",
        str(whisper_output_base),
        "-pp",
    ]
    if language and language != "auto":
        args.extend(["-l", language])
    if prompt:
        args.extend(["--prompt", prompt])
    if max_context_tokens is not None:
        args.extend(["-mc", str(max(0, max_context_tokens))])
    if no_gpu:
        args.append("--no-gpu")
    subprocess.run(args, check=True)

    if not whisper_json.is_file() or whisper_json.stat().st_size == 0:
        raise RuntimeError("whisper.cpp did not produce a non-empty JSON transcript: %s" % whisper_json)

    root = json.loads(whisper_json.read_text(encoding="utf-8"))
    words = parse_whisper_cpp_words(root)
    if not words:
        raise RuntimeError("whisper.cpp JSON did not contain usable timed words: %s" % whisper_json)

    payload = {
        "audio": str(audio_path),
        "engine": "whisper.cpp",
        "model": str(model_path),
        "language": whisper_cpp_language(root, language),
        "words": words,
    }
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def whisper_cpp_language(root: Dict[str, Any], fallback: Optional[str]) -> Optional[str]:
    result = root.get("result")
    if isinstance(result, dict) and result.get("language"):
        return str(result["language"])
    params = root.get("params")
    if isinstance(params, dict) and params.get("language"):
        return str(params["language"])
    return fallback


def parse_whisper_cpp_words(root: Dict[str, Any]) -> List[Dict[str, object]]:
    segments = root.get("transcription")
    if not isinstance(segments, list):
        segments = root.get("segments")
    if not isinstance(segments, list):
        return []

    words: List[Dict[str, object]] = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        token_words = _parse_whisper_cpp_token_words(segment)
        if token_words:
            words.extend(token_words)
            continue
        span = _interval(segment)
        text = _speech_text(segment.get("text"))
        if span and text:
            words.append({"start": span[0], "end": span[1], "text": text})

    words.sort(key=lambda word: (float(word["start"]), float(word["end"])))
    return words


def _parse_whisper_cpp_token_words(segment: Dict[str, Any]) -> List[Dict[str, object]]:
    tokens = segment.get("tokens")
    if not isinstance(tokens, list):
        tokens = segment.get("words")
    if not isinstance(tokens, list):
        return []

    words: List[Dict[str, object]] = []
    merge_eligible: List[bool] = []
    for token in tokens:
        if not isinstance(token, dict):
            continue
        span = _interval(token)
        raw_text = str(token.get("text") or "")
        text = _speech_text(raw_text)
        if not span or not text:
            continue
        item: Dict[str, object] = {"start": span[0], "end": span[1], "text": text}
        probability = token.get("p", token.get("probability"))
        if isinstance(probability, (int, float)) and math.isfinite(float(probability)):
            item["probability"] = float(probability)
        starts_new_whisper_token_word = bool(raw_text[:1].isspace()) and not _contains_cjk_or_hangul(text)
        if words and _should_merge_latin_asr_token(
            str(words[-1]["text"]),
            merge_eligible[-1],
            text,
            raw_text,
        ):
            words[-1] = {
                **words[-1],
                "end": max(float(words[-1]["end"]), float(item["end"])),
                "text": str(words[-1]["text"]) + text,
            }
            if "probability" in words[-1] or "probability" in item:
                words[-1]["probability"] = min(
                    float(words[-1].get("probability", 1.0)),
                    float(item.get("probability", 1.0)),
                )
            merge_eligible[-1] = True
        else:
            words.append(item)
            merge_eligible.append(starts_new_whisper_token_word)
    return words


def _should_merge_latin_asr_token(previous: str, previous_merge_eligible: bool, current: str, raw_current: str) -> bool:
    if not previous_merge_eligible:
        return False
    if raw_current[:1].isspace():
        return False
    previous = previous.strip()
    current = current.strip()
    if not previous or not current:
        return False
    if _contains_cjk_or_hangul(previous) or _contains_cjk_or_hangul(current):
        return False
    if _is_latin_join_punctuation(current):
        return True
    if _is_latin_apostrophe_prefix(previous) and _contains_letter_outside_cjk(current):
        return True
    return _contains_letter_outside_cjk(previous) and _contains_letter_outside_cjk(current)


def _is_latin_join_punctuation(text: str) -> bool:
    return all(ch in "'’.,!?:;" for ch in text) or text.startswith(("'", "’"))


def _is_latin_apostrophe_prefix(text: str) -> bool:
    return bool(text) and all(ch in "'’" for ch in text)


def _contains_letter_outside_cjk(text: str) -> bool:
    return any(ch.isalpha() and not _is_cjk_or_hangul(ch) for ch in text)


def _contains_cjk_or_hangul(text: str) -> bool:
    return any(_is_cjk_or_hangul(ch) for ch in text)


def _is_cjk_or_hangul(ch: str) -> bool:
    code = ord(ch)
    return (
        0x3040 <= code <= 0x30FF
        or 0x3400 <= code <= 0x4DBF
        or 0x4E00 <= code <= 0x9FFF
        or 0xAC00 <= code <= 0xD7A3
    )


def _speech_text(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    if re.fullmatch(r"\[_[A-Z]+(?:_[0-9]+)?_?\]", text):
        return ""
    return text


def _interval(value: Dict[str, Any]) -> Optional[tuple[float, float]]:
    offsets = value.get("offsets")
    if isinstance(offsets, dict):
        start = _seconds(offsets.get("from"), values_are_ms=True)
        end = _seconds(offsets.get("to"), values_are_ms=True)
        if start is not None and end is not None and end >= start:
            return start, end

    timestamps = value.get("timestamps")
    if isinstance(timestamps, dict):
        start = _seconds(timestamps.get("from"))
        end = _seconds(timestamps.get("to"))
        if start is not None and end is not None and end >= start:
            return start, end

    start = _seconds(value.get("start", value.get("startSeconds")))
    end = _seconds(value.get("end", value.get("endSeconds")))
    if start is not None and end is not None and end >= start:
        return start, end
    return None


def _seconds(value: Any, values_are_ms: bool = False) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        raw = float(value)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if ":" in text:
            parts = [float(part.replace(",", ".")) for part in text.split(":")]
            if len(parts) != 3:
                return None
            raw = parts[0] * 3600 + parts[1] * 60 + parts[2]
        else:
            raw = float(text)
    else:
        return None
    if not math.isfinite(raw):
        return None
    return raw / 1000 if values_are_ms else raw

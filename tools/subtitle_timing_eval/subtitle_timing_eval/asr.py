from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional


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

#!/bin/zsh
# Strictly manual local ASR smoke for release QA. It never downloads runtime,
# models, or media; every input must already exist on this machine.
set -euo pipefail

if [[ "${MOONGATE_ASR_QA_RUN:-}" != "1" ]]; then
    cat >&2 <<'MSG'
Set MOONGATE_ASR_QA_RUN=1 to run this strictly manual QA smoke.

Required local inputs:
  MOONGATE_ASR_QA_RUNTIME_DIR=/path/to/packaged/asr/runtime
    or MOONGATE_ASR_QA_WHISPER_CLI=/path/to/whisper-cli
  MOONGATE_ASR_QA_MODEL=/path/to/model.bin
  MOONGATE_ASR_QA_AUDIO=/path/to/short-audio-or-video
  MOONGATE_ASR_QA_FFMPEG=/path/to/ffmpeg
Optional:
  MOONGATE_ASR_QA_VAD_MODEL=/path/to/local-silero-vad-model.bin
  MOONGATE_ASR_QA_NO_GPU=1
MSG
    exit 66
fi

runtime_dir="${MOONGATE_ASR_QA_RUNTIME_DIR:-}"
whisper_cli="${MOONGATE_ASR_QA_WHISPER_CLI:-}"
model_path="${MOONGATE_ASR_QA_MODEL:-}"
audio_path="${MOONGATE_ASR_QA_AUDIO:-}"
ffmpeg_bin="${MOONGATE_ASR_QA_FFMPEG:-}"
vad_model_path="${MOONGATE_ASR_QA_VAD_MODEL:-}"
no_gpu="${MOONGATE_ASR_QA_NO_GPU:-1}"
language="${MOONGATE_ASR_QA_LANGUAGE:-ja}"
prompt="${MOONGATE_ASR_QA_PROMPT:-Moongate local ASR release smoke}"
work_dir="${MOONGATE_ASR_QA_WORKDIR:-}"

require_file() {
    local label="$1"
    local path="$2"
    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "$label is required and must point to a local file: $path" >&2
        exit 2
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to validate whisper.cpp JSON output." >&2
    exit 2
fi

if [[ -n "$runtime_dir" ]]; then
    if [[ ! -d "$runtime_dir" ]]; then
        echo "MOONGATE_ASR_QA_RUNTIME_DIR must point to a packaged runtime directory: $runtime_dir" >&2
        exit 2
    fi
    manifest_path="$runtime_dir/asr-runtime-manifest.json"
    if [[ ! -s "$manifest_path" ]]; then
        echo "Packaged runtime manifest is required: $manifest_path" >&2
        exit 2
    fi
    whisper_cli="$(
        python3 - "$runtime_dir" "$manifest_path" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

runtime_dir = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2])

with manifest_path.open("r", encoding="utf-8") as handle:
    root = json.load(handle)

runtimes = root.get("runtimes")
if not isinstance(runtimes, list) or not runtimes:
    raise SystemExit("Packaged runtime manifest must contain a non-empty runtimes array.")

runtime = runtimes[0]
relative = runtime.get("executableRelativePath")
sha256 = str(runtime.get("sha256") or "").lower()
if not isinstance(relative, str) or not relative.strip():
    raise SystemExit("Packaged runtime manifest is missing executableRelativePath.")
if os.path.isabs(relative):
    raise SystemExit("Packaged runtime executableRelativePath must be relative.")
parts = Path(relative).parts
if any(part in ("", ".", "..") for part in parts):
    raise SystemExit("Packaged runtime executableRelativePath must not contain traversal.")
if len(sha256) != 64 or any(char not in "0123456789abcdef" for char in sha256):
    raise SystemExit("Packaged runtime manifest is missing a valid sha256.")

executable = (runtime_dir / relative).resolve()
try:
    executable.relative_to(runtime_dir)
except ValueError as error:
    raise SystemExit("Packaged runtime executable escapes the runtime directory.") from error
if not executable.is_file():
    raise SystemExit(f"Packaged runtime executable is missing: {executable}")

actual = hashlib.sha256(executable.read_bytes()).hexdigest()
if actual != sha256:
    raise SystemExit(f"Packaged runtime sha256 mismatch: expected {sha256}, got {actual}")

print(executable)
PY
    )"
fi

require_file "MOONGATE_ASR_QA_WHISPER_CLI" "$whisper_cli"
require_file "MOONGATE_ASR_QA_MODEL" "$model_path"
require_file "MOONGATE_ASR_QA_AUDIO" "$audio_path"
require_file "MOONGATE_ASR_QA_FFMPEG" "$ffmpeg_bin"
if [[ -n "$vad_model_path" ]]; then
    require_file "MOONGATE_ASR_QA_VAD_MODEL" "$vad_model_path"
fi

if [[ ! -x "$whisper_cli" ]]; then
    echo "MOONGATE_ASR_QA_WHISPER_CLI must be executable: $whisper_cli" >&2
    exit 2
fi
if [[ ! -x "$ffmpeg_bin" ]]; then
    echo "MOONGATE_ASR_QA_FFMPEG must be executable: $ffmpeg_bin" >&2
    exit 2
fi

if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/moongate-local-asr-smoke.XXXXXX")"
else
    mkdir -p "$work_dir"
fi

stem="$(basename "${audio_path%.*}")"
wav_path="$work_dir/$stem.16k-mono.wav"
output_base="$work_dir/$stem.whisper"
srt_path="$work_dir/$stem.local-asr.${language}.srt"

echo "==> Converting audio to 16 kHz mono PCM WAV"
"$ffmpeg_bin" -y -i "$audio_path" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav_path" >/dev/null

args=(
    "$whisper_cli"
    -m "$model_path"
    -f "$wav_path"
    -ojf
    -of "$output_base"
    -pp
)
if [[ -n "$language" && "$language" != "auto" ]]; then
    args+=(-l "$language")
fi
if [[ "$no_gpu" == "1" || "$no_gpu" == "true" || "$no_gpu" == "TRUE" ]]; then
    args+=(--no-gpu)
fi
if [[ -n "$vad_model_path" ]]; then
    args+=(--vad --vad-model "$vad_model_path")
fi
if [[ -n "$prompt" ]]; then
    args+=(--prompt "$prompt")
fi

echo "==> Running whisper.cpp"
if [[ -n "$vad_model_path" ]]; then
    echo "==> VAD enabled with model: $vad_model_path"
fi
if [[ "$no_gpu" == "1" || "$no_gpu" == "true" || "$no_gpu" == "TRUE" ]]; then
    echo "==> GPU disabled for deterministic local smoke"
fi
"${args[@]}"

json_path="$output_base.json"
if [[ ! -s "$json_path" ]]; then
    echo "whisper.cpp did not produce a non-empty JSON transcript: $json_path" >&2
    exit 3
fi

python3 - "$json_path" "$srt_path" "$language" <<'PY'
import json
import math
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
srt_path = Path(sys.argv[2])
language = sys.argv[3]

with json_path.open("r", encoding="utf-8") as handle:
    root = json.load(handle)

segments = root.get("transcription") or root.get("segments") or []

def seconds(value, values_are_ms=False):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        raw = float(value)
    elif isinstance(value, str):
        value = value.strip()
        if not value:
            return None
        if ":" in value:
            parts = [float(part.replace(",", ".")) for part in value.split(":")]
            if len(parts) != 3:
                return None
            raw = parts[0] * 3600 + parts[1] * 60 + parts[2]
        else:
            raw = float(value)
    else:
        return None
    if not math.isfinite(raw):
        return None
    return raw / 1000 if values_are_ms else raw

def interval(obj):
    offsets = obj.get("offsets")
    if isinstance(offsets, dict):
        start = seconds(offsets.get("from"), values_are_ms=True)
        end = seconds(offsets.get("to"), values_are_ms=True)
        if start is not None and end is not None and end >= start:
            return start, end
    timestamps = obj.get("timestamps")
    if isinstance(timestamps, dict):
        start = seconds(timestamps.get("from"))
        end = seconds(timestamps.get("to"))
        if start is not None and end is not None and end >= start:
            return start, end
    start = seconds(obj.get("start") if "start" in obj else obj.get("startSeconds"))
    end = seconds(obj.get("end") if "end" in obj else obj.get("endSeconds"))
    if start is not None and end is not None and end >= start:
        return start, end
    return None

def text_of(obj):
    return str(obj.get("text") or "").strip()

cues = []
for segment in segments:
    if not isinstance(segment, dict):
        continue
    span = interval(segment)
    text = text_of(segment)
    if span and text:
        cues.append((span[0], span[1], text))
        continue
    tokens = segment.get("tokens") or segment.get("words") or []
    token_items = []
    for token in tokens:
        if not isinstance(token, dict):
            continue
        token_span = interval(token)
        token_text = text_of(token)
        if token_span and token_text:
            token_items.append((token_span[0], token_span[1], token_text))
    if token_items:
        cues.append((
            token_items[0][0],
            token_items[-1][1],
            "".join(item[2] for item in token_items).strip(),
        ))

cues = [(start, end, text) for start, end, text in cues if text and end >= start]
cues.sort(key=lambda cue: (cue[0], cue[1]))
if not cues:
    raise SystemExit("No timed text cues found in whisper.cpp JSON.")
for index, cue in enumerate(cues[1:], start=1):
    if cue[0] < cues[index - 1][0]:
        raise SystemExit("Cue starts are not monotonic.")

def stamp(value):
    millis = int(round(value * 1000))
    hours, rem = divmod(millis, 3600_000)
    minutes, rem = divmod(rem, 60_000)
    seconds_value, millis = divmod(rem, 1000)
    return f"{hours:02}:{minutes:02}:{seconds_value:02},{millis:03}"

with srt_path.open("w", encoding="utf-8") as handle:
    for index, (start, end, text) in enumerate(cues, start=1):
        handle.write(f"{index}\n{stamp(start)} --> {stamp(end)}\n{text}\n\n")

print(json.dumps({
    "language": language,
    "cueCount": len(cues),
    "durationSeconds": round(max(end for _, end, _ in cues), 3),
    "srtPath": str(srt_path),
}, ensure_ascii=False))
PY

if [[ ! -s "$srt_path" ]]; then
    echo "Local ASR smoke did not produce a non-empty source SRT: $srt_path" >&2
    exit 3
fi

echo "==> Local ASR smoke passed"
echo "JSON: $json_path"
echo "SRT:  $srt_path"

#!/bin/zsh
# Strictly manual cloud ASR smoke. It uploads the supplied local media to the
# configured transcription backend, so it must never run by accident.
set -euo pipefail

required_gate="I_UNDERSTAND_THIS_UPLOADS_AUDIO_AND_MAY_COST_MONEY"
if [[ "${MOONGATE_CLOUD_ASR_QA_RUN:-}" != "$required_gate" ]]; then
    cat >&2 <<MSG
Set MOONGATE_CLOUD_ASR_QA_RUN=$required_gate to run this manual cloud ASR smoke.

Required local inputs:
  MOONGATE_CLOUD_ASR_API_KEY=<already-authorized api key>
  MOONGATE_CLOUD_ASR_AUDIO=/path/to/short-audio-or-video

Optional:
  MOONGATE_CLOUD_ASR_BASE_URL=https://api.openai.com
  MOONGATE_CLOUD_ASR_MODEL=whisper-1
  MOONGATE_CLOUD_ASR_LANGUAGE=ja
  MOONGATE_CLOUD_ASR_PROMPT='short prompt'
  MOONGATE_CLOUD_ASR_GUIDE_SRT=/path/to/local-or-platform-timed-guide.srt
  MOONGATE_CLOUD_ASR_OUTPUT=/path/to/output.srt
MSG
    exit 66
fi

api_key="${MOONGATE_CLOUD_ASR_API_KEY:-}"
base_url="${MOONGATE_CLOUD_ASR_BASE_URL:-https://api.openai.com}"
model="${MOONGATE_CLOUD_ASR_MODEL:-whisper-1}"
audio_path="${MOONGATE_CLOUD_ASR_AUDIO:-}"
language="${MOONGATE_CLOUD_ASR_LANGUAGE:-ja}"
prompt="${MOONGATE_CLOUD_ASR_PROMPT:-Moongate cloud ASR release smoke}"
guide_srt="${MOONGATE_CLOUD_ASR_GUIDE_SRT:-}"
output_path="${MOONGATE_CLOUD_ASR_OUTPUT:-}"
work_dir="${MOONGATE_CLOUD_ASR_WORKDIR:-}"

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for the cloud ASR smoke." >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to validate the returned SRT." >&2
    exit 2
fi
if [[ -z "$api_key" ]]; then
    echo "MOONGATE_CLOUD_ASR_API_KEY is required." >&2
    exit 2
fi
if [[ -z "$audio_path" || ! -f "$audio_path" ]]; then
    echo "MOONGATE_CLOUD_ASR_AUDIO must point to a local file: $audio_path" >&2
    exit 2
fi
if [[ -n "$guide_srt" && ! -f "$guide_srt" ]]; then
    echo "MOONGATE_CLOUD_ASR_GUIDE_SRT must point to a local SRT guide: $guide_srt" >&2
    exit 2
fi
if [[ "${model:l}" != "whisper-1" && -z "$guide_srt" ]]; then
    echo "JSON-only cloud ASR models require MOONGATE_CLOUD_ASR_GUIDE_SRT for local timing alignment: $model" >&2
    exit 2
fi
response_format="srt"
if [[ "${model:l}" != "whisper-1" ]]; then
    response_format="json"
fi

if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/moongate-cloud-asr-smoke.XXXXXX")"
else
    mkdir -p "$work_dir"
fi
if [[ -z "$output_path" ]]; then
    stem="$(basename "${audio_path%.*}")"
    output_path="$work_dir/$stem.cloud-asr.${language}.srt"
else
    mkdir -p "$(dirname "$output_path")"
fi
response_path="$work_dir/cloud-asr-response.body"

endpoint="$(
    python3 - "$base_url" <<'PY'
import sys
from urllib.parse import urlparse, urlunparse

raw = sys.argv[1].strip().rstrip("/")
parsed = urlparse(raw)
if not parsed.scheme or not parsed.netloc:
    raise SystemExit("MOONGATE_CLOUD_ASR_BASE_URL must be an absolute URL.")
path = parsed.path.strip("/")
if path == "":
    path = "v1"
elif not path.endswith("v1"):
    path = path + "/v1"
path = path + "/audio/transcriptions"
print(urlunparse((parsed.scheme, parsed.netloc, "/" + path, "", "", "")))
PY
)"

curl_args=(
    -sS
    -X POST "$endpoint"
    -H "Authorization: Bearer $api_key"
    -F "model=$model"
    -F "response_format=$response_format"
    -F "file=@$audio_path"
    -o "$response_path"
    -w "%{http_code}"
)
if [[ -n "$language" && "$language" != "auto" ]]; then
    curl_args+=(-F "language=$language")
fi
if [[ -n "$prompt" ]]; then
    curl_args+=(-F "prompt=$prompt")
fi

echo "==> Uploading local media for cloud ASR smoke"
echo "==> Endpoint: $endpoint"
echo "==> Model: $model"
echo "==> Response format: $response_format"
http_status="$(curl "${curl_args[@]}")"

if [[ "$http_status" != 2* ]]; then
    echo "Cloud ASR request failed with HTTP $http_status" >&2
    python3 - "$response_path" >&2 <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
print(text[:1000])
PY
    exit 3
fi
if [[ ! -s "$response_path" ]]; then
    echo "Cloud ASR returned an empty response body." >&2
    exit 3
fi

if [[ "$response_format" == "json" ]]; then
    python3 - "$response_path" "$guide_srt" "$output_path" <<'PY'
import json
import re
import sys
from pathlib import Path

response_path = Path(sys.argv[1])
guide_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

payload = json.loads(response_path.read_text(encoding="utf-8"))
transcript = " ".join(str(payload.get("text", "")).split())
if not transcript:
    raise SystemExit("JSON transcription response did not contain non-empty text.")

raw_guide = guide_path.read_text(encoding="utf-8", errors="replace")
cue_pattern = re.compile(
    r"(?ms)(?:^|\n)\s*(?:\d+\s*\n)?"
    r"(\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,.]\d{3}).*?\n"
    r"(.*?)(?=\n\s*\n|\Z)"
)
guide = []
for match in cue_pattern.finditer(raw_guide):
    text = " ".join(line.strip() for line in match.group(3).splitlines() if line.strip())
    if text:
        guide.append((match.group(1).replace(".", ","), match.group(2).replace(".", ","), text))
if not guide:
    raise SystemExit("Guide SRT did not contain usable timed cues.")

def prefers_char_units(text: str) -> bool:
    chars = [ch for ch in text if not ch.isspace()]
    if not chars:
        return False
    cjk = sum(1 for ch in chars if "\u3040" <= ch <= "\u30ff" or "\u3400" <= ch <= "\u9fff" or "\uac00" <= ch <= "\ud7af")
    return cjk / len(chars) >= 0.35

char_mode = prefers_char_units(transcript)
units = [ch for ch in transcript if not ch.isspace()] if char_mode else transcript.split()
weights = [max(1, len([ch for ch in text if not ch.isspace()]) if char_mode else len(text.split())) for _, _, text in guide]
total_weight = max(1, sum(weights))
cursor = 0
out = []
for idx, (start, end, _guide_text) in enumerate(guide):
    remaining = len(units) - cursor
    if remaining <= 0:
        break
    remaining_cues = len(guide) - idx
    if idx == len(guide) - 1:
        take = remaining
    else:
        proportional = round(len(units) * weights[idx] / total_weight)
        take = min(max(1, proportional), max(1, remaining - (remaining_cues - 1)))
    chunk = units[cursor:cursor + take]
    text = "".join(chunk) if char_mode else " ".join(chunk)
    out.append([start, end, text])
    cursor += take
if cursor < len(units) and out:
    tail = "".join(units[cursor:]) if char_mode else " ".join(units[cursor:])
    out[-1][2] = out[-1][2] + ("" if char_mode else " ") + tail

output_path.write_text(
    "\n\n".join(f"{i}\n{start} --> {end}\n{text}" for i, (start, end, text) in enumerate(out, start=1)) + "\n",
    encoding="utf-8",
)
print({"bytes": output_path.stat().st_size, "output": str(output_path), "alignmentGuide": str(guide_path)})
PY
else
    cp "$response_path" "$output_path"
    python3 - "$output_path" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
if "-->" not in text:
    raise SystemExit("Returned body does not look like SRT: missing cue arrow.")
if not text.strip():
    raise SystemExit("Returned SRT is empty.")
print({"bytes": path.stat().st_size, "output": str(path)})
PY
fi

echo "==> Cloud ASR smoke passed"
echo "SRT: $output_path"

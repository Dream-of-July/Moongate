#!/bin/bash
# End-to-end pipeline for the new multilingual corpus samples (es/pt/hi/fr/de/it).
# download section audio + human captions -> whisper.cpp ASR -> local-asr SRT.
# Resumable: skips steps whose outputs already exist. Artifacts are gitignored.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
ROOT="$(pwd)"
ART="artifacts/subtitle_timing_eval"
CLI=/private/tmp/moongate-swift-test/debug/moongate-cli
MODEL="$HOME/Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin"
COOKIE="$HOME/Library/Application Support/月之门/cookies/youtube.txt"
export PYTHONPATH=tools/subtitle_timing_eval

# sample_id : lang : whisper_lang (some subtitle_lang differ e.g. pt-BR)
SAMPLES=(
  "tedx_rosario_simpsons_science_es:es:es:60:120"
  "tedx_riodelaplata_social_media_es:es:es:60:120"
  "tedx_saopaulo_help_yourself_pt:pt-BR:pt:60:120"
  "tedx_saopaulo_meaningless_life_pt:pt-BR:pt:60:120"
  "tedx_gateway_poetry_hi:hi:hi:20:120"
  "tedx_paris_quantum_fr:fr:fr:60:120"
  "tedx_milano_give_back_it:it:it:60:120"
  "tedx_rheinmain_comfort_zone_de:de:de:60:120"
  "tedx_arabic_dont_kill_language_ar:ar:ar:60:120"
  "tedx_yarmouk_three_letters_ar:ar:ar:60:120"
  "tedx_kau_brain_learning_ar:ar:ar:60:120"
  "tedx_leti_unbanal_ru:ru:ru:60:120"
  "tedx_sadovoering_entrepreneurship_ru:ru:ru:60:120"
  "tedx_sadovoering_life_ru:ru:ru:60:120"
)

for entry in "${SAMPLES[@]}"; do
  IFS=":" read -r sid sublang wlang start dur <<< "$entry"
  d="$ART/$sid"
  echo "==== $sid (lang=$wlang) ===="
  mkdir -p "$d"

  # 1) download section audio + human captions (temp cookie copy for safety)
  audio=$(ls "$d"/*.m4a 2>/dev/null | head -1)
  if [ -z "$audio" ]; then
    TMPC=$(mktemp); cp "$COOKIE" "$TMPC"
    python3 -m subtitle_timing_eval.cli prepare \
      --manifest tools/subtitle_timing_eval/samples.json \
      --sample-id "$sid" --artifacts "$ART" --cookies "$TMPC" 2>&1 | tail -3
    rm -f "$TMPC"
    sleep 4
    audio=$(ls "$d"/*.m4a 2>/dev/null | head -1)
  fi
  if [ -z "$audio" ]; then echo "[skip] $sid — no audio after prepare"; continue; fi

  # 2) whisper.cpp ASR -> raw json (resumable)
  wav="$d/e2e-input.$start-$((start+dur)).wav"
  raw="$d/asr_words.$start-$((start+dur)).whisper-cpp.json"
  if [ ! -f "$raw" ]; then
    ffmpeg -nostdin -v error -y -i "$audio" -t "$dur" -ac 1 -ar 16000 -c:a pcm_s16le "$wav" 2>&1 | tail -1
    python3 -m subtitle_timing_eval.cli asr \
      --engine whisper-cpp --audio "$wav" --out "$raw" \
      --whisper-cli /opt/homebrew/bin/whisper-cli --model-path "$MODEL" \
      --ffmpeg /opt/homebrew/bin/ffmpeg --language "$wlang" 2>&1 | tail -2
  fi
  if [ ! -f "$raw" ]; then echo "[skip] $sid — ASR failed"; continue; fi

  # 3) local-asr SRT via production parser path (speech profile)
  out="$d/local-asr.$start-$((start+dur)).$wlang.srt"
  "$CLI" local-asr-srt --asr-words "$raw" --language "$wlang" \
    --out "$out" --file-name "$sid.section.wav" --timing-profile speech 2>&1 | tail -1
  echo "[done] $sid -> $(basename "$out")"
done
echo "ALL DONE"

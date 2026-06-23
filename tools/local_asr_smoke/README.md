# Local ASR Smoke

This is a strictly manual release QA gate for Moongate v0.8 local ASR.

It is intentionally not part of normal CI. It never downloads a model, runtime,
media file, package, or installer. Run it only when you already have a local
whisper.cpp runtime, a local whisper model, a short local audio/video sample,
and a local ffmpeg binary. Prefer pointing it at the packaged `asr/runtime`
directory from a built app or Windows publish output so the smoke also verifies
the packaged runtime manifest and SHA-256.

## Inputs

Set every input explicitly:

```zsh
MOONGATE_ASR_QA_RUN=1 \
MOONGATE_ASR_QA_RUNTIME_DIR=/absolute/path/to/app-or-publish/asr/runtime \
MOONGATE_ASR_QA_MODEL=/absolute/path/to/model.bin \
MOONGATE_ASR_QA_AUDIO=/absolute/path/to/short-sample.mp4 \
MOONGATE_ASR_QA_FFMPEG=/absolute/path/to/ffmpeg \
MOONGATE_ASR_QA_LANGUAGE=ja \
zsh tools/local_asr_smoke/run-local-asr-smoke.sh
```

Optional inputs:

- `MOONGATE_ASR_QA_WHISPER_CLI`: direct path to `whisper-cli` when you are
  validating an unpackaged local runtime. If `MOONGATE_ASR_QA_RUNTIME_DIR` is
  set, the script reads `asr-runtime-manifest.json`, verifies the packaged
  executable SHA-256, and uses the manifest's `executableRelativePath` instead.
- `MOONGATE_ASR_QA_PROMPT`: prompt passed to `whisper-cli --prompt`.
- `MOONGATE_ASR_QA_WORKDIR`: output directory. If omitted, the script creates a temp directory.

## What It Proves

- A packaged runtime manifest can be read, stays inside the runtime directory,
  and its SHA-256 matches the packaged executable.
- ffmpeg can extract a 16 kHz mono PCM WAV from the supplied local media.
- whisper.cpp accepts Moongate's v0.8 command shape: `-m`, `-f`, `-ojf`, `-of`, `-pp`, optional `-l`, and optional `--prompt`.
- whisper.cpp writes a non-empty JSON transcript.
- The JSON contains timed text that can be converted into `*.local-asr.<lang>.srt`.
- The generated SRT is non-empty and has monotonic cue starts.

## What It Does Not Prove

- It does not download or install runtime/model files.
- It does not prove translation or burn-in.
- It does not prove installer update behavior or app UI adoption; it proves the
  packaged runtime directory and real ASR command shape can be used together.
- It does not yet prove the app-level transcript cache with a real runtime; that remains a deeper release QA item.

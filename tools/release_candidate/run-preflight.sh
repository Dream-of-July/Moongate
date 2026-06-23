#!/bin/zsh
# v0.8 release-candidate preflight. This script runs local gates only by default.
# Windows VM checks are opt-in with MOONGATE_RC_INCLUDE_VM=1.
set -euo pipefail

PROJ_DIR="${0:a:h:h:h}"
RC_VERSION="${MOONGATE_RC_VERSION:-0.8.0-rc.1}"
SWIFT_SCRATCH="${MOONGATE_RC_SWIFT_SCRATCH:-/tmp/moongate-v08-rc-swift}"
CLANG_CACHE="${CLANG_MODULE_CACHE_PATH:-/tmp/moongate-v08-rc-clang-module-cache}"
SWIFT_FILTER="ASRContractsTests|MacOSContentBoundaryTests|MacOSViewModelBoundaryTests|MacOSQueueBoundaryTests|MacOSSettingsBoundaryTests|LocalizerTests|QueueProgressTests|EngineProgressTests|HDRSupportTests"
DOTNET_FILTER="AsrContractsTests|WindowsSettingsSurfaceTests|QueueTests|SettingsTests|ReleaseSurfaceTests"

cd "$PROJ_DIR"

echo "==> Moongate v$RC_VERSION release-candidate preflight"

echo "==> git diff --check"
git diff --check

echo "==> shell syntax"
# Equivalent summary: zsh -n build.sh build-windows.sh make-dmg.sh make-pkg.sh make-sparkle-zip.sh make-appcast.sh tools/local_asr_smoke/run-local-asr-smoke.sh
shell_scripts=(
    build.sh
    build-windows.sh
    make-dmg.sh
    make-pkg.sh
    make-sparkle-zip.sh
    make-appcast.sh
    tools/local_asr_smoke/run-local-asr-smoke.sh
)
for script in "${shell_scripts[@]}"; do
    zsh -n "$script"
done

echo "==> Python subtitle timing eval"
python3 -m unittest discover -s tools/subtitle_timing_eval/tests

echo "==> Swift focused RC suite"
env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" \
    swift test --scratch-path "$SWIFT_SCRATCH" \
    --filter "$SWIFT_FILTER" \
    --disable-sandbox

echo "==> .NET focused RC suite"
dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj \
    --filter "$DOTNET_FILTER" \
    --nologo

if [[ "${MOONGATE_RC_INCLUDE_VM:-}" == "1" ]]; then
    if ! command -v prlctl >/dev/null 2>&1; then
        echo "prlctl not found; cannot run Windows VM preflight." >&2
        exit 2
    fi

    vm_name="${MOONGATE_RC_VM_NAME:-Windows 11}"
    win_source="Z:${PROJ_DIR//\//\\}"
    win_script="$win_source\\tools\\release_candidate\\run-windows-vm-preflight.ps1"

    echo "==> Windows VM focused RC suite ($vm_name)"
    prlctl exec "$vm_name" --current-user powershell.exe \
        -NoProfile \
        -ExecutionPolicy Bypass \
        -File "$win_script" \
        -SourceRoot "$win_source"
else
    echo "==> Windows VM preflight skipped (set MOONGATE_RC_INCLUDE_VM=1 to run it)."
fi

echo "==> RC preflight completed"

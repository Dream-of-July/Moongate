#!/bin/zsh
# 在 macOS 上交叉构建 Windows 版：单测 → publish win-x64（自包含，用户无需装 .NET）→ NSIS 安装器。
# 产物输出到 ~/Downloads（避免 iCloud 同步的 ~/Documents）。
# 注意：GUI 无法在 macOS 上运行验证，只有编译与核心库单测两道关。
set -euo pipefail

PROJ_DIR="${0:a:h}"
WIN_DIR="$PROJ_DIR/windows"
PUBLISH_DIR="$HOME/Library/Caches/moongate-build/win-publish"
VERSION="${MOONGATE_VERSION:-0.8.2}"
OUT="${1:-$HOME/Downloads/Moongate-Windows-Setup-v$VERSION.exe}"
MOONGATE_WHISPER_CPP_RUNTIME_DIR="${MOONGATE_WHISPER_CPP_RUNTIME_DIR:-}"

export DOTNET_CLI_TELEMETRY_OPTOUT=1

echo "==> dotnet test（核心库单测，mac 上可跑）"
dotnet test "$WIN_DIR/MoongateCore.Tests/MoongateCore.Tests.csproj" --nologo -v quiet

echo "==> dotnet publish win-x64（自包含）"
rm -rf "$PUBLISH_DIR"
dotnet publish "$WIN_DIR/MoongateApp/MoongateApp.csproj" -c Release -r win-x64 \
    --self-contained true \
    -p:EnableWindowsTargeting=true \
    -p:Version="$VERSION" \
    -o "$PUBLISH_DIR" --nologo

if [[ -n "$MOONGATE_WHISPER_CPP_RUNTIME_DIR" ]]; then
    if [[ ! -d "$MOONGATE_WHISPER_CPP_RUNTIME_DIR" ]]; then
        echo "MOONGATE_WHISPER_CPP_RUNTIME_DIR 不是目录：$MOONGATE_WHISPER_CPP_RUNTIME_DIR" >&2
        exit 1
    fi
    if [[ ! -f "$MOONGATE_WHISPER_CPP_RUNTIME_DIR/whisper-cli.exe" ]]; then
        echo "MOONGATE_WHISPER_CPP_RUNTIME_DIR 缺少 whisper-cli.exe。" >&2
        exit 1
    fi
    echo "==> 打包 whisper.cpp runtime: $MOONGATE_WHISPER_CPP_RUNTIME_DIR"
    mkdir -p "$PUBLISH_DIR/asr/runtime"
    cp -R "$MOONGATE_WHISPER_CPP_RUNTIME_DIR"/. "$PUBLISH_DIR/asr/runtime/"
    runtime_sha="$(shasum -a 256 "$PUBLISH_DIR/asr/runtime/whisper-cli.exe" | awk '{print $1}')"
    cat > "$PUBLISH_DIR/asr/runtime/asr-runtime-manifest.json" <<JSON
{
  "runtimes": [
    {
      "provider": "whisper.cpp",
      "platform": "windows",
      "architecture": "x64",
      "version": "${MOONGATE_WHISPER_CPP_RUNTIME_VERSION:-local}",
      "executableRelativePath": "whisper-cli.exe",
      "sha256": "$runtime_sha",
      "license": "${MOONGATE_WHISPER_CPP_RUNTIME_LICENSE:-MIT}",
      "sourceDescription": "${MOONGATE_WHISPER_CPP_RUNTIME_SOURCE:-local staged whisper.cpp runtime}"
    }
  ]
}
JSON
fi

echo "==> makensis 打安装器"
makensis -INPUTCHARSET UTF8 \
    -DPUBLISH_DIR="$PUBLISH_DIR" \
    -DOUTFILE="$OUT" \
    -DAPPVERSION="$VERSION" \
    -DICON_PATH="$WIN_DIR/assets/app-nsis.ico" \
    "$WIN_DIR/installer/installer.nsi" >/dev/null
HASH="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf "%s  %s\n" "$HASH" "${OUT:t}" > "$OUT.sha256"

echo "==> 完成：$OUT"
echo "==> SHA256：$OUT.sha256"
echo "    （Windows 上双击安装，无需管理员权限；首次启动 App 会自动下载 yt-dlp/ffmpeg/deno）"

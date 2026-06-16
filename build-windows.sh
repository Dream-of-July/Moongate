#!/bin/zsh
# 在 macOS 上交叉构建 Windows 版：单测 → publish win-x64（自包含，用户无需装 .NET）→ NSIS 安装器。
# 产物输出到 ~/Downloads（避免 iCloud 同步的 ~/Documents）。
# 注意：GUI 无法在 macOS 上运行验证，只有编译与核心库单测两道关。
set -euo pipefail

PROJ_DIR="${0:a:h}"
WIN_DIR="$PROJ_DIR/windows"
PUBLISH_DIR="$HOME/Library/Caches/moongate-build/win-publish"
VERSION="0.6.1"
OUT="${1:-$HOME/Downloads/Moongate-Windows-Setup-v$VERSION.exe}"

export DOTNET_CLI_TELEMETRY_OPTOUT=1

echo "==> dotnet test（核心库单测，mac 上可跑）"
dotnet test "$WIN_DIR" --nologo -v quiet

echo "==> dotnet publish win-x64（自包含）"
rm -rf "$PUBLISH_DIR"
dotnet publish "$WIN_DIR/MoongateApp/MoongateApp.csproj" -c Release -r win-x64 \
    --self-contained true \
    -p:EnableWindowsTargeting=true \
    -p:Version="$VERSION" \
    -o "$PUBLISH_DIR" --nologo

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

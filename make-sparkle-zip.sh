#!/bin/zsh
# 打包 Sparkle 自更新用 ZIP。正式发布时配合 make-appcast.sh 生成 EdDSA 签名 appcast。
set -euo pipefail

PROJ_DIR="${0:a:h}"
APP_NAME="月之门"
VERSION="${MOONGATE_VERSION:-0.7.3}"
BUILD_NUMBER="${MOONGATE_BUILD_NUMBER:-703}"
OUT="${1:-$HOME/Downloads/Moongate-macOS-v$VERSION.zip}"
STAGING="$(mktemp -d /tmp/moongate-sparkle-zip-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

INSTALL_DIR="$STAGING/Applications" \
MOONGATE_VERSION="$VERSION" \
MOONGATE_BUILD_NUMBER="$BUILD_NUMBER" \
"$PROJ_DIR/build.sh"

APP="$STAGING/Applications/$APP_NAME.app"
if [[ ! -d "$APP" ]]; then
    echo "找不到 $APP，无法创建 Sparkle ZIP。" >&2
    exit 1
fi

rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
echo "==> Sparkle ZIP 已生成：$OUT"
echo "==> 下一步：./make-appcast.sh \"$OUT\""

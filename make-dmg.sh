#!/bin/zsh
# 打包手动安装用 DMG：先跑 build.sh 确保 App 最新（含图标），再生成压缩镜像。
# App 内更新不再使用 DMG；当前免 Developer ID 更新资产请用 make-sparkle-zip.sh 生成 ZIP。
# 输出默认到 ~/Downloads；也可以传参覆盖输出路径。
set -euo pipefail

PROJ_DIR="${0:a:h}"
APP_NAME="月之门"
VERSION="${MOONGATE_VERSION:-0.8.2}"
OUT="${1:-$HOME/Downloads/Moongate-macOS-v$VERSION.dmg}"
BUILD_STAGING="$(mktemp -d /tmp/moongate-dmg-build-XXXXXX)"
DMG_STAGING="$(mktemp -d /tmp/moongate-dmg-XXXXXX)"
trap 'rm -rf "$BUILD_STAGING" "$DMG_STAGING"' EXIT
APP="$BUILD_STAGING/Applications/$APP_NAME.app"

INSTALL_DIR="$BUILD_STAGING/Applications" "$PROJ_DIR/build.sh"

cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$OUT" >/dev/null
echo "==> DMG 已生成：$OUT"
echo "    （ad-hoc 签名：在别的 Mac 上首次打开需右键 → 打开，或先执行"
echo "      xattr -dr com.apple.quarantine /Applications/$APP_NAME.app）"

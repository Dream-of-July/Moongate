#!/bin/zsh
# 打包分发用 DMG：先跑 build.sh 确保 App 最新（含图标），再生成压缩镜像。
# 输出默认到 ~/Downloads；也可以传参覆盖输出路径。
set -euo pipefail

PROJ_DIR="${0:a:h}"
APP_NAME="月之门"
VERSION="0.6.0"
# build.sh 把 App 装到 /Applications，这里必须从同一位置取，否则 cp 找不到文件。
APP="/Applications/$APP_NAME.app"
OUT="${1:-$HOME/Downloads/Moongate-macOS-v$VERSION.dmg}"

"$PROJ_DIR/build.sh"

STAGING="$(mktemp -d /tmp/moongate-dmg-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT" >/dev/null
echo "==> DMG 已生成：$OUT"
echo "    （ad-hoc 签名：在别的 Mac 上首次打开需右键 → 打开，或先执行"
echo "      xattr -dr com.apple.quarantine /Applications/$APP_NAME.app）"

#!/bin/zsh
# 打包未来 Developer ID 官方链路备用的 macOS Installer PKG。
# 当前免 Apple Developer Program 的 App 内更新主链路使用 Sparkle ZIP（make-sparkle-zip.sh）。
# 正式发布时必须设置 PKG_SIGN_IDENTITY 为 Developer ID Installer 证书名，
# 并在上传 GitHub Release 前完成 notarization 与 stapler。
set -euo pipefail

PROJ_DIR="${0:a:h}"
APP_NAME="月之门"
VERSION="${MOONGATE_VERSION:-0.8.0-rc.1}"
OUT="${1:-$HOME/Downloads/Moongate-macOS-v$VERSION.pkg}"
IDENTIFIER="com.moongate.app.pkg"
STAGING="$(mktemp -d /tmp/moongate-pkg-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

INSTALL_DIR="$STAGING/Applications" "$PROJ_DIR/build.sh"
APP="$STAGING/Applications/$APP_NAME.app"

if [[ ! -d "$APP" ]]; then
    echo "找不到 $APP，无法创建安装包。" >&2
    exit 1
fi

rm -f "$OUT"

args=(
    --component "$APP" /Applications
    --identifier "$IDENTIFIER"
    --version "$VERSION"
)

if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    args+=(--sign "$PKG_SIGN_IDENTITY")
fi

productbuild "${args[@]}" "$OUT" >/dev/null

echo "==> PKG 已生成：$OUT"
if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    pkgutil --check-signature "$OUT"
    echo "==> 正式发布前继续执行：xcrun notarytool submit \"$OUT\" --wait ... && xcrun stapler staple \"$OUT\""
else
    echo "    （未设置 PKG_SIGN_IDENTITY：此包仅用于本地 QA；当前免 Developer ID 更新请使用 Sparkle ZIP。）"
fi

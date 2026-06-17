#!/bin/zsh
# 编译并安装 月之门.app 到 /Applications。
# 注意：本项目位于 iCloud 同步的 ~/Documents 下，构建产物若留在项目内会破坏 codesign，
# 因此 scratch path 与 .app 全部放在 iCloud 之外。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
APP_NAME="月之门"
APP_VERSION="${MOONGATE_VERSION:-0.7.0}"
APP_BUILD_NUMBER="${MOONGATE_BUILD_NUMBER:-700}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://dream-of-july.github.io/moongate/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_PUBLIC_ED_KEY_FILE="${SPARKLE_PUBLIC_ED_KEY_FILE:-$PROJ_DIR/sparkle-public-ed-key.txt}"
# Icon Composer 源、actool 的 --app-icon、以及 Info.plist 的 CFBundleIconName 三者必须同名，
# 否则 macOS 按 CFBundleIconName 从 Assets.car 取分层图标时会落空（Tahoe Liquid Glass 失效）。
ICON_SOURCE_NAME="$APP_NAME"
# 默认装到系统级 /Applications；打包脚本可通过 INSTALL_DIR 指向临时 staging，避免覆盖本机已安装 App。
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/$APP_NAME.app"
TMP_APP="$INSTALL_DIR/.$APP_NAME.app.new"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.app.previous"
ICON_DOC="$PROJ_DIR/$ICON_SOURCE_NAME.icon"
ICON_OUT="$SCRATCH/icon-compiled"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" && -f "$SPARKLE_PUBLIC_ED_KEY_FILE" ]]; then
    SPARKLE_PUBLIC_ED_KEY="$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_ED_KEY_FILE")"
fi

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "缺少 Sparkle 公钥。请先运行 ./init-sparkle-keys.sh，或设置 SPARKLE_PUBLIC_ED_KEY。" >&2
    exit 1
fi

cleanup() {
    rm -rf "$TMP_APP"
}
trap cleanup EXIT

echo "==> swift build (release, scratch: $SCRATCH)"
swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH"

BIN="$(swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" --show-bin-path)/Moongate"

find_sparkle_framework() {
    local root candidate
    for root in "$SCRATCH/artifacts" "$PROJ_DIR/.build/artifacts"; do
        if [[ -d "$root" ]]; then
            candidate="$(find "$root" -path "*/Sparkle.framework" -type d -prune -print 2>/dev/null | head -n 1)"
            if [[ -n "$candidate" ]]; then
                print -r -- "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

SPARKLE_FRAMEWORK="$(find_sparkle_framework || true)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "找不到 Sparkle.framework；请确认 SwiftPM 已解析 Sparkle 依赖。" >&2
    exit 1
fi

# Icon Composer 的 .icon 文档每次构建现编译：Assets.car（Tahoe 分层 Liquid Glass）
# + .icns（旧系统/访达列表回退）。actool 不可用时跳过（无图标，不阻塞构建）。
ICON_READY=0
if [[ -d "$ICON_DOC" ]] && xcrun --find actool >/dev/null 2>&1; then
    echo "==> actool 编译图标 $ICON_DOC"
    rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
    if xcrun actool "$ICON_DOC" --compile "$ICON_OUT" \
        --output-format human-readable-text --notices --warnings \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon "$ICON_SOURCE_NAME" \
        --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1; then
        ICON_READY=1
    else
        echo "    （actool 编译失败，跳过图标）"
    fi
fi

echo "==> 组装 $APP"
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources" "$TMP_APP/Contents/Frameworks"
cp "$BIN" "$TMP_APP/Contents/MacOS/Moongate"
ditto "$SPARKLE_FRAMEWORK" "$TMP_APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$TMP_APP/Contents/MacOS/Moongate" 2>/dev/null || true
if [[ "$ICON_READY" == 1 ]]; then
    cp "$ICON_OUT/Assets.car" "$TMP_APP/Contents/Resources/"
    cp "$ICON_OUT/$ICON_SOURCE_NAME.icns" "$TMP_APP/Contents/Resources/$APP_NAME.icns"
fi

cat > "$TMP_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>zh_CN</string>
    <key>CFBundleExecutable</key>             <string>Moongate</string>
    <key>CFBundleIdentifier</key>             <string>com.moongate.app</string>
    <key>CFBundleName</key>                   <string>月之门</string>
    <key>CFBundleDisplayName</key>            <string>月之门</string>
    <key>CFBundleIconFile</key>               <string>月之门</string>
    <key>CFBundleIconName</key>               <string>月之门</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>                <string>$APP_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSHumanReadableCopyright</key>       <string>MIT License</string>
    <key>SUFeedURL</key>                      <string>$SPARKLE_FEED_URL</string>
    <key>SUPublicEDKey</key>                  <string>$SPARKLE_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key>        <true/>
    <key>SUAutomaticallyUpdate</key>          <false/>
    <key>SUScheduledCheckInterval</key>       <integer>86400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key> <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$TMP_APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$TMP_APP"

rm -rf "$BACKUP_APP"
if [[ -e "$APP" ]]; then
    mv "$APP" "$BACKUP_APP"
fi
if ! mv "$TMP_APP" "$APP"; then
    if [[ -e "$BACKUP_APP" ]]; then
        mv "$BACKUP_APP" "$APP"
    fi
    exit 1
fi
rm -rf "$BACKUP_APP"

echo "==> 完成：$APP"

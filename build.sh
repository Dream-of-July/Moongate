#!/bin/zsh
# 编译并安装 月之门.app 到 /Applications。
# 注意：本项目位于 iCloud 同步的 ~/Documents 下，构建产物若留在项目内会破坏 codesign，
# 因此 scratch path 与 .app 全部放在 iCloud 之外。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
APP_NAME="月之门"
# Icon Composer 源、actool 的 --app-icon、以及 Info.plist 的 CFBundleIconName 三者必须同名，
# 否则 macOS 按 CFBundleIconName 从 Assets.car 取分层图标时会落空（Tahoe Liquid Glass 失效）。
ICON_SOURCE_NAME="$APP_NAME"
# 装到系统级 /Applications：访达侧边栏「应用程序」默认指这里，不像 ~/Applications 那样要手动找。
# 当前用户在 admin 组时可直接写，无需 sudo。
INSTALL_DIR="/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
TMP_APP="$INSTALL_DIR/.$APP_NAME.app.new"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.app.previous"
ICON_DOC="$PROJ_DIR/$ICON_SOURCE_NAME.icon"
ICON_OUT="$SCRATCH/icon-compiled"

cleanup() {
    rm -rf "$TMP_APP"
}
trap cleanup EXIT

echo "==> swift build (release, scratch: $SCRATCH)"
swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH"

BIN="$(swift build -c release --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" --show-bin-path)/Moongate"

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
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"
cp "$BIN" "$TMP_APP/Contents/MacOS/Moongate"
if [[ "$ICON_READY" == 1 ]]; then
    cp "$ICON_OUT/Assets.car" "$TMP_APP/Contents/Resources/"
    cp "$ICON_OUT/$ICON_SOURCE_NAME.icns" "$TMP_APP/Contents/Resources/$APP_NAME.icns"
fi

cat > "$TMP_APP/Contents/Info.plist" <<'PLIST'
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
    <key>CFBundleShortVersionString</key>     <string>0.7.0</string>
    <key>CFBundleVersion</key>                <string>1</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSHumanReadableCopyright</key>       <string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
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

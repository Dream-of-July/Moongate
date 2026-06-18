#!/bin/zsh
# 为 Sparkle 生成 GitHub Pages 使用的 appcast.xml。
# 默认假设 ZIP 已上传到本仓库对应 GitHub Release。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
VERSION="${MOONGATE_VERSION:-0.7.3}"
BUILD_NUMBER="${MOONGATE_BUILD_NUMBER:-703}"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
ZIP="${1:-$HOME/Downloads/Moongate-macOS-v$VERSION.zip}"
ZIP_URL="${ZIP_URL:-https://github.com/Dream-of-July/moongate/releases/download/$RELEASE_TAG/$(basename "$ZIP")}"
APPCAST_OUT="${APPCAST_OUT:-$PROJ_DIR/docs/appcast.xml}"
RELEASE_LINK="${RELEASE_LINK:-https://github.com/Dream-of-July/moongate/releases/tag/$RELEASE_TAG}"
TITLE="${TITLE:-Moongate $VERSION}"

find_sparkle_tool() {
    local name="$1"
    local root candidate
    for root in "$SCRATCH/artifacts" "$PROJ_DIR/.build/artifacts" "$PROJ_DIR/.build/checkouts/Sparkle"; do
        if [[ -d "$root" ]]; then
            candidate="$(find "$root" -path "*/bin/$name" -type f -print 2>/dev/null | head -n 1)"
            if [[ -n "$candidate" ]]; then
                print -r -- "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

if [[ ! -f "$ZIP" ]]; then
    echo "找不到 ZIP：$ZIP" >&2
    exit 1
fi

if ! SIGN_UPDATE="$(find_sparkle_tool sign_update)"; then
    echo "==> 解析 Sparkle 依赖以获取 sign_update 工具"
    swift package --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" resolve
    SIGN_UPDATE="$(find_sparkle_tool sign_update)"
fi

SIGNATURE_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
if [[ "$SIGNATURE_ATTRS" != *"sparkle:edSignature"* ]]; then
    echo "sign_update 没有返回 sparkle:edSignature，无法生成可验证的 appcast。" >&2
    exit 1
fi
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S %z")"

mkdir -p "$(dirname "$APPCAST_OUT")"
cat > "$APPCAST_OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
    xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Moongate Updates</title>
        <link>https://dream-of-july.github.io/moongate/</link>
        <description>Moongate macOS updates</description>
        <language>zh-cn</language>
        <item>
            <title>$TITLE</title>
            <link>$RELEASE_LINK</link>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
            <pubDate>$PUB_DATE</pubDate>
            <enclosure url="$ZIP_URL"
                $SIGNATURE_ATTRS
                type="application/zip" />
        </item>
    </channel>
</rss>
XML

echo "==> appcast 已生成：$APPCAST_OUT"
echo "==> ZIP URL：$ZIP_URL"

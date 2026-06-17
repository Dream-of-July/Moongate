#!/bin/zsh
# 初始化 Sparkle EdDSA 密钥。私钥由 Sparkle 保存到本机 Keychain；
# 仓库只保存可公开的 SUPublicEDKey。
set -euo pipefail

PROJ_DIR="${0:a:h}"
SCRATCH="$HOME/Library/Caches/vdl-build"
PUBLIC_KEY_FILE="${SPARKLE_PUBLIC_ED_KEY_FILE:-$PROJ_DIR/sparkle-public-ed-key.txt}"

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

if ! GENERATE_KEYS="$(find_sparkle_tool generate_keys)"; then
    echo "==> 解析 Sparkle 依赖以获取 generate_keys 工具"
    swift package --package-path "$PROJ_DIR" --scratch-path "$SCRATCH" resolve
    GENERATE_KEYS="$(find_sparkle_tool generate_keys)"
fi

echo "==> 运行 Sparkle generate_keys（私钥会保存到本机 Keychain）"
OUTPUT="$("$GENERATE_KEYS")"
echo "$OUTPUT"

PUBLIC_KEY="$(print -r -- "$OUTPUT" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | tail -n 1)"
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "无法从 generate_keys 输出中解析 SUPublicEDKey。" >&2
    exit 1
fi

print -r -- "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
echo "==> Sparkle 公钥已写入：$PUBLIC_KEY_FILE"

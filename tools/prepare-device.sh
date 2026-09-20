#!/usr/bin/env bash
# 在电脑上准备 Kindle 需要的东西：
#   1. 取 EasyTier 官方 Linux armv7 静态包（32 位 ARM，静态链接，PW5/PW6/KT5 这类 armv7l 设备直接用）
#   2. 整理成两个可以直接拷进 Kindle 的目录：
#        out/easytier/                     -> 拷到 /mnt/us/easytier
#        out/koreader/plugins/             -> 拷到 /mnt/us/koreader/plugins
#
# 用法：
#   tools/prepare-device.sh [本地 zip 路径] [版本号]
# 例：
#   tools/prepare-device.sh                                   # 自动下载最新版
#   tools/prepare-device.sh ~/Downloads/easytier-linux-armv7-v2.6.4.zip v2.6.4
#
# 说明：国内直连 GitHub 的 release 经常卡住，脚本会依次尝试直连和 ghproxy 镜像。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
VERSION="${2:-v2.6.4}"
ZIP_NAME="easytier-linux-armv7-${VERSION}.zip"
ZIP_PATH="${1:-}"

say() { printf '\033[1m== %s\033[0m\n' "$1"; }

say "检查依赖"
for cmd in unzip curl; do
    command -v "$cmd" >/dev/null || { echo "缺少 $cmd，请先安装"; exit 1; }
done

if [ -z "$ZIP_PATH" ]; then
    ZIP_PATH="$OUT/$ZIP_NAME"
    if [ ! -f "$ZIP_PATH" ]; then
        mkdir -p "$OUT"
        URL="https://github.com/EasyTier/EasyTier/releases/download/${VERSION}/${ZIP_NAME}"
        say "下载 $ZIP_NAME"
        if ! curl -fL --connect-timeout 15 --max-time 900 -o "$ZIP_PATH" "$URL"; then
            echo "直连失败，改用镜像 ghproxy.net"
            curl -fL --connect-timeout 15 --max-time 900 -o "$ZIP_PATH" "https://ghproxy.net/$URL"
        fi
    fi
fi

[ -f "$ZIP_PATH" ] || { echo "找不到 zip：$ZIP_PATH"; exit 1; }

say "解包 $ZIP_PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q -o "$ZIP_PATH" -d "$TMP"

CORE="$(find "$TMP" -name easytier-core -type f | head -1)"
CLI="$(find "$TMP" -name easytier-cli -type f | head -1)"
[ -n "$CORE" ] || { echo "zip 里没有 easytier-core"; exit 1; }

say "整理输出目录"
rm -rf "$OUT/easytier" "$OUT/koreader"
mkdir -p "$OUT/easytier/bin" "$OUT/koreader/plugins"
cp "$CORE" "$OUT/easytier/bin/easytier-core"
[ -n "$CLI" ] && cp "$CLI" "$OUT/easytier/bin/easytier-cli"
chmod +x "$OUT/easytier/bin/"* 2>/dev/null || true

# 插件本体（如果这个仓库就在本机）
if [ -d "$ROOT/easytier.koplugin" ]; then
    cp -r "$ROOT/easytier.koplugin" "$OUT/koreader/plugins/"
    # 顺手带上说明文档，方便在设备上/离线时查
    [ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$OUT/koreader/plugins/easytier.koplugin/README.md"
fi

# Release 资产：插件本体 + 说明文档打成一个 zip
# 注意：用相对路径调用（原生 python 不认识 MSYS 的 /e/... 这种路径）
if command -v python >/dev/null 2>&1; then
    (cd "$ROOT" && python tools/pack-release.py >/dev/null) && say "已生成 $OUT/easytier.koplugin.zip"
fi

cat <<EOF

$(say "完成")
产物在 $OUT

拷贝到 Kindle（数据线即可，两个目录都要）：

  $OUT/easytier            ->  /mnt/us/easytier
  $OUT/koreader/plugins    ->  /mnt/us/koreader/plugins

即设备上的最终结构：
  /mnt/us/easytier/bin/easytier-core
  /mnt/us/easytier/bin/easytier-cli
  /mnt/us/koreader/plugins/easytier.koplugin/{main.lua,_meta.lua,...}

注意：插件目录名必须以 .koplugin 结尾，否则 KOReader 不会加载。
EOF

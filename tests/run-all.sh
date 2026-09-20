#!/usr/bin/env bash
# 一次跑完全部测试。可选的第一个参数是真实 easytier-core 的路径，
# 用来额外验证 ELF 架构识别（官方 easytier-linux-armv7 包里那个）。
#
#   tests/run-all.sh /path/to/easytier-core

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BIN="${1:-}"
fail=0

for f in tests/test_config.lua tests/test_proc.lua tests/test_menu.lua; do
    printf '\n===== %s =====\n' "$f"
    if lua "$f" $BIN; then
        :
    else
        fail=1
    fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then
    echo "全部通过"
else
    echo "有测试失败"
fi
exit "$fail"

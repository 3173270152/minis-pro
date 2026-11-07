#!/bin/sh
# gen_sys_table.sh - 生成系统 selector 白名单（rename-selectors 必需）
#
#   ./gen_sys_table.sh [输出路径]
#
# 默认输出到: 项目根目录/sys_selectors.txt
#
# ⚠️ 不生成这张表就用 rename-selectors = 系统方法被误改 = 必崩（SIGABRT，无崩溃报告）

set -e
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/sys_selectors.txt}"
CACHE=/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e

if [ ! -f "$CACHE" ]; then
    echo "[!] 找不到 dyld shared cache: $CACHE"
    echo "    请确认设备是 arm64e 且已挂载系统分区"
    exit 1
fi

echo "[*] 从 $CACHE 提取系统 selector ..."
strings -n 4 "$CACHE" \
  | LC_ALL=C grep -E '^[A-Za-z_][A-Za-z0-9_:]{2,79}$' \
  | LC_ALL=C sort -u > "$OUT"

N=$(wc -l < "$OUT")
SZ=$(du -h "$OUT" | awk '{print $1}')
echo "[+] 完成: $OUT ($N 条, $SZ)"
echo
echo "验证方法: rename-selectors 输出里必须有"
echo "  [i] 系统 selector 表: $OUT ($N 条)"

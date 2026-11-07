#!/usr/bin/env bash
# ============================================================================
# build_all.sh — 一键构建（对应 STATUS §8 的手动 5 步 + §P2 的收敛自动检测）
#
# 把原来「gen → make → deploy → strip/rename → hide」的手动流程串起来，
# 并自动循环重编直到函数布局收敛（LC_FUNCTION_STARTS 集合稳定），
# 避免人工判断「编几轮才稳」。
#
# 用法:
#   export LLVM16=/path/to/llvm16                 # LLVM 16 根目录
#   export DYLIB=/path/to/app.dylib          # make 产出的目标 dylib
#   export GCOBF=sobf,sub,bcf,split,fla,cenc,frag # 混淆 pass 组合
#   export GCOBF_SKIP=<反调试函数前缀>             # 跳过的函数前缀
#   ./build_all.sh
#
# 需要的外部工具: make / python3 / ldid / (可选) otool,nm（gen 脚本用）
# 本脚本只做编排；具体编译规则仍由你的 Makefile 决定。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

: "${DYLIB:?请先 export DYLIB=目标 dylib 路径}"
: "${MAX_ROUNDS:=6}"            # 收敛最多重编轮数
: "${SNAP:=$ROOT/.conv_snapshot.json}"
GEN="$HERE/gen_multi_hooks.py"
POST="$HERE/gcobf-post.py"
CONV="$HERE/check_convergence.py"

log() { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }

# ---- 1. 收敛循环：gen 字节码/hook → make → 检测函数布局是否稳定 ----
rm -f "$SNAP"
converged=0
for r in $(seq 1 "$MAX_ROUNDS"); do
    log "第 $r/$MAX_ROUNDS 轮：生成 hook + 字节码"
    python3 "$GEN"

    log "第 $r 轮：编译（make）"
    make

    if [ "$r" -eq 1 ]; then
        python3 "$CONV" "$DYLIB" --save "$SNAP" >/dev/null || true
        log "已建立收敛基线"
        continue
    fi
    if python3 "$CONV" "$DYLIB" --save "$SNAP" --compare; then
        log "✓ 第 $r 轮已收敛，停止重编"
        converged=1
        break
    else
        log "仍在漂移，继续下一轮"
    fi
done
[ "$converged" -eq 1 ] || log "⚠ 达到 MAX_ROUNDS=$MAX_ROUNDS 仍未完全收敛（通常仍可用，请看漂移幅度）"

# ---- 2. 后处理：strip → rename-selectors → hide-exports → 重签 ----
WORK="$(dirname "$DYLIB")"
STEP1="$WORK/_step1_strip.dylib"
STEP2="$WORK/_step2_rename.dylib"
FINAL="$WORK/_final.dylib"

log "后处理 1/3：strip（抹 mov x29,x29 标记）"
python3 "$POST" strip "$DYLIB" -o "$STEP1"

log "后处理 2/3：rename-selectors（保守模式 --skip-selrefs）"
python3 "$POST" rename-selectors "$STEP1" -o "$STEP2" --skip-selrefs --save-map "$WORK/sel_map.txt"

log "后处理 3/3：hide-exports"
python3 "$POST" hide-exports "$STEP2" -o "$FINAL"

# ---- 2b. 静态抹除（可选）：把已虚拟化函数体换成桩，让静态/dump 也看不到 ----
#   由 gen_multi_hooks.py 的 WIPE_MODE 生成 g_wipe_list.txt；为空则跳过。
#   ⚠️ 抹除去掉了「VM 失败回退原函数」的安全网，务必分批上机验证（起不来就缩名单）。
WIPE_LIST="${WIPE_LIST:-$(dirname "$DYLIB")/VMP/g_wipe_list.txt}"
if [ -s "$WIPE_LIST" ]; then
    log "静态抹除：按 $WIPE_LIST ($(grep -c . "$WIPE_LIST") 个函数)"
    python3 "$POST" wipe "$FINAL" --list "$WIPE_LIST" --fill "${WIPE_FILL:-nop}"
else
    log "静态抹除：无名单(WIPE_MODE=off)或为空，跳过"
fi

if command -v ldid >/dev/null 2>&1; then
    log "重签名（ldid -S）"
    ldid -S "$FINAL"
else
    log "⚠ 未找到 ldid，请手动重签 $FINAL（strip 改过 __text 必须重签）"
fi

# ---- 3. 自检 ----
log "效果自检（verify / report）"
python3 "$POST" verify "$FINAL" || true
python3 "$POST" report "$FINAL" || true

log "完成 → $FINAL"

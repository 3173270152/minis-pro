#!/usr/bin/env bash
# setup_ios_toolchain.sh — 在 Linux 上搭建 iOS arm64 构建环境（用于引擎编译验证）
#
# 已验证可用：Ubuntu clang 18 + iPhoneOS SDK + ld64.lld → 编译+链接 arm64 Mach-O dylib。
# 不需要 macOS。运行后得到：theos/（含 logos .xm 预处理）、一个 iPhoneOS SDK、工具链符号链接。
#
# 用法：  ./tools/setup_ios_toolchain.sh [工作目录]
# 产出：  $WORK/theos, $WORK/sdks/iPhoneOS16.5.sdk, $WORK/iostc/bin（clang/ld/lipo/otool…）
set -e
WORK="${1:-$PWD/_iosenv}"
mkdir -p "$WORK"; cd "$WORK"

echo "[1/4] 克隆 theos（含 logos/orion 子模块）"
[ -d theos ] || git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/theos/theos.git theos

echo "[2/4] 取一个 iPhoneOS SDK（partial+sparse，仅 16.5 ≈ 233MB）"
if [ ! -d sdks/iPhoneOS16.5.sdk ]; then
  git clone --filter=blob:none --no-checkout --depth 1 https://github.com/theos/sdks.git sdks
  ( cd sdks && git sparse-checkout init --cone && git sparse-checkout set iPhoneOS16.5.sdk && git checkout )
fi
ln -sfn "$WORK/sdks/iPhoneOS16.5.sdk" "$WORK/theos/sdks/iPhoneOS16.5.sdk"

echo "[3/4] 工具链符号链接（系统 llvm-18 → Apple 工具名）"
mkdir -p iostc/bin; cd iostc/bin
for p in "clang:clang" "clang++:clang++" "ld:ld64.lld-18" "lipo:llvm-lipo-18" \
         "otool:llvm-otool-18" "strip:llvm-strip-18" "nm:llvm-nm" "ar:llvm-ar" \
         "ranlib:llvm-ranlib-18" "install_name_tool:llvm-install-name-tool-18"; do
  ln -sf "$(command -v ${p##*:})" "${p%%:*}"
done
cd "$WORK"

echo "[4/4] 完成。构建引擎时用："
echo "    export SDK=$WORK/sdks/iPhoneOS16.5.sdk"
echo "    export THEOS=$WORK/theos"
echo "    export PATH=$WORK/iostc/bin:\$PATH"
echo "  然后 ./tools/verify_engine_ios.sh 做编译验证。"

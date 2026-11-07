#!/usr/bin/env bash
# 在 Linux 上用 clang+iPhoneOS SDK 对 VM 引擎做真·iOS arm64 编译验证。
# 用法: SDK=/path/to/iPhoneOS16.5.sdk ./tools/verify_engine_ios.sh
set -e
SDK="${SDK:?请设 SDK=iPhoneOS SDK 路径}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CC=clang
TARGET=arm64-apple-ios14.0
echo "[verify] 编译 vm_interp.c (arm64-ios, 含全部 handler)..."
$CC -target $TARGET -isysroot "$SDK" -I "$HERE/VMP" -I "$HERE/VMP/vm_handlers" \
    -Os -fno-stack-protector -fno-builtin -c "$HERE/VMP/vm_interp.c" -o /tmp/_vmi.o
echo "[verify] ✓ 编译通过 → /tmp/_vmi.o"
$CC -target $TARGET -isysroot "$SDK" -shared /tmp/_vmi.o -o /tmp/_vmi.dylib \
    -fuse-ld=lld -Wl,-undefined,dynamic_lookup -Wl,-install_name,@rpath/x.dylib
echo "[verify] ✓ 链接成 dylib → /tmp/_vmi.dylib"
file /tmp/_vmi.dylib

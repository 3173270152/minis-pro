#!/usr/bin/env python3
# gen_blobs.py - 生成 anti_debug_pro.c 用的黑名单加密表
# 目的: dylib 里不出现 "Frida" / "cycript" 这类明文, strings 搜不到
import sys

NAMES = [
    "Frida",          # 覆盖 FridaGadget / frida-agent / frida
    "gum-js-loop",
    "gum-js",
    "dumpdecrypted",
    "bagbak",
    "cycript",
    "Dobby",
    "Flex",
    "RevealServer",
    "LookinServer",
    "InjectionIII",
    "SSLKillSwitch",
]
KEY = 0x5A

out = []
out.append("// anti_blobs.h - 由 gen_blobs.py 生成, 勿手改")
out.append("// 黑名单按 0x5A 逐字节异或, 运行时在栈上还原后再 strstr")
out.append("#ifndef ANTI_BLOBS_H")
out.append("#define ANTI_BLOBS_H")
out.append("")
for i, n in enumerate(NAMES):
    enc = [c ^ KEY for c in n.encode("ascii")] + [0]
    body = ",".join("0x%02x" % b for b in enc)
    out.append("static const unsigned char gcob_n%d[] = {%s};" % (i, body))
out.append("")
out.append("typedef struct { const unsigned char *enc; unsigned len; } gcob_name_t;")
out.append("")
entries = ",".join("{gcob_n%d, %d}" % (i, len(n) + 1) for i, n in enumerate(NAMES))
out.append("static const gcob_name_t gcob_names[] = {%s};" % entries)
out.append("static const unsigned gcob_name_count = %d;" % len(NAMES))
out.append("")
out.append("#endif")

sys.stdout.write("\n".join(out) + "\n")

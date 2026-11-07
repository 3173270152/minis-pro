#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analyze_coverage.py — 按 LC_FUNCTION_STARTS 枚举全部函数，统计 vmp.py
可翻译率，并把失败按「具体指令/助记符」分桶（冲覆盖率用的精确数据）。

用法: python3 analyze_coverage.py <dylib> [--bc-limit N]
"""
import os, sys, struct
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmp


def scan_function_starts(buf):
    o = 32
    n = struct.unpack_from('<I', buf, 16)[0]
    foff = fsize = 0
    text_lo = text_hi = None
    oo = 32
    for _ in range(n):
        cmd, sz = struct.unpack_from('<II', buf, oo)
        if cmd == 0x26:
            foff, fsize = struct.unpack_from('<II', buf, oo + 8)
        if cmd == 0x19:  # LC_SEGMENT_64
            seg = buf[oo+8:oo+24].split(b'\0')[0].decode(errors='replace')
            ns = struct.unpack_from('<I', buf, oo+64)[0]; so = oo + 72
            for _j in range(ns):
                sn = buf[so:so+16].split(b'\0')[0].decode(errors='replace')
                a, s2 = struct.unpack_from('<QQ', buf, so+32)
                if seg == '__TEXT' and sn == '__text':
                    text_lo, text_hi = a, a + s2
                so += 80
        oo += sz
    funcs = []
    if fsize:
        p = foff; addr = 0; end = foff + fsize
        while p < end:
            delta = 0; shift = 0
            while p < end:
                b = buf[p]; p += 1
                delta |= (b & 0x7F) << shift; shift += 7
                if not (b & 0x80): break
            if delta == 0: break
            addr += delta
            funcs.append(addr)
    return funcs, (text_lo, text_hi)


def guess(w):
    if (w >> 24) & 0x1F == 0x11: return "ADD/SUB imm"
    if (w >> 24) & 0x1F == 0x12: return "logical imm / MOVN?"
    if (w >> 24) & 0x1F == 0x1E: return "FP/SIMD scalar"
    if (w >> 25) & 0xF == 0x7:   return "SIMD/FP vector"
    if (w >> 26) & 0x3F == 0x0D: return "LDP/STP?"
    if (w >> 24) & 0x1F == 0x0D: return "LD/ST variant"
    if (w & 0xFF000000) == 0xD5000000: return "system (MSR/MRS/barrier)"
    if (w & 0x7C000000) == 0x14000000: return "B/BL"
    return "?"


def main(dylib, bc_limit=2048):
    buf = open(dylib, "rb").read()
    funcs, (tlo, thi) = scan_function_starts(buf)
    if tlo is not None:
        funcs = [a for a in funcs if tlo <= a < thi]
    total = len(funcs)
    ok = 0
    reason = Counter()          # 翻译失败原因（粗）
    tr_mnem = Counter()         # 翻译失败：具体助记符
    dec_word = Counter()        # 解码失败：原始指令字
    dec_ex = {}
    too_long = 0
    for i, addr in enumerate(funcs):
        end = funcs[i+1] if i+1 < len(funcs) else addr + 0x4000
        insts, derr = vmp.decode_function(buf, addr, min(end, addr + 0x4000))
        if derr is not None and derr.startswith('解码失败'):
            # 解析出失败指令字
            try:
                w = int(derr.split('0x')[1].split()[0], 16)
            except Exception:
                w = 0
            reason['解码失败'] += 1
            dec_word[w] += 1
            dec_ex.setdefault(w, (addr, guess(w)))
            continue
        if not insts:
            reason['空函数/越界'] += 1; continue
        try:
            bc = vmp.translate(insts)
        except vmp.TransError as e:
            reason['翻译失败'] += 1
            msg = str(e)
            # 提取助记符/原因关键字
            key = msg.split('@')[0].strip()
            tr_mnem[key] += 1
            continue
        except Exception as e:
            reason['翻译异常'] += 1
            tr_mnem[('异常:' + str(e)[:30])] += 1
            continue
        if len(bc) > bc_limit:
            too_long += 1
            reason['字节码超限(%d)' % bc_limit] += 1
            continue
        ok += 1

    print("==== %s ====" % os.path.basename(dylib))
    print("LC_FUNCTION_STARTS(__text 内): %d 个函数" % total)
    print("可完整翻译(≤%dB): %d  (%.1f%%)" % (bc_limit, ok, 100.0*ok/max(1,total)))
    print()
    print("---- 失败大类 ----")
    for r, c in reason.most_common():
        print("  %5d  %s" % (c, r))
    print()
    print("---- 翻译失败：按原因/助记符（前 25）----")
    for m, c in tr_mnem.most_common(25):
        print("  %5d  %s" % (c, m))
    print()
    print("---- 解码失败：按指令编码（前 30）----")
    print("  %-10s %5s  %-26s %s" % ("word", "count", "guess", "example@off"))
    for w, c in dec_word.most_common(30):
        a, g = dec_ex[w]
        print("  0x%08x %5d  %-26s @0x%x" % (w, c, g, a))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    lim = 2048
    if '--bc-limit' in sys.argv:
        lim = int(sys.argv[sys.argv.index('--bc-limit')+1])
    main(args[0], lim)

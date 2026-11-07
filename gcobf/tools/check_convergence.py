#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_convergence.py — 自举收敛检测（对应 STATUS §3.5 地址漂移问题）

从 Mach-O 的 LC_FUNCTION_STARTS 取出全部函数入口地址集合，
与上一轮构建保存的快照比对，判断函数布局是否已稳定（收敛）。

用法:
    # 第一轮：建立基线
    python3 check_convergence.py <dylib> --save .conv_snapshot.json
    # 之后每轮：比对上一轮
    python3 check_convergence.py <dylib> --save .conv_snapshot.json --compare
    #   退出码 0 = 已收敛（与上一轮完全一致），1 = 仍在漂移

只读、纯标准库，可在设备上直接跑。
"""
import json
import os
import struct
import sys


def scan_function_starts(buf):
    """解析 LC_FUNCTION_STARTS (0x26)，返回函数入口地址（相对基址）列表。"""
    o = 32
    n = struct.unpack_from('<I', buf, 16)[0]
    foff = fsize = 0
    for _ in range(n):
        cmd, sz = struct.unpack_from('<II', buf, o)
        if cmd == 0x26:
            foff, fsize = struct.unpack_from('<II', buf, o + 8)
        o += sz
    if not fsize:
        return []
    funcs = []
    p = foff
    addr = 0
    end = foff + fsize
    while p < end:
        delta = 0
        shift = 0
        while p < end:
            b = buf[p]
            p += 1
            delta |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
        if delta == 0:
            break
        addr += delta
        funcs.append(addr)
    return funcs


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    snap_path = None
    if "--save" in argv:
        snap_path = argv[argv.index("--save") + 1]
    do_compare = "--compare" in argv

    with open(path, "rb") as f:
        buf = f.read()
    funcs = scan_function_starts(buf)
    print("[conv] %s: LC_FUNCTION_STARTS 共 %d 个函数入口" % (os.path.basename(path), len(funcs)))

    rc = 0
    if do_compare and snap_path and os.path.exists(snap_path):
        prev = json.load(open(snap_path))
        prev_funcs = prev.get("funcs", [])
        prev_set = set(prev_funcs)
        cur_set = set(funcs)
        added = sorted(cur_set - prev_set)
        removed = sorted(prev_set - cur_set)
        same_count = (len(prev_funcs) == len(funcs))
        if not added and not removed:
            print("[conv] ✓ 已收敛：函数入口集合与上一轮完全一致（%d 个）" % len(funcs))
            rc = 0
        else:
            print("[conv] ✗ 仍在漂移：新增 %d，消失 %d（数量 %d → %d）"
                  % (len(added), len(removed), len(prev_funcs), len(funcs)))
            for a in added[:8]:
                print("        + 0x%x" % a)
            for a in removed[:8]:
                print("        - 0x%x" % a)
            rc = 1
    elif do_compare:
        print("[conv] （无上一轮快照，本轮仅建立基线）")

    if snap_path:
        json.dump({"count": len(funcs), "funcs": funcs}, open(snap_path, "w"))
        print("[conv] 快照已写入 %s" % snap_path)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

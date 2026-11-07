#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_isa.py — ISA 多态：每次构建随机打乱 opcode 编码表。

VMProtect 招牌手法之一：每个 build 的虚拟指令集编码都不同。逆向者逆完一个 build
的解释器，换个 build 全作废，也无法用通用 opcode 表批量解码 __vmpbc。

做法：对「所有 opcode 用到的字节值」做一个随机**双射** π（byte→byte）。
对 C 侧(vm_opcodes.h)和 Python 侧(vmp.py / optable.py)施加同一个 π → 天然对齐。
因为 C 侧全部通过 OP_ 宏使用，重新生成 vm_opcodes.h 即整体换编码，无需改逻辑。

用法：
    python3 tools/vmp/gen_isa.py            # 生成随机 ISA → 覆盖 vm_opcodes.h + 写 op_perm.json
    python3 tools/vmp/gen_isa.py --seed 123 # 可复现
然后构建时设 GCOBF_ISA=<op_perm.json 路径>，vmp.py / optable.py 会读它套用同一置换。
默认不设 = 用原固定 ISA（零回归）。
"""
import os, re, sys, json, random

HERE = os.path.dirname(os.path.abspath(__file__))
VM_OPCODES_H = os.path.normpath(os.path.join(HERE, "..", "..", "VMP", "vm_opcodes.h"))
VMP_PY = os.path.join(HERE, "vmp.py")
PERM_JSON = os.path.join(HERE, "op_perm.json")


def parse_defines(path):
    """解析 vm_opcodes.h（含多行续行）→ [(name, value)]。"""
    txt = open(path, encoding="utf-8").read().replace("\\\n", " ")
    out = []
    for m in re.finditer(r"#define\s+(OP_\w+)\s+(0x[0-9A-Fa-f]+|\d+)", txt):
        out.append((m.group(1), int(m.group(2), 0)))
    return out


def parse_vmp_values(path):
    txt = open(path, encoding="utf-8").read()
    vals = set()
    for m in re.finditer(r"^OP_\w+\s*=\s*(0x[0-9A-Fa-f]+)", txt, re.M):
        vals.add(int(m.group(1), 0))
    return vals


def main(argv):
    seed = None
    if "--seed" in argv:
        seed = int(argv[argv.index("--seed") + 1])
    random.seed(seed)

    defs = parse_defines(VM_OPCODES_H)
    used = set(v for _, v in defs) | parse_vmp_values(VMP_PY)
    used = sorted(used)
    # 随机双射 π：used 的一个随机排列
    shuffled = used[:]
    random.shuffle(shuffled)
    perm = {old: new for old, new in zip(used, shuffled)}
    # 自映射校验：双射、无碰撞
    assert len(set(perm.values())) == len(perm), "π 非双射"

    # 1) 重写 vm_opcodes.h（保留名字，换值；扁平 #define，C 侧全走宏）
    lines = [
        "/* vm_opcodes.h — ISA 多态生成 (gen_isa.py)。每次构建编码不同。",
        " * 名字不变、值按随机双射 π 重排；C 侧全部通过 OP_ 宏使用，故仅此文件变。",
        " */",
        "#ifndef VM_OPCODES_H",
        "#define VM_OPCODES_H",
        "",
    ]
    for name, val in defs:
        lines.append("#define %-16s 0x%02X" % (name, perm[val]))
    lines += ["", "#endif /* VM_OPCODES_H */", ""]
    open(VM_OPCODES_H, "w", encoding="utf-8").write("\n".join(lines))

    # 2) 写 perm.json（old→new，字符串键便于 json）
    json.dump({str(k): v for k, v in perm.items()}, open(PERM_JSON, "w"), indent=0)

    print("[gen_isa] 已生成随机 ISA：%d 个 opcode 值重排" % len(perm))
    print("[gen_isa] 覆盖: %s" % VM_OPCODES_H)
    print("[gen_isa] 置换表: %s" % PERM_JSON)
    print("[gen_isa] 构建时设环境变量: export GCOBF_ISA=%s" % PERM_JSON)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

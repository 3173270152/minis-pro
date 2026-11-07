#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""VM 字节码完整模拟器 v3
支持：MOV/MOVK/UBFM/LOAD*/STORE*/LOAD_LIT*/LOAD_IDX*/CALL_LIT/pre-post-index/ALU/分支
用途：在编译前验证 vmp.py 生成的字节码是否与 ARM64 语义一致
"""
import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from optable import OPNAME

OP = {name: val for val, name in OPNAME.items()}

FZ, FN, FC = 1, 2, 4
MASK64 = (1 << 64) - 1

def sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v

def dec(bc, pc, key):
    kb = (key >> ((pc & 3) * 8)) & 0xFF
    return bc[pc] ^ ((kb ^ (pc * 0x9E3779B9)) & 0xFF)

def run(bc, key, R, mem, trace=True, max_steps=5000):
    """mem: dict{addr: byte} 模拟内存；CALL_LIT 返回 0"""
    FL = 0
    pc = 0
    n = 0
    calls = []
    estk = []   # v-bcjunk: eval 操作栈(栈机 op / 中性垃圾用)
    while 0 <= pc < len(bc):
        n += 1
        if n > max_steps:
            return "LOOP", pc, n, calls
        op = dec(bc, pc, key)
        # ---- 栈机 eval-stack op(按真实 opcode 值直接处理, 绕过 optable 里 0x09/0x0A 的错标)----
        #   0x04 PUSH_IMM64 0x05 DUP 0x07 DROP 0x09 ADD 0x0A SUB 0x0B MUL 0x0C XOR 0x0D AND 0x0E OR
        if op in (0x04, 0x05, 0x07, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E):
            if op == 0x04:
                estk.append(struct.unpack_from("<Q", bc, pc+1)[0]); pc += 9
            elif op == 0x05:
                estk.append(estk[-1] if estk else 0); pc += 1
            elif op == 0x07:
                if estk: estk.pop()
                pc += 1
            else:
                b_ = estk.pop() if estk else 0
                a_ = estk.pop() if estk else 0
                r_ = {0x09: a_ + b_, 0x0A: a_ - b_, 0x0B: a_ * b_,
                      0x0C: a_ ^ b_, 0x0D: a_ & b_, 0x0E: a_ | b_}[op] & MASK64
                estk.append(r_); pc += 1
            continue
        nm = OPNAME.get(op)
        line = "  pc=%4d op=0x%02x %-12s" % (pc, op, nm or "UNKNOWN")
        if nm is None:
            print(line + " <-- 非法")
            return "UNKNOWN", pc, n, calls
        try:
            if nm == "HALT":
                if trace: print(line + " R0=0x%x" % R[0])
                return "HALT", pc, n, calls
            elif nm == "NOP":
                pc += 1
            elif nm == "MOV_IMM":
                d = bc[pc+1]; R[d & 31] = struct.unpack_from("<Q", bc, pc+2)[0]; pc += 10
                if trace: print(line + " R%d=0x%x" % (d & 31, R[d & 31]))
            elif nm == "MOV_IMM32":
                d = bc[pc+1]; R[d & 31] = struct.unpack_from("<I", bc, pc+2)[0]; pc += 6
                if trace: print(line + " R%d=0x%x" % (d & 31, R[d & 31]))
            elif nm == "MOV_REG":
                d = bc[pc+1]; s = bc[pc+2]; R[d & 31] = R[s & 31]; pc += 3
                if trace: print(line + " R%d <- R%d" % (d & 31, s & 31))
            elif nm == "MOVK":
                d = bc[pc+1]; imm = struct.unpack_from("<H", bc, pc+2)[0]
                hw = bc[pc+4] & 3; sh = 16 * hw
                R[d & 31] = (R[d & 31] & ~(0xFFFF << sh)) | (imm << sh)
                R[d & 31] &= MASK64
                pc += 5
                if trace: print(line + " R%d=0x%x" % (d & 31, R[d & 31]))
            elif nm == "UBFM":
                d = bc[pc+1]; s = bc[pc+2]; immr = bc[pc+3]; imms = bc[pc+4]; sf = bc[pc+5] & 1
                w = 64 if sf else 32
                src = R[s & 31] & ((1 << w) - 1)
                r = immr & (w - 1); sm = imms & (w - 1)
                if sm >= r:
                    res = (src >> r) & ((1 << (sm - r + 1)) - 1)
                else:
                    res = ((src >> r) | (src << (w - r))) & ((1 << (sm + 1)) - 1)
                R[d & 31] = res & ((1 << w) - 1)
                pc += 6
                if trace: print(line + " R%d=0x%x" % (d & 31, R[d & 31]))
            elif nm in ("ADD", "SUB", "AND", "OR", "XOR"):
                d = bc[pc+1]; a = bc[pc+2]; b = bc[pc+3]
                va, vb = R[a & 31], R[b & 31]
                R[d & 31] = {"ADD": va + vb, "SUB": va - vb,
                             "AND": va & vb, "OR": va | vb, "XOR": va ^ vb}[nm] & MASK64
                pc += 4
                if trace: print(line + " R%d=0x%x" % (d & 31, R[d & 31]))
            elif nm in ("ADD_IMM", "SUB_IMM", "AND_IMM", "OR_IMM", "XOR_IMM", "MUL_IMM"):
                d = bc[pc+1]; s = bc[pc+2]; imm = struct.unpack_from("<I", bc, pc+3)[0]
                va = R[s & 31]
                R[d & 31] = {"ADD_IMM": va + imm, "SUB_IMM": va - imm,
                             "AND_IMM": va & imm, "OR_IMM": va | imm,
                             "XOR_IMM": va ^ imm, "MUL_IMM": va * imm}[nm] & MASK64
                pc += 7
                if trace: print(line + " R%d=0x%x (imm=0x%x)" % (d & 31, R[d & 31], imm))
            elif nm in ("LOAD8", "LOAD16", "LOAD32", "LOAD64"):
                d = bc[pc+1]; b = bc[pc+2]; off = struct.unpack_from("<h", bc, pc+3)[0]
                addr = (R[b & 31] + off) & MASK64
                w = {"LOAD8": 1, "LOAD16": 2, "LOAD32": 4, "LOAD64": 8}[nm]
                val = 0
                for i in range(w):
                    val |= mem.get(addr + i, 0) << (8 * i)
                R[d & 31] = val
                pc += 5
                if trace: print(line + " R%d = [0x%x] = 0x%x" % (d & 31, addr, val))
            elif nm in ("STORE8", "STORE16", "STORE32", "STORE64"):
                b = bc[pc+1]; s = bc[pc+2]; off = struct.unpack_from("<h", bc, pc+3)[0]
                addr = (R[b & 31] + off) & MASK64
                w = {"STORE8": 1, "STORE16": 2, "STORE32": 4, "STORE64": 8}[nm]
                val = R[s & 31]
                for i in range(w):
                    mem[addr + i] = (val >> (8 * i)) & 0xFF
                pc += 5
                if trace: print(line + " [0x%x] = 0x%x" % (addr, val & ((1 << (8*w)) - 1)))
            elif nm.startswith("LOAD_LIT"):
                d = bc[pc+1]; off = struct.unpack_from("<I", bc, pc+2)[0]
                addr = (R[28] + off) & MASK64
                w = {"LOAD_LIT8": 1, "LOAD_LIT16": 2, "LOAD_LIT32": 4, "LOAD_LIT64": 8}[nm]
                val = 0
                for i in range(w):
                    val |= mem.get(addr + i, 0) << (8 * i)
                R[d & 31] = val
                pc += 6
                if trace: print(line + " R%d = [base+0x%x] = 0x%x" % (d & 31, off, val))
            elif nm.startswith("LOAD_IDX"):
                d = bc[pc+1]; n_ = bc[pc+2]; m = bc[pc+3]; sh = bc[pc+4] & 0x3F
                addr = (R[n_ & 31] + (R[m & 31] << sh)) & MASK64
                w = {"LOAD_IDX8": 1, "LOAD_IDX16": 2, "LOAD_IDX32": 4, "LOAD_IDX64": 8}[nm]
                val = 0
                for i in range(w):
                    val |= mem.get(addr + i, 0) << (8 * i)
                R[d & 31] = val
                pc += 5
                if trace: print(line + " R%d = [0x%x] = 0x%x" % (d & 31, addr, val))
            elif nm.startswith("STORE_IDX"):
                b = bc[pc+1]; n_ = bc[pc+2]; m = bc[pc+3]; sh = bc[pc+4] & 0x3F
                addr = (R[b & 31] + (R[m & 31] << sh)) & MASK64
                w = {"STORE_IDX8": 1, "STORE_IDX16": 2, "STORE_IDX32": 4, "STORE_IDX64": 8}[nm]
                val = R[n_ & 31]
                for i in range(w):
                    mem[addr + i] = (val >> (8 * i)) & 0xFF
                pc += 5
                if trace: print(line + " [0x%x] = 0x%x" % (addr, val))
            elif nm == "CALL_LIT":
                off = struct.unpack_from("<I", bc, pc+1)[0]
                target = (R[28] + off) & MASK64
                calls.append(target)
                if trace: print(line + " call 0x%x (R0=0x%x R1=0x%x)" % (target, R[0], R[1]))
                R[0] = 0x1234567890   # FAKE_OBJ: 模拟 objc_msgSend 返回非 nil
                pc += 5
            elif nm == "CMP_IMM":
                r = bc[pc+1]; imm = struct.unpack_from("<I", bc, pc+2)[0]
                va, vb = R[r & 31], imm
                FL = 0
                if va == vb: FL |= FZ
                if sx(va, 64) < vb: FL |= FN
                if va < vb: FL |= FC
                pc += 6
            elif nm == "CMP":
                a = bc[pc+1]; b_ = bc[pc+2]; va, vb = R[a & 31], R[b_ & 31]
                FL = 0
                if va == vb: FL |= FZ
                if sx(va, 64) < sx(vb, 64): FL |= FN
                if va < vb: FL |= FC
                pc += 3
            elif nm == "JMP":
                off = struct.unpack_from("<I", bc, pc+1)[0]; pc = off
                if trace: print(line + " -> 0x%x" % off)
            elif nm in ("JE", "JNE", "JGT", "JLE", "JL", "JGE", "JB", "JAE"):
                off = struct.unpack_from("<I", bc, pc+1)[0]
                cond = {"JE": bool(FL & FZ), "JNE": not (FL & FZ),
                        "JGT": (not (FL & FZ)) and (not (FL & FN)),
                        "JLE": bool(FL & FZ) or bool(FL & FN),
                        "JL": bool(FL & FN), "JGE": not (FL & FN),
                        "JB": bool(FL & FC), "JAE": not (FL & FC)}[nm]
                if trace: print(line + " %s -> %s" % (cond, ("0x%x" % off) if cond else "next"))
                pc = off if cond else pc + 5
            else:
                print(line + " <-- 模拟器未实现")
                return "UNIMPL", pc, n, calls
        except Exception as ex:
            print(line + " <-- 执行异常: %s" % ex)
            return "ERROR", pc, n, calls
    return "EOF", pc, n, calls

if __name__ == "__main__":
    import vmp
    dylib = sys.argv[1]
    addr = int(sys.argv[2], 0)
    raw = open(dylib, "rb").read()
    insts, pos = [], 0
    while pos < 0x2000:
        w = struct.unpack_from("<I", raw, addr + pos)[0]
        d = vmp.decode(w)
        if d is None:
            print("解码失败 @ +0x%x (0x%08x)" % (pos, w)); break
        insts.append((addr + pos, w))
        pos += 4
        if d[0] == "ret": break
    bc = vmp.translate(insts)
    body = bc[:-25]
    key = struct.unpack_from("<I", bc, len(bc) - 24)[0] & 0xFF
    print("函数@0x%x: %d 条 ARM64 -> %d 字节 VM (oc_key=0x%x)" % (addr, len(insts), len(body), key))
    R = [0] * 32
    R[28] = 0x100000000          # image base
    R[31] = 0x200000000          # 虚拟栈顶（模拟）
    for i in range(8): R[i] = 0
    mem = {}
    st, p, n, calls = run(body, key, R, mem)
    print("\n结果: %s @pc=0x%x, %d 步, 调用 %d 次" % (st, p, n, len(calls)))

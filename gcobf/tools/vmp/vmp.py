#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vmp.py — ARM64 → VMPacker VM 字节码 + Mach-O 注入

VMPacker 原生只处理 ELF(Go)。这里用 Python 重新实现了一条 Mach-O 链路:
    ARM64 指令 → 解码 → 虚拟机字节码 → 注入 dylib 新段 → 重写函数入口为跳板

用法:
    python3 vmp.py <dylib> --func <符号名> [--out out.dylib] [-v]
    python3 vmp.py <dylib> --addr 0xADDR:SIZE[:name] [...]

限制(当前子集, 遇到不支持的指令会跳过该函数并报告):
    MOVZ/MOVK/MOVN, MOV(reg), ADD/SUB/AND/ORR/EOR(reg), ADD/SUB(imm),
    MUL, LSL/LSR/ASR(imm), CMP/CMN(reg/imm), LDR/STR/LDRB/STRB/LDRH/STRH,
    B, BL, B.cond, CBZ/CBNZ, RET, NOP
"""
import os
import struct
import sys

# ============================================================
# VM 指令集 (与 stub/ios/arm64/vm_opcodes.h 一一对应)
# ============================================================
OP_NOP        = 0xC3
OP_MOV_IMM    = 0x5A   # [op][r][imm64]  10B
OP_MOV_IMM32  = 0x49   # [op][r][imm32]   6B
OP_MOV_REG    = 0x2F   # [op][dst][src]   3B
OP_LOAD8      = 0x91
OP_LOAD16     = 0xE7
OP_LOAD32     = 0xA4
OP_LOAD64     = 0xB7
OP_LOAD_LIT8 = 0x56
OP_LOAD_LIT16 = 0x57
OP_LOAD_LIT32 = 0x59
OP_LOAD_LIT64 = 0x5B
OP_CALL_LIT    = 0xF5  # [op][imm32]  call R28+imm
OP_LOAD_IDX8   = 0xF6  # [op][rt][rn][rm][sh]  R[rt] = *(u8*)(Rn + (Rm<<sh))
OP_LOAD_IDX16  = 0xF7
OP_LOAD_IDX32  = 0xF8
OP_LOAD_IDX64  = 0xF9
OP_STORE_IDX8  = 0xFA
OP_STORE_IDX16 = 0xFB
OP_STORE_IDX32 = 0xFC
OP_STORE_IDX64 = 0xFD
OP_MOVK       = 0xFE
OP_FMOV_REG = 0x40
OP_FADD = 0x41
OP_FSUB = 0x42
OP_FMUL = 0x43
OP_FDIV = 0x45
OP_FNEG = 0x46
OP_FABS = 0x48
OP_FCVT_S2D   = 0x09
OP_FCVT_D2S   = 0x0A
OP_SCVTF = 0x4B
OP_UCVTF = 0x4C
OP_FCVTZS = 0x4E
OP_FCVTZU = 0x4F
OP_FCMP = 0x50
OP_LOAD_FP = 0x51
OP_STORE_FP = 0x54
OP_FMOV_IMM = 0x55
OP_UBFM       = 0xEF  # [op][rd][rn][immr][imms][sf]  位域提取/插入  # [op][rd][imm16][hw]  Xd = (Xd & ~(0xFFFF<<sh)) | (imm<<sh)
OP_STORE8     = 0xD2
OP_STORE16    = 0xE8
OP_STORE32    = 0x19
OP_STORE64    = 0x2A
OP_ADD        = 0x37   # [op][d][a][b]
OP_SUB        = 0x6E
OP_MUL        = 0x83
OP_XOR        = 0x1B
OP_AND        = 0x4D
OP_OR         = 0x72
OP_TST        = 0x30   # [op][rn][rm][pad]  4B
OP_FMOV_GEN   = 0x31   # [op][fd][rn]       3B
OP_EXTR       = 0x32   # [op][rd][rn][rm][lsb][sf]  6B
OP_TBZ        = 0x16   # [op][reg][bit][target32]  7B
OP_TBNZ       = 0x17
OP_ROR        = 0x3D   # ROR Xd, Xn, Xm  4B
OP_SHL        = 0xAE
OP_SHR        = 0xF1
OP_ASR        = 0xDA
OP_NOT        = 0x08
OP_ADD_IMM    = 0xE5
OP_SUB_IMM    = 0x78
OP_XOR_IMM    = 0x3C
OP_AND_IMM    = 0xD9
OP_OR_IMM     = 0x6B
OP_MUL_IMM    = 0xB3
OP_SHL_IMM    = 0x7A
OP_SHR_IMM    = 0x8C
OP_ASR_IMM    = 0x9D
OP_CMP        = 0x9F
OP_CMP_IMM    = 0xA1
OP_JMP        = 0x44
OP_JE         = 0x58
OP_JNE        = 0xBB
OP_JL         = 0x15
OP_JGE        = 0x29
OP_JGT        = 0x36
OP_JLE        = 0x47
OP_JB         = 0x52
OP_JAE        = 0x64
OP_JBE        = 0x53
OP_JA         = 0x65
OP_PUSH       = 0x63
OP_POP        = 0x27
OP_CALL_NATIVE= 0xAB   # [op][imm64] 9B
OP_CALL_REG   = 0xBC   # [op][rn]
OP_BR_REG     = 0xCD
OP_RET        = 0xEE   # [op][rn]
OP_HALT       = 0x00
# 条件比较 (handler/opcode 早已存在于 VM, 这里补 decode/translate)
OP_CCMP_REG   = 0x18   # [op][cond][nzcv][rn][rm][sf]   6B
OP_CCMP_IMM   = 0x1A   # [op][cond][nzcv][rn][imm5][sf] 6B
OP_CCMN_REG   = 0x1C
OP_CCMN_IMM   = 0x1D
# v-cov80: 浮点标量 + 浮点字面量加载
OP_FMAX        = 0x33  # [op][d][n][m][sf]   5B
OP_FMIN        = 0x34  # [op][d][n][m][sf]   5B
OP_FSQRT       = 0x35  # [op][d][n][sf]      4B
OP_FRINT       = 0x38  # [op][d][n][sf][mode] 5B
OP_LOAD_LIT_FP = 0x39  # [op][rt][imm32][sz]  7B
# v-neon: NEON/AdvSIMD (值与 vm_opcodes.h 一致)
OP_VMOVI = 0x3A  # [op][vd][lo64][hi64]            18B
OP_VLDR  = 0x3B  # [op][vt][rn][off16][q]          6B
OP_VSTR  = 0x3E  # [op][vt][rn][off16][q]          6B
OP_V3S   = 0x3F  # [op][vd][vn][vm][esz][u][opc][q] 8B
OP_V2S   = 0x5C  # [op][vd][vn][esz][u][opc][q]    7B
OP_VDUPE = 0x5D  # [op][vd][vn][esz][idx][q]       6B
OP_VDUPG = 0x5E  # [op][vd][rn][esz][q]            5B
OP_VINSE = 0x5F  # [op][vd][vn][esz][didx][sidx]   6B
OP_VINSG = 0x60  # [op][vd][rn][esz][didx]         5B
OP_VUMOV = 0x61  # [op][rd][vn][esz][idx][sgn]     6B
OP_VEXT  = 0x62  # [op][vd][vn][vm][idx][q]        6B
OP_VPERM = 0x66  # [op][vd][vn][vm][esz][kind][q]  7B
OP_VFMA  = 0x67  # [op][vd][vn][vm][esz][sub][q]   7B
OP_FMADD  = 0x68 # [op][d][n][m][a][sf][flags]     7B
OP_FCMP_Z = 0x69 # [op][n][sf]                     3B
OP_FCSEL  = 0x6A # [op][d][n][m][cond][sf]         6B
# v-bcjunk: eval-stack 中性垃圾所需的栈机 opcode(值与 vm_opcodes.h 一致)
OP_S_PUSH_IMM64 = 0x04
OP_S_DUP  = 0x05
OP_S_DROP = 0x07
OP_S_ADD  = 0x09
OP_S_SUB  = 0x0A
OP_S_MUL  = 0x0B
OP_S_XOR  = 0x0C
OP_S_AND  = 0x0D
OP_S_OR   = 0x0E

# ★ v-isa: ISA 多态。若设了 GCOBF_ISA=<op_perm.json>，按同一随机双射 π 重排上面所有
#   OP_ 值（与 vm_opcodes.h / optable.py 一致）。默认不设 = 原固定 ISA，零回归。
def _apply_isa_perm():
    import os, json
    p = os.environ.get("GCOBF_ISA")
    if not p or not os.path.exists(p):
        return
    perm = json.load(open(p))  # {"旧值": 新值}
    g = globals()
    for k in list(g):
        if k.startswith("OP_") and isinstance(g[k], int):
            nv = perm.get(str(g[k]))
            if nv is not None:
                g[k] = nv
_apply_isa_perm()


# ============================================================
# ARM64 解码 (只覆盖常用子集)
# ============================================================
def sx(v, bits):
    """符号扩展"""
    m = 1 << (bits - 1)
    return (v ^ m) - m


def _bitmask_imm(n, imms, immr, sf):
    """ARM64 logical immediate 的 N:immr:imms -> 实际掩码"""
    wid = 64 if sf else 32
    x = (n << 6) | ((~imms) & 0x3F)
    if x == 0:
        return None
    l = x.bit_length() - 1
    if l < 1:
        return None
    size = 1 << l
    if size > wid:
        return None
    S = imms & (size - 1)
    R = immr & (size - 1)
    if S == size - 1:
        return None
    welem = (1 << (S + 1)) - 1
    if R:
        welem = ((welem >> R) | (welem << (size - R))) & ((1 << size) - 1)
    mask = 0
    for i in range(0, 64, size):
        mask |= welem << i
    if not sf:
        mask &= 0xFFFFFFFF
    return mask


def _vfp_expand_imm(imm8, N):
    """ARM VFPExpandImm：8 位编码 → IEEE 浮点位模式（N=32 单精度 / 64 双精度）。"""
    E = 8 if N == 32 else 11
    F = N - E - 1
    sign = (imm8 >> 7) & 1
    b6 = (imm8 >> 6) & 1
    # exp = NOT(b6) : (b6 重复 E-3 次) : imm8<5:4>
    exp = ((b6 ^ 1) << (E - 1))
    rep = (0 if b6 == 0 else ((1 << (E - 3)) - 1)) << 2
    exp |= rep
    exp |= (imm8 >> 4) & 0x3
    frac = ((imm8 & 0xF) << (F - 4))
    return (sign << (N - 1)) | (exp << F) | frac


# ============================================================
# v-neon: NEON / AdvSIMD 解码 (覆盖业务高频子集)
# ============================================================
def _adv_simd_expand_imm(op, cmode, imm8):
    """ARM AdvSIMDExpandImm → 64 位模式(随后复制成 128 位)。返回 None 表示该 cmode 不处理。"""
    cm_hi = (cmode >> 1) & 7
    cm0 = cmode & 1
    if cm_hi <= 5 and cm0 == 1:
        return None  # ORR/BIC 立即数(读目标), 不处理
    if cm_hi == 0:
        imm32 = imm8
    elif cm_hi == 1:
        imm32 = imm8 << 8
    elif cm_hi == 2:
        imm32 = imm8 << 16
    elif cm_hi == 3:
        imm32 = imm8 << 24
    elif cm_hi == 4:
        imm16 = imm8
        v = imm16 * 0x0001000100010001
        return (~v & 0xFFFFFFFFFFFFFFFF) if op else v
    elif cm_hi == 5:
        imm16 = imm8 << 8
        v = imm16 * 0x0001000100010001
        return (~v & 0xFFFFFFFFFFFFFFFF) if op else v
    elif cm_hi == 6:
        imm32 = ((imm8 << 8) | 0xFF) if cm0 == 0 else ((imm8 << 16) | 0xFFFF)
    else:  # cm_hi == 7
        if cm0 == 0:
            if op == 0:   # MOVI: imm8 复制到每个字节
                v = 0
                for i in range(8):
                    v |= imm8 << (8 * i)
                return v
            else:         # MOVI 2D: 每 bit 展开成一个字节 0xFF/0x00
                v = 0
                for i in range(8):
                    if imm8 & (1 << i):
                        v |= 0xFF << (8 * i)
                return v
        else:  # cmode=1111
            if op == 0:   # FMOV vec S imm
                bits = _vfp_expand_imm(imm8, 32)
                return (bits << 32) | bits
            else:         # FMOV vec D imm (AArch64)
                return _vfp_expand_imm(imm8, 64)
    v = (imm32 << 32) | imm32
    return (~v & 0xFFFFFFFFFFFFFFFF) if op else v


def _imm5_esz_idx(imm5):
    if imm5 & 1:   return 0, imm5 >> 1
    if imm5 & 2:   return 1, imm5 >> 2
    if imm5 & 4:   return 2, imm5 >> 3
    if imm5 & 8:   return 3, imm5 >> 4
    return None, None


def _decode_neon(w):
    """NEON/AdvSIMD 子集 → (mn, operands)；不认识返回 None。"""
    # ---- 修饰立即数 (movi/mvni/fmov vec) ----
    if (w & 0x9FF80400) == 0x0F000400:
        Q = (w >> 30) & 1
        op = (w >> 29) & 1
        cmode = (w >> 12) & 0xF
        imm8 = (((w >> 16) & 7) << 5) | ((w >> 5) & 0x1F)
        rd = w & 31
        v64 = _adv_simd_expand_imm(op, cmode, imm8)
        if v64 is None:
            return None
        lo = v64
        hi = v64 if Q else 0
        return ('vmovi', {'vd': rd, 'lo': lo & 0xFFFFFFFFFFFFFFFF, 'hi': hi & 0xFFFFFFFFFFFFFFFF})

    # ---- LDR/STR Q (128 位, 无符号偏移) ----  off 必须落在有符号 16 位内, 否则跳过
    if (w & 0xFFC00000) == 0x3DC00000:   # LDR q
        imm = ((w >> 10) & 0xFFF) << 4
        return ('vldr', {'vt': w & 31, 'rn': (w >> 5) & 31, 'off': imm, 'q': 1}) if imm <= 32767 else None
    if (w & 0xFFC00000) == 0x3D800000:   # STR q
        imm = ((w >> 10) & 0xFFF) << 4
        return ('vstr', {'vt': w & 31, 'rn': (w >> 5) & 31, 'off': imm, 'q': 1}) if imm <= 32767 else None
    # ---- LDUR/STUR Q (128 位, 无缩放 9 位) ----
    if (w & 0xFFE00C00) == 0x3CC00000:
        return ('vldr', {'vt': w & 31, 'rn': (w >> 5) & 31, 'off': sx((w >> 12) & 0x1FF, 9), 'q': 1})
    if (w & 0xFFE00C00) == 0x3C800000:
        return ('vstr', {'vt': w & 31, 'rn': (w >> 5) & 31, 'off': sx((w >> 12) & 0x1FF, 9), 'q': 1})

    # ---- three-same (bit21=1, bit10=1, bits28:24=01110) ----
    if (w & 0x9F200400) == 0x0E200400:
        Q = (w >> 30) & 1
        U = (w >> 29) & 1
        size = (w >> 22) & 3
        Rm = (w >> 16) & 31
        opcode = (w >> 11) & 0x1F
        Rn = (w >> 5) & 31
        Rd = w & 31
        sz = size & 1            # FP: 0=S 1=D
        esz_fp = 3 if sz else 2
        # FP three-same(按精确 opcode 匹配)
        # fadd:opc=0x1A U0 sizehi0 / fsub:0x1A U0 sizehi1 / fmul:0x1B U1 sizehi0 / fdiv:0x1F U1 sizehi0
        # fmla:0x19 U0 sizehi0 / fmls:0x19 U0 sizehi1 / fmax:0x1E U0 sizehi0 / fmin:0x1E U0 sizehi1
        # fcmeq:0x1C U0 / fcmge:0x1C U1 sizehi0 / fcmgt:0x1C U1 sizehi1 / fabd:0x1A U1 sizehi1
        sizehi = (size >> 1) & 1
        if opcode == 0x19 and U == 0:        # FMLA/FMLS
            return ('vfma', {'vd': Rd, 'vn': Rn, 'vm': Rm, 'esz': esz_fp, 'sub': sizehi, 'q': Q})
        fp_opc = None
        if opcode == 0x1A and U == 0: fp_opc = 33 if sizehi else 32   # fsub/fadd
        elif opcode == 0x1B and U == 1 and sizehi == 0: fp_opc = 34   # fmul
        elif opcode == 0x1F and U == 1 and sizehi == 0: fp_opc = 35   # fdiv
        elif opcode == 0x1E and U == 0: fp_opc = 37 if sizehi else 36 # fmin/fmax
        elif opcode == 0x1C and U == 0 and sizehi == 0: fp_opc = 38   # fcmeq
        elif opcode == 0x1C and U == 1: fp_opc = 40 if sizehi == 0 else 39  # fcmge/fcmgt
        elif opcode == 0x1A and U == 1 and sizehi == 1: fp_opc = 41   # fabd
        if fp_opc is not None:
            return ('v3s', {'vd': Rd, 'vn': Rn, 'vm': Rm, 'esz': esz_fp, 'u': 0, 'opc': fp_opc, 'q': Q})
        # 整数 three-same
        int_opc = None
        if opcode == 0x10: int_opc = 1 if U else 0          # SUB/ADD
        elif opcode == 0x13 and U == 0 and size <= 2: int_opc = 2  # MUL
        elif opcode == 0x03:
            if U == 0:
                int_opc = {0: 3, 1: 6, 2: 4, 3: 7}[size]    # AND/BIC/ORR/ORN
            elif U == 1 and size == 0:
                int_opc = 5                                  # EOR
        elif opcode == 0x06: int_opc = 9                     # CMGT/CMHI
        elif opcode == 0x07: int_opc = 10                    # CMGE/CMHS
        elif opcode == 0x11 and U == 1: int_opc = 8          # CMEQ
        elif opcode == 0x0C: int_opc = 13                    # SMAX/UMAX
        elif opcode == 0x0D: int_opc = 14                    # SMIN/UMIN
        if int_opc is not None:
            return ('v3s', {'vd': Rd, 'vn': Rn, 'vm': Rm, 'esz': size, 'u': U, 'opc': int_opc, 'q': Q})
        return None

    # ---- two-reg misc (bits21:17=10000, bits11:10=10) ----
    if (w & 0x9F3E0C00) == 0x0E200800:
        Q = (w >> 30) & 1
        U = (w >> 29) & 1
        size = (w >> 22) & 3
        opcode = (w >> 12) & 0x1F
        Rn = (w >> 5) & 31
        Rd = w & 31
        if size >= 2:    # FP two-reg misc (size = 1sz)
            sz = size & 1
            esz = 3 if sz else 2
            o = None
            if opcode == 0x0F: o = 32 if U else 33   # FNEG/FABS
            elif opcode == 0x1F and U == 1: o = 34   # FSQRT
            elif opcode == 0x1D: o = 41 if U else 40 # UCVTF/SCVTF
            elif opcode == 0x1B: o = 43 if U else 42 # FCVTZU/FCVTZS
            if o is not None:
                return ('v2s', {'vd': Rd, 'vn': Rn, 'esz': esz, 'u': U, 'opc': o, 'q': Q})
            return None
        else:            # 整数 two-reg misc
            o = None
            if opcode == 0x0B: o = 0 if U else 1     # NEG/ABS
            elif opcode == 0x05 and U == 1: o = 2    # NOT
            if o is not None:
                return ('v2s', {'vd': Rd, 'vn': Rn, 'esz': size, 'u': U, 'opc': o, 'q': Q})
            return None

    # ---- copy (dup/ins/umov/smov): bits28:21=01110000, bit15=0, bit10=1 ----
    if (w & 0x9FE08400) == 0x0E000400:
        Q = (w >> 30) & 1
        op = (w >> 29) & 1
        imm5 = (w >> 16) & 31
        imm4 = (w >> 11) & 0xF
        Rn = (w >> 5) & 31
        Rd = w & 31
        esz, idx = _imm5_esz_idx(imm5)
        if esz is None:
            return None
        if op == 1:      # INS (element)  Vd[dindex] <- Vn[sindex]
            sidx = imm4 >> esz
            return ('vinse', {'vd': Rd, 'vn': Rn, 'esz': esz, 'didx': idx, 'sidx': sidx})
        # op == 0
        if imm4 == 0:    # DUP element
            return ('vdupe', {'vd': Rd, 'vn': Rn, 'esz': esz, 'idx': idx, 'q': Q})
        if imm4 == 1:    # DUP general
            return ('vdupg', {'vd': Rd, 'rn': Rn, 'esz': esz, 'q': Q})
        if imm4 == 3:    # INS general  Vd[idx] <- Rn
            return ('vinsg', {'vd': Rd, 'rn': Rn, 'esz': esz, 'didx': idx})
        if imm4 == 5:    # SMOV  Rd <- sext(Vn[idx])
            return ('vumov', {'rd': Rd, 'vn': Rn, 'esz': esz, 'idx': idx, 'sgn': 1})
        if imm4 == 7:    # UMOV  Rd <- Vn[idx]
            return ('vumov', {'rd': Rd, 'vn': Rn, 'esz': esz, 'idx': idx, 'sgn': 0})
        return None

    # ---- EXT: bits29:24=101110, bit21=0, bit15=0, bit10=0 ----
    if (w & 0xBFE08400) == 0x2E000000:
        Q = (w >> 30) & 1
        Rm = (w >> 16) & 31
        imm4 = (w >> 11) & 0xF
        Rn = (w >> 5) & 31
        Rd = w & 31
        if Q == 0 and (imm4 & 8):
            return None
        return ('vext', {'vd': Rd, 'vn': Rn, 'vm': Rm, 'idx': imm4, 'q': Q})

    # ---- permute (zip/uzp/trn): bit29=0, bits28:24=01110, bit21=0, bit15=0, bits11:10=10 ----
    if (w & 0xBF200C00) == 0x0E000800:
        Q = (w >> 30) & 1
        size = (w >> 22) & 3
        Rm = (w >> 16) & 31
        opcode = (w >> 12) & 7
        Rn = (w >> 5) & 31
        Rd = w & 31
        kmap = {1: 2, 2: 4, 3: 0, 5: 3, 6: 5, 7: 1}  # uzp1/trn1/zip1/uzp2/trn2/zip2
        if opcode not in kmap:
            return None
        return ('vperm', {'vd': Rd, 'vn': Rn, 'vm': Rm, 'esz': size, 'kind': kmap[opcode], 'q': Q})

    return None


def decode(w):
    """返回 (mnemonic, operands dict) 或 None"""
    sf = (w >> 31) & 1

    if w == 0xD503201F:
        return ('nop', {})

    # RET Xn
    if (w & 0xFFFFFC1F) == 0xD65F0000:
        return ('ret', {'rn': (w >> 5) & 31})

    # BR / BLR
    if (w & 0xFFFFFC1F) == 0xD61F0000:
        return ('br', {'rn': (w >> 5) & 31})
    if (w & 0xFFFFFC1F) == 0xD63F0000:
        return ('blr', {'rn': (w >> 5) & 31})

    # B / BL
    if (w & 0xFC000000) == 0x14000000:
        return ('b', {'off': sx(w & 0x3FFFFFF, 26) * 4})
    if (w & 0xFC000000) == 0x94000000:
        return ('bl', {'off': sx(w & 0x3FFFFFF, 26) * 4})

    # B.cond
    if (w & 0xFF000010) == 0x54000000:
        return ('bcond', {'cond': w & 0xF, 'off': sx((w >> 5) & 0x7FFFF, 19) * 4})

    # CBZ / CBNZ
    if (w & 0x7E000000) == 0x34000000:
        op = (w >> 24) & 1
        return ('cbnz' if op else 'cbz',
                {'rt': w & 31, 'off': sx((w >> 5) & 0x7FFFF, 19) * 4, 'sf': sf})

    # TBZ / TBNZ
    if (w & 0x7E000000) == 0x36000000:
        op = (w >> 24) & 1
        bit = ((w >> 31) << 5) | ((w >> 19) & 31)
        return ('tbnz' if op else 'tbz',
                {'rt': w & 31, 'bit': bit, 'off': sx((w >> 5) & 0x3FFF, 14) * 4})

    # ADRP
    if (w & 0x9F000000) == 0x90000000:
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        return ("adrp", {"rd": w & 31, "imm": sx(imm, 21)})

    # ADR
    if (w & 0x9F000000) == 0x10000000:
        imm = (((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3)
        return ("adr", {"rd": w & 31, "imm": sx(imm, 21)})

    # MOVZ / MOVK / MOVN  (sf opc 100101 hw imm16 Rd)
    if (w & 0x1F800000) == 0x12800000:
        opc = (w >> 29) & 3
        if opc in (0, 2, 3):
            return ({0: 'movn', 2: 'movz', 3: 'movk'}[opc],
                    {'rd': w & 31, 'imm': (w >> 5) & 0xFFFF,
                     'hw': (w >> 21) & 3, 'sf': sf})

    # ADD/SUB (imm)  -- sf op S 100010 sh imm12 Rn Rd
    if (w & 0x1F000000) == 0x11000000:
        op = (w >> 30) & 1
        s = (w >> 29) & 1
        sh = (w >> 22) & 1
        imm = ((w >> 10) & 0xFFF) << (12 if sh else 0)
        rn = (w >> 5) & 31
        rd = w & 31
        if s:
            return ('cmp_imm' if op == 1 else 'cmn_imm', {'rn': rn, 'imm': imm, 'sf': sf})
        return ('add_imm' if op == 0 else 'sub_imm',
                {'rd': rd, 'rn': rn, 'imm': imm, 'sf': sf})

    # ADD/SUB (shifted reg)
    if (w & 0x1F200000) == 0x0B000000:
        op = (w >> 30) & 1
        s = (w >> 29) & 1
        rm = (w >> 16) & 31
        rn = (w >> 5) & 31
        rd = w & 31
        if s:
            return ('cmp' if op == 1 else 'cmn', {'rn': rn, 'rm': rm, 'sf': sf})
        return ('add' if op == 0 else 'sub', {'rd': rd, 'rn': rn, 'rm': rm, 'sf': sf})

    # Logical (shifted reg): AND/ORR/EOR/ANDS/BIC/ORN/EON/BICS
    if (w & 0x1F000000) == 0x0A000000:
        opc = (w >> 29) & 3
        nbit = (w >> 21) & 1          # 1 => 取反第二操作数
        rm = (w >> 16) & 31
        rn = (w >> 5) & 31
        rd = w & 31
        if opc == 3:                  # ANDS -> TST
            return ('tst', {'rn': rn, 'rm': rm, 'sf': sf})
        name = {(0, 0): 'and', (0, 1): 'bic',
                (1, 0): 'orr', (1, 1): 'orn',
                (2, 0): 'eor', (2, 1): 'eon'}[(opc, nbit)]
        return (name, {'rd': rd, 'rn': rn, 'rm': rm, 'sf': sf})

    # MOV (reg) = ORR Xd, XZR, Xm
    if (w & 0xFFE0FFE0) == 0xAA0003E0 or (w & 0xFFE0FFE0) == 0x2A0003E0:
        return ('mov_reg', {'rd': w & 31, 'rm': (w >> 16) & 31, 'sf': sf})

    # MUL = MADD Xd, Xn, Xm, XZR
    if (w & 0xFFE0FC00) == 0x9B007C00 or (w & 0xFFE0FC00) == 0x1B007C00:
        return ('mul', {'rd': w & 31, 'rn': (w >> 5) & 31, 'rm': (w >> 16) & 31, 'sf': sf})

    # MADD / MSUB
    if (w & 0x7FE08000) == 0x1B000000:
        o0 = (w >> 15) & 1
        return ("msub" if o0 else "madd",
                {"rd": w & 31, "rn": (w >> 5) & 31, "rm": (w >> 16) & 31,
                 "ra": (w >> 10) & 31, "sf": sf})

    # CSEL / CSINC / CSINV / CSNEG
    if (w & 0x1FE00800) == 0x1A800000:
        return ("csel", {"rd": w & 31, "rn": (w >> 5) & 31, "rm": (w >> 16) & 31,
                         "cond": (w >> 12) & 0xF, "op2": (w >> 10) & 3, "sf": sf})

    # CCMP / CCMN (conditional compare, register & immediate)
    #   bits[28:21]=11010010, S(bit29)=1; bit11: 0=reg 1=imm; o2(bit10)=o3(bit4)=0
    #   handler 字节布局: [op][cond][nzcv][rn][rm/imm5][sf]；cond/nzcv 直接用 ARM 原值
    if ((w >> 29) & 1) and ((w >> 21) & 0xFF) == 0xD2 and \
       ((w >> 10) & 1) == 0 and ((w >> 4) & 1) == 0:
        op = (w >> 30) & 1          # 0=CCMN, 1=CCMP
        cond = (w >> 12) & 0xF
        rn = (w >> 5) & 31
        nzcv = w & 0xF
        sf = (w >> 31) & 1
        if (w >> 11) & 1:           # immediate
            imm5 = (w >> 16) & 0x1F
            return ('ccmp_imm' if op else 'ccmn_imm',
                    {'rn': rn, 'imm': imm5, 'cond': cond, 'nzcv': nzcv, 'sf': sf})
        else:                        # register
            rm = (w >> 16) & 31
            return ('ccmp_reg' if op else 'ccmn_reg',
                    {'rn': rn, 'rm': rm, 'cond': cond, 'nzcv': nzcv, 'sf': sf})

    # UDIV / SDIV
    if (w & 0xFFE0FC00) == 0x9AC00800 or (w & 0xFFE0FC00) == 0x1AC00800:
        return ('udiv', {'rd': w & 31, 'rn': (w >> 5) & 31, 'rm': (w >> 16) & 31})
    if (w & 0xFFE0FC00) == 0x9AC00C00 or (w & 0xFFE0FC00) == 0x1AC00C00:
        return ('sdiv', {'rd': w & 31, 'rn': (w >> 5) & 31, 'rm': (w >> 16) & 31})

    # FMOV (general) Dd, Xn   -- 0x9E670000 ; Sd, Wn -- 0x1E270000
    if (w & 0xFFFFFC00) == 0x9E670000:
        return ('fmov_gen', {'fd': w & 31, 'rn': (w >> 5) & 31})
    if (w & 0xFFFFFC00) == 0x1E270000:
        return ('fmov_gen', {'fd': w & 31, 'rn': (w >> 5) & 31})

    # EXTR Xd, Xn, Xm, #lsb  (32: 0x13800000 / 64: 0x93C00000)
    if (w & 0x7FE00000) == 0x13800000 or (w & 0x7FE00000) == 0x13C00000:
        return ('extr', {'rd': w & 31, 'rn': (w >> 5) & 31, 'rm': (w >> 16) & 31,
                         'lsb': (w >> 10) & 0x3F, 'sf': (w >> 31) & 1})

    # LSLV / LSRV / ASRV / RORV (寄存器移位)
    for _m, _n in ((0x1AC02000, 'lslv'), (0x1AC02400, 'lsrv'),
                   (0x1AC02800, 'asrv'), (0x1AC02C00, 'rorv')):
        if (w & 0xFFE0FC00) == _m or (w & 0xFFE0FC00) == (_m | 0x80000000):
            return (_n, {'rd': w & 31, 'rn': (w >> 5) & 31, 'rm': (w >> 16) & 31})

    # LSL/LSR/ASR (imm) = UBFM/SBFM
    # LSL Xd,Xn,#sh  -> UBFM Xd,Xn,#(-sh%64),#(63-sh)
    if (w & 0x7F800000) == 0x53000000:
        n = (w >> 22) & 1
        immr = (w >> 16) & 0x3F
        imms = (w >> 10) & 0x3F
        rn = (w >> 5) & 31
        rd = w & 31
        width = 64 if sf else 32
        if n == 0:
            if imms == width - 1:                     # LSR
                return ('lsr_imm', {'rd': rd, 'rn': rn, 'imm': immr, 'sf': sf})
            if (imms + 1) % width == immr:            # LSL
                return ('lsl_imm', {'rd': rd, 'rn': rn,
                                    'imm': (width - 1) - imms, 'sf': sf})
            if (imms & 0x20) and ((imms & 0x1F) == width - 1):   # ASR
                return ('asr_imm', {'rd': rd, 'rn': rn, 'imm': immr, 'sf': sf})
    # ================= 浮点 / SIMD =================
    # v-neon: NEON/AdvSIMD 向量指令(bit28=0 的 01110 类),先于标量浮点判
    _nd = _decode_neon(w)
    if _nd is not None:
        return _nd
    # v-neon: 标量 3-source 浮点 FMADD/FMSUB/FNMADD/FNMSUB (0x1F 开头, 不被下面 0x1E 块覆盖)
    #   sf位31=0, bits28:24=11111, type=bits23:22, o1=bit21, o0=bit15
    if (w & 0xFF000000) == 0x1F000000:
        _t = (w >> 22) & 3
        if _t in (0, 1):   # S / D (H 精度跳过)
            return ('fmadd', {'rd': w & 31, 'rn': (w >> 5) & 31,
                              'rm': (w >> 16) & 31, 'ra': (w >> 10) & 31,
                              'sf': _t & 1, 'o1': (w >> 21) & 1, 'o0': (w >> 15) & 1})
    # 标量浮点: 0x1E / 0x1F 开头 (bit28-24 = 11110)
    if (w & 0x5F000000) == 0x1E000000:
        fsf = (w >> 22) & 1          # 0=单精度(S) 1=双精度(D)
        rn_v = (w >> 5) & 31
        rn_r = rn_v
        rd_v = w & 31
        rm_v = (w >> 16) & 31
        opcode = (w >> 12) & 0x1F    # bits 16-12

        # v-cov80: FMOV 标量立即数（浮点常量）—— bits[12:10]=100, bits[9:5]=00000
        #   imm8=bits[20:13]，用 VFPExpandImm 展开成 IEEE 位模式，复用 OP_FMOV_IMM。
        if ((w >> 10) & 0x7) == 4 and ((w >> 5) & 0x1F) == 0 and ((w >> 21) & 1) == 1:
            ptype = (w >> 22) & 3    # 0=S 1=D 3=H
            if ptype in (0, 1):
                imm8 = (w >> 13) & 0xFF
                bits = _vfp_expand_imm(imm8, 32 if ptype == 0 else 64)
                return ('fmov_imm', {'rd': w & 31, 'bits': bits, 'sf': ptype & 1})

        # v-cov80: 浮点 1-source（FSQRT/FRINTx）必须在 FMOV/FABS/FNEG 之前判，
        #   因为现有 FABS/FMOV 掩码没区分 opcode 的 bit16 会误吞 FSQRT/FRINT。
        #   1-source 形式: bits[14:10]=10000, bit21=1, opcode=bits[20:15]
        if ((w >> 10) & 0x1F) == 0x10 and ((w >> 21) & 1) == 1:
            _o6 = (w >> 15) & 0x3F
            if _o6 == 3:
                return ('fsqrt', {'rd': rd_v, 'rn': rn_v, 'sf': fsf})
            if 8 <= _o6 <= 15:
                return ('frint', {'rd': rd_v, 'rn': rn_v, 'sf': fsf, 'mode': _o6 - 8})

        # FMOV Vd, Vn
        if (w & 0xFF60FC00) == (0x1E204000 | (fsf << 22)):
            return ('fmov_reg', {'rd': rd_v, 'rn': rn_v, 'sf': fsf})
        # FNEG / FABS
        if (w & 0xFF60FC00) == (0x1E214000 | (fsf << 22)):
            return ('fneg', {'rd': rd_v, 'rn': rn_v, 'sf': fsf})
        if (w & 0xFF60FC00) == (0x1E20C000 | (fsf << 22)):
            return ('fabs', {'rd': rd_v, 'rn': rn_v, 'sf': fsf})
        # FADD/FSUB/FMUL/FDIV
        for o, nm in ((0x1E202800,'fadd'),(0x1E203800,'fsub'),
                      (0x1E200800,'fmul'),(0x1E201800,'fdiv')):
            if (w & 0xFF60FC00) == (o | (fsf << 22)):
                return (nm, {'rd': rd_v, 'rn': rn_v, 'rm': rm_v, 'sf': fsf})
        # FCMP Vn, Vm
        for o in (0x1E202000, 0x1E202010):
            if (w & 0xFF60FC1F) == (o | (fsf << 22)):
                return ('fcmp', {'rn': rn_v, 'rm': rm_v, 'sf': fsf})
        # FCMP Vn, #0.0 (零立即数比较) —— bits4:3=01, Rm=0
        if (w & 0xFF3FFC1F) == 0x1E202008:
            return ('fcmp_zero', {'rn': rn_v, 'sf': (w >> 22) & 1})
        # FCSEL Vd, Vn, Vm, cond —— bit21=1, bits11:10=11
        if ((w >> 21) & 1) == 1 and ((w >> 10) & 3) == 3:
            return ('fcsel', {'rd': rd_v, 'rn': rn_v, 'rm': rm_v,
                              'cond': (w >> 12) & 0xF, 'sf': (w >> 22) & 1})
        # FCVT S->D / D->S (位23=1 表示 D->S)
        if (w & 0xFFBFFC00) == 0x1E22C000:
            return ('fcvt', {'rd': rd_v, 'rn': rn_v, 'dir': (w >> 22) & 1})
        # SCVTF / UCVTF: FP宽度=type(bit22), 整数宽度=sf(bit31)
        #   (掩码放开 bit31 → 支持 x 寄存器源; 之前钉死 bit31=0 把 64 位源全漏了)
        if (w & 0x7F3EFC00) == 0x1E220000:
            return ('scvtf', {'rd': rd_v, 'rn': rn_v,
                              'fsf': (w >> 22) & 1, 'isw': (w >> 31) & 1})
        if (w & 0x7F3EFC00) == 0x1E230000:
            return ('ucvtf', {'rd': rd_v, 'rn': rn_v,
                              'fsf': (w >> 22) & 1, 'isw': (w >> 31) & 1})
        # FCVTZS / FCVTZU (Rd 是整数寄存器)
        if (w & 0x7F3EFC00) == 0x1E380000:
            return ('fcvtzs', {'rd': rd_v, 'rn': rn_v,
                               'fsf': (w >> 22) & 1, 'isw': (w >> 31) & 1})
        if (w & 0x7F3EFC00) == 0x1E390000:
            return ('fcvtzu', {'rd': rd_v, 'rn': rn_v,
                               'fsf': (w >> 22) & 1, 'isw': (w >> 31) & 1})
        # v-cov80: 浮点 2-source FMAX/FMIN(/NM)—— bits[11:10]=10, bit21=1, opcode=bits[15:12]
        if ((w >> 10) & 3) == 2 and ((w >> 21) & 1) == 1:
            o4 = (w >> 12) & 0xF
            if o4 in (4, 6):   # FMAX / FMAXNM
                return ('fmax', {'rd': rd_v, 'rn': rn_v, 'rm': rm_v, 'sf': fsf})
            if o4 in (5, 7):   # FMIN / FMINNM
                return ('fmin', {'rd': rd_v, 'rn': rn_v, 'rm': rm_v, 'sf': fsf})
        return None

    # 浮点 LDR/STR (unsigned offset): 0xBD/0xFD 开头
    if (w & 0x3F000000) in (0x3D000000,):
        if (w >> 23) & 1:   # opc 高位=1 → 128位(Q)访问; _decode_neon 已处理在内的, 这里只会是越界 Q → 跳过, 不可误判成 32 位
            return None
        sz = 1 if (w >> 30) & 1 else 0      # bit30: 1=D(64) 0=S(32)
        opc_bit = (w >> 22) & 1             # bit22: 0=store 1=load
        imm = ((w >> 10) & 0xFFF) << (3 if sz else 2)
        rn = (w >> 5) & 31
        rt = w & 31
        return ('ldr_fp' if opc_bit else 'str_fp',
                {'rt': rt, 'rn': rn, 'off': imm, 'sz': sz})

    # 浮点 LDR/STR (unscaled): 0xBC/0xFC 开头
    if (w & 0x3F200C00) == (0x3C000000 if (w >> 30) & 1 else 0x3C000000):
        pass
    if (w & 0xBF200C00) == 0x3C000000:
        if (w >> 23) & 1:   # 128位(Q) 无缩放访问, 交给 _decode_neon; 越界则跳过
            return None
        sz = 1 if (w >> 30) & 1 else 0
        opc_bit = (w >> 22) & 1
        imm = sx((w >> 12) & 0x1FF, 9)
        rn = (w >> 5) & 31
        rt = w & 31
        if ((w >> 10) & 3) == 0:
            return ('ldr_fp' if opc_bit else 'str_fp',
                    {'rt': rt, 'rn': rn, 'off': imm, 'sz': sz})
        return None


    # 位域指令: sf opc(00=ubfm? 实际 SBFM=00, BFM=01, UBFM=10) 100110 N immr imms Rn Rd
    if (w & 0x1F800000) == 0x13000000:
        opc = (w >> 29) & 3      # 0=SBFM 1=BFM 2=UBFM
        n = (w >> 22) & 1
        immr = (w >> 16) & 0x3F
        imms = (w >> 10) & 0x3F
        rn = (w >> 5) & 31
        rd = w & 31
        if n == sf:              # 合法编码
            return ({0: 'sbfm', 1: 'bfm', 2: 'ubfm'}[opc],
                    {'rd': rd, 'rn': rn, 'immr': immr, 'imms': imms, 'sf': sf})

    # 逻辑立即数: sf opc 100100 N immr imms Rn Rd
    if (w & 0x1F800000) == 0x12000000:
        opc = (w >> 29) & 3
        n = (w >> 22) & 1
        immr = (w >> 16) & 0x3F
        imms = (w >> 10) & 0x3F
        rn = (w >> 5) & 31
        rd = w & 31
        mask = _bitmask_imm(n, imms, immr, sf)
        if mask is not None:
            return ({0: 'and_lit', 1: 'orr_lit', 2: 'eor_lit', 3: 'ands_lit'}[opc],
                    {'rd': rd, 'rn': rn, 'imm': mask, 'sf': sf})

        # 其它位域操作暂不支持

    # v-cov80: LDR 浮点字面量 (SIMD&FP literal): bits[29:24]=011100
    #   opc(bit31:30): 0=S(32) 1=D(64) 2=Q(128,跳过)
    if ((w >> 24) & 0x3F) == 0x1C:
        sz = (w >> 30) & 3
        if sz in (0, 1):
            off = sx((w >> 5) & 0x7FFFF, 19) * 4
            return ('ldr_lit_fp', {'rt': w & 31, 'off': off, 'sz': sz})

    # LDR/STR (literal): opc 011 0 00 imm19 Rt  —— 只接受整数版, FP 版(0x1C)拒绝
    if (w & 0x3F000000) == 0x18000000:
        opc = (w >> 30) & 3
        off = sx((w >> 5) & 0x7FFFF, 19) * 4
        rt = w & 31
        if opc == 3:
            return None              # PRFM, 忽略
        return ('ldr_lit', {'rt': rt, 'off': off, 'size': opc})

    # LDR/STR (pre/post-index): size opc 111 0 00 0 imm9 bits11-10 Rn Rt
    #   bits11-10 = 01 (post-index) / 11 (pre-index)
    if (w & 0x3B200C00) in (0x38000400, 0x38000C00):
        size = (w >> 30) & 3
        opc = (w >> 22) & 3
        imm = sx((w >> 12) & 0x1FF, 9)
        mode = 'post' if ((w >> 10) & 3) == 1 else 'pre'
        rn = (w >> 5) & 31
        rt = w & 31
        if opc in (0, 1):
            return ('ld_st_idx9', {'rt': rt, 'rn': rn, 'off': imm,
                                   'size': size, 'store': (opc == 0), 'mode': mode})

    # SIMD LDR/STR (register offset, bit21=1): size opc 111 0 00 0 1 Rm option S 10 Rn Rt
    if (w & 0x3B200C00) == 0x38200800:
        szb = (w >> 30) & 3
        opc = (w >> 22) & 3
        rm = (w >> 16) & 31
        option = (w >> 13) & 7
        s_ = (w >> 12) & 1
        rn = (w >> 5) & 31
        rt = w & 31
        if option in (2, 3, 6, 7):
            # S=0(4B) D=1(8B) Q=2(16B)
            sz = 0 if szb == 0 else 1
            shift = s_ * (2 if szb == 0 else 3)
            if opc == 0:
                return ('str_fp_idx', {'rt': rt, 'rn': rn, 'rm': rm,
                                       'sz': sz, 'shift': shift, 'q': (szb == 2)})
            if opc == 1:
                return ('ldr_fp_idx', {'rt': rt, 'rn': rn, 'rm': rm,
                                       'sz': sz, 'shift': shift, 'q': (szb == 2)})

    # LDR/STR (register offset): size opc 111 0 00 0 1 Rm option S 10 Rn Rt
    if (w & 0x3B200C00) == 0x38000800:   # bit21=0 (非 unsigned offset), bits11-10=10 (register)
        size = (w >> 30) & 3
        opc = (w >> 22) & 3
        rm = (w >> 16) & 31
        option = (w >> 13) & 7
        s_ = (w >> 12) & 1
        rn = (w >> 5) & 31
        rt = w & 31
        if option in (2, 3, 6, 7):      # UXTW(010/011) / SXTW(110/111)
            shift = s_ * size
            if opc == 0:
                return ('str_idx', {'rt': rt, 'rn': rn, 'rm': rm, 'size': size, 'shift': shift})
            if opc == 1:
                return ('ldr_idx', {'rt': rt, 'rn': rn, 'rm': rm, 'size': size, 'shift': shift})

    # LDUR/STUR (unscaled): size opc 111 0 00 0 imm9 Rn Rt
    if (w & 0x3B200C00) == 0x38000000:
        size = (w >> 30) & 3
        opc = (w >> 22) & 3
        imm = sx((w >> 12) & 0x1FF, 9)
        rn = (w >> 5) & 31
        rt = w & 31
        if opc == 0:
            return ('str', {'rt': rt, 'rn': rn, 'off': imm, 'size': size})
        if opc == 1:
            return ('ldr', {'rt': rt, 'rn': rn, 'off': imm, 'size': size})
        if opc == 2 and size == 2:
            return ('ldrsw', {'rt': rt, 'rn': rn, 'off': imm})
        if opc in (2, 3) and size in (0, 1):   # LDURSB / LDURSH（符号扩展）
            return ('ldrs', {'rt': rt, 'rn': rn, 'off': imm,
                             'size': size, 'is32': opc == 3})

    # LDR/STR (unsigned offset): size opc 111 0 01 imm12 Rn Rt
    if (w & 0x3B000000) == 0x39000000:
        size = (w >> 30) & 3
        opc = (w >> 22) & 3
        imm = ((w >> 10) & 0xFFF) << size
        rn = (w >> 5) & 31
        rt = w & 31
        if opc == 0:   # store
            return ('str', {'rt': rt, 'rn': rn, 'off': imm, 'size': size})
        if opc == 1:   # load
            return ('ldr', {'rt': rt, 'rn': rn, 'off': imm, 'size': size})
        if opc == 2 and size == 2:   # LDRSW
            return ('ldrsw', {'rt': rt, 'rn': rn, 'off': imm})
        if opc in (2, 3) and size in (0, 1):   # LDRSB / LDRSH（符号扩展）
            return ('ldrs', {'rt': rt, 'rn': rn, 'off': imm,
                             'size': size, 'is32': opc == 3})

    # SIMD LDP/STP (bit26=1): size(31-30) 101 0 00 idx imm7 Rt2 Rn Rt
    if (w & 0x3E000000) == 0x2C000000:
        szb = (w >> 30) & 3
        l = (w >> 22) & 1
        idx = (w >> 23) & 3
        # S=szb0(4B) D=szb1(8B) Q=szb2(16B)
        scale = {0: 2, 1: 3, 2: 4, 3: 3}[szb]
        imm7 = sx((w >> 15) & 0x7F, 7) * (1 << scale)
        rt2 = (w >> 10) & 31
        rn = (w >> 5) & 31
        rt = w & 31
        return ('fp_pair', {'rt': rt, 'rt2': rt2, 'rn': rn, 'off': imm7,
                            'sz': 0 if szb == 0 else 1, 'wb': idx, 'load': bool(l),
                            'q': (szb == 2)})

    # LDP/STP (offset / pre-index / post-index)
    if (w & 0x3E000000) == 0x28000000:   # bit26=0: 整数; FP 版 0x2C 由下面拦截
        opc = (w >> 30) & 3
        l = (w >> 22) & 1
        idx = (w >> 23) & 3          # 0=offset 1=post 3=pre
        # ★ opc 映射: 0=32位(W)  2=64位(X)  1/3=SIMD(Q) 不支持
        if opc == 0:
            size, scale = 2, 4        # W (32-bit)
        elif opc == 2:
            size, scale = 3, 8        # X (64-bit)  ← stp x29,x30 用的就是它
        else:
            return None               # SIMD pair 交给 fp_pair 处理
        imm7 = sx((w >> 15) & 0x7F, 7) * scale
        rt2 = (w >> 10) & 31
        rn = (w >> 5) & 31
        rt = w & 31
        return ('ldp' if l else 'stp',
                {'rt': rt, 'rt2': rt2, 'rn': rn, 'off': imm7,
                 'size': size, 'wb': idx})

    return None


# ============================================================
# 翻译: ARM64 指令序列 → VM 字节码
# ============================================================
class TransError(Exception):
    pass


def decode_function(raw, start, end, max_insts=600):
    """从 start 线性解码一个函数的指令，带「可达性守卫」防止越过无条件
    分支撞进字面量池/数据被当指令误译。

    返回 (insts, err)；err 为 None 表示成功，否则是失败原因字符串。

    可达性规则：
      - 正常顺序指令：继续。
      - 分支(b/bcond/cbz/tbz)：若目标在 [start,end) 内，更新 reach_end。
      - 终止类(ret / br / 无条件 b)：仅当后续地址 <= reach_end（即仍有分支
        指向其后、存在可达基本块）才继续解码；否则停止。
    这样「无条件跳转之后、直到某个分支目标之前」的区间若无人跳入即判为数据，
    不会被线性误读。
    """
    insts = []
    reach_end = start   # 已见分支目标的最大值（可达边界）
    a = start
    cnt = 0
    while a + 4 <= end and a + 4 <= len(raw) and cnt < max_insts:
        w = struct.unpack_from('<I', raw, a)[0]
        d = decode(w)
        if d is None:
            return insts, "解码失败 0x%08x @+0x%x" % (w, a - start)
        insts.append((a, w))
        cnt += 1
        mn = d[0]
        # 更新可达边界（仅函数内分支）
        if mn in ('b', 'bcond', 'cbz', 'cbnz', 'tbz', 'tbnz'):
            tgt = a + d[1]['off']
            if start <= tgt < end:
                if tgt > reach_end:
                    reach_end = tgt
        nxt = a + 4
        # 终止类：无后续可达块就停
        if mn == 'ret' or mn == 'br':
            if nxt <= reach_end:
                a = nxt; continue
            break
        if mn == 'b':
            tgt = a + d[1]['off']
            internal = (start <= tgt < end)
            if internal and tgt > reach_end:
                reach_end = tgt
            # 无条件跳转后：仅当前方还有可达块才继续
            if nxt <= reach_end:
                a = nxt; continue
            break
        a = nxt
    if not insts:
        return insts, "空函数"
    return insts, None


def translate(insts, verbose=False):
    """insts: [(addr, word), ...]，返回 (bytecode, branch_targets)

    分支目标用 VM 偏移表示；先占位后回填。
    """
    code = bytearray()
    op_pos = []          # 每个 opcode 字节在字节码中的位置(需要加密)
    # arm_index -> vm_offset
    vm_off = {}
    # 待回填: (bytecode_field_pos, arm_target_index, kind)
    fixups = []
    # 注：#3 虚拟寄存器重映射(σ)曾在此实现，但 vmsim3 对拍发现它与 VM 的 ABI 边界
    #   (call/svc/halt 硬编码 R[0..7])冲突 → 已撤出，待 σ-aware 的 ABI handler 落地
    #   并上机验证后再启用。详见 第八批 报告。

    def emit_read(dst, src):
        """把 src 读进 dst：src==31 表示 ZR（零），不是 SP"""
        if (src & 31) == 31:
            emit(bytes([OP_MOV_IMM32, dst & 31]) + struct.pack('<I', 0))
        else:
            emit(bytes([OP_MOV_REG, dst & 31, src & 31]))

    def emit(b, is_op=True):
        if is_op:
            op_pos.append(len(code))
        code.extend(b)

    def vm_pos():
        return len(code)

    # ---- v-bcjunk: 字节码级中性垃圾注入 ----
    #   在真实指令之间插入只操作 eval 栈的垃圾(push/算术/drop),对 R[]/V[]/FL 零副作用、
    #   栈深度平衡。目的: 让 __vmpbc 字节码不再与原指令 1:1,拉开反编译距离。
    #   默认开;GCOBF_BCJUNK=0 可关(用于等价对拍调试)。
    import os as _os2, random as _rnd2
    _BCJUNK = _os2.environ.get("GCOBF_BCJUNK", "1") != "0"
    # 密度: 每条真实指令后以 _BCJUNK_P 概率插一小段 (默认 0.33, 控制膨胀)
    try: _BCJUNK_P = float(_os2.environ.get("GCOBF_BCJUNK_P", "0.33"))
    except ValueError: _BCJUNK_P = 0.33
    _bjr = _rnd2.Random()
    _SJ_BIN = [OP_S_ADD, OP_S_SUB, OP_S_MUL, OP_S_XOR, OP_S_AND, OP_S_OR]

    def _emit_bcjunk():
        # 一段平衡的 eval-stack 运算(只碰 eval 栈, 对 R/V/FL 零副作用):
        #   push 1~2 个立即数 → 1~2 次二元运算 → 把残留全部 drop
        depth = 0
        npush = _bjr.randint(1, 2)
        for _ in range(npush):
            emit(bytes([OP_S_PUSH_IMM64]) + struct.pack('<Q', _bjr.getrandbits(64)))
            depth += 1
        for _ in range(_bjr.randint(0, 2)):
            if depth >= 2:
                emit(bytes([_bjr.choice(_SJ_BIN)])); depth -= 1
        for _ in range(depth):
            emit(bytes([OP_S_DROP]))

    for idx, (addr, w) in enumerate(insts):
        vm_off[idx] = vm_pos()
        d = decode(w)
        if d is None:
            raise TransError("不支持的指令 0x%08x @ +%d" % (w, idx * 4))
        mn, o = d

        if mn == 'nop':
            emit(bytes([OP_NOP]))

        elif mn in ('movz', 'movk', 'movn'):
            if mn == 'movz':
                v = o['imm'] << (16 * o['hw'])
                if o['imm'] == 0:
                    emit(bytes([OP_MOV_IMM32, o['rd']]) + struct.pack('<I', 0))
                elif o['hw'] == 0 and o['imm'] <= 0x7FFFFFFF:
                    emit(bytes([OP_MOV_IMM32, o['rd']]) + struct.pack('<I', v))
                else:
                    emit(bytes([OP_MOV_IMM, o['rd']]) + struct.pack('<Q', v))
            elif mn == 'movn':
                v = (~(o['imm'] << (16 * o['hw']))) & 0xFFFFFFFFFFFFFFFF
                emit(bytes([OP_MOV_IMM, o['rd']]) + struct.pack('<Q', v))
            else:  # movk
                emit(bytes([OP_MOVK, o['rd']]) + struct.pack('<H', o['imm'] & 0xFFFF) + bytes([o['hw'] & 3]))

        elif mn == 'mov_reg':
            emit(bytes([OP_MOV_REG, o['rd'], o['rm']]))

        elif mn in ('add', 'sub', 'and', 'orr', 'eor', 'orn', 'bic', 'eon'):
            opmap = {'add': OP_ADD, 'sub': OP_SUB, 'and': OP_AND,
                     'orr': OP_OR, 'eor': OP_XOR}
            rn_zr = (o['rn'] & 31) == 31
            rm_zr = (o['rm'] & 31) == 31
            if mn in ('bic', 'orn', 'eon'):
                # 先 NOT rm 再运算
                if rm_zr:
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0xFFFFFFFF))
                else:
                    emit(bytes([OP_NOT, o['rd'], o['rm']]))
                if rn_zr:
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
                else:
                    emit(bytes([opmap[{'bic': 'and', 'orn': 'orr', 'eon': 'eor'}[mn]],
                                o['rd'], o['rn'], o['rd']]))
            elif rn_zr and rm_zr:
                # R = 0 op 0
                emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
            elif rm_zr:
                # R = rn op 0
                if mn in ('orr', 'eor', 'add', 'sub'):
                    emit_read(o['rd'], o['rn'])          # = MOV Rd, Rn
                else:  # and
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
            elif rn_zr:
                # R = 0 op rm
                if mn in ('orr', 'eor', 'add'):
                    emit_read(o['rd'], o['rm'])          # = MOV Rd, Rm
                elif mn == 'and':
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
                else:  # sub: 0 - rm = -rm
                    emit(bytes([OP_NOT, o['rd'], o['rm']]))
                    emit(bytes([OP_ADD_IMM, o['rd'], o['rd']]) + struct.pack('<I', 1))
            else:
                emit(bytes([opmap[mn], o['rd'], o['rn'], o['rm']]))

        elif mn in ('add_imm', 'sub_imm'):
            emit(bytes([OP_ADD_IMM if mn == 'add_imm' else OP_SUB_IMM,
                        o['rd'], o['rn']]) + struct.pack('<I', o['imm'] & 0xFFFFFFFF))

        elif mn == 'mul':
            emit(bytes([OP_MUL, o['rd'], o['rn'], o['rm']]))

        elif mn in ('madd', 'msub'):
            emit(bytes([OP_MUL, o['rd'], o['rn'], o['rm']]))
            emit(bytes([OP_ADD if mn == 'madd' else OP_SUB,
                        o['rd'], o['rd'], o['ra']]))

        elif mn == 'csel':
            # CSEL/CSINC/CSINV/CSNEG 由 op2 区分：
            #   op2=0 CSEL : cond ? Rn : Rm
            #   op2=1 CSINC: cond ? Rn : Rm+1     ← authorized 用的就是它
            #   op2=2 CSINV: cond ? Rn : ~Rm
            #   op2=3 CSNEG: cond ? Rn : -Rm
            # 生成: Jcc true ; <假分支: Rd 由 Rm 变换> ; JMP end ; true: MOV Rd,Rn ; end:
            opj = {0: OP_JE, 1: OP_JNE, 0xB: OP_JL, 0xA: OP_JGE,
                   0xC: OP_JGT, 0xD: OP_JLE, 3: OP_JB, 2: OP_JAE,
                   9: OP_JBE, 8: OP_JA}.get(o['cond'])
            if opj is None:
                raise TransError("csel 不支持的 cond 0x%x" % o['cond'])
            op2 = o.get('op2', 0)
            p1 = vm_pos()
            emit(bytes([opj]) + struct.pack('<I', 0))
            # ---- 假分支（条件不成立时）----
            if op2 == 0:                                  # CSEL
                emit_read(o['rd'], o['rm'])
            elif op2 == 1:                                # CSINC: Rd = Rm + 1 (Rm==ZR -> 1)
                if (o['rm'] & 31) == 31:
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 1))
                else:
                    emit(bytes([OP_ADD_IMM, o['rd'], o['rm']]) + struct.pack('<I', 1))
            elif op2 == 2:                                # CSINV: Rd = ~Rm
                if (o['rm'] & 31) == 31:
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0xFFFFFFFF))
                else:
                    emit(bytes([OP_NOT, o['rd'], o['rm']]))
            else:                                         # CSNEG: Rd = -Rm
                if (o['rm'] & 31) == 31:
                    emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
                else:
                    emit(bytes([OP_MOV_REG, o['rd'], o['rm']]))
                    emit(bytes([OP_SUB, o['rd'], 31, o['rd']]))
            p2 = vm_pos()
            emit(bytes([OP_JMP]) + struct.pack('<I', 0))
            lbl_true = vm_pos()
            emit_read(o['rd'], o['rn'])                   # 真分支：Rd = Rn（Rn==ZR -> 0）
            lbl_end = vm_pos()
            struct.pack_into('<I', code, p1 + 1, lbl_true)
            struct.pack_into('<I', code, p2 + 1, lbl_end)

        elif mn in ('lsl_imm', 'lsr_imm', 'asr_imm'):
            op = {'lsl_imm': OP_SHL_IMM, 'lsr_imm': OP_SHR_IMM, 'asr_imm': OP_ASR_IMM}[mn]
            emit(bytes([op, o['rd'], o['rn']]) + struct.pack('<I', o['imm']))

        elif mn in ('cmp', 'cmn'):
            emit(bytes([OP_CMP, o['rn'], o['rm']]))
        elif mn in ('cmp_imm', 'cmn_imm'):
            emit(bytes([OP_CMP_IMM, o['rn']]) + struct.pack('<I', o['imm'] & 0xFFFFFFFF))

        elif mn in ('adrp', 'adr'):
            if mn == 'adrp':
                target = (addr & ~0xFFF) + (o['imm'] << 12)
            else:
                target = addr + o['imm']
            emit(bytes([OP_MOV_IMM, o['rd']]) + struct.pack('<Q', target))
            emit(bytes([OP_ADD, o['rd'], o['rd'], 28]))    # + image base (R28)

        elif mn in ('ldr_fp_idx', 'str_fp_idx'):
            # 地址 = Rn + (Rm << shift)，用临时 R30 计算（避免改 R31）
            emit(bytes([OP_SHL_IMM, 30, o['rm']]) + struct.pack('<I', o['shift']))
            emit(bytes([OP_ADD, 30, o['rn'], 30]))
            opf = OP_LOAD_FP if mn == 'ldr_fp_idx' else OP_STORE_FP
            emit(bytes([opf, o['rt'], 30]) + struct.pack('<H', 0) + bytes([o['sz']]))

        elif mn == 'fp_pair':
            # 用 h_load_fp/h_store_fp 逐条展开（sz:0=S 1=D）
            off = o['off']
            rn = o['rn']
            wb = o.get('wb', 0)
            if wb == 3:      # pre-index
                d = -off
                if d >= 0:
                    emit(bytes([OP_ADD_IMM, rn, rn]) + struct.pack('<I', d))
                else:
                    emit(bytes([OP_SUB_IMM, rn, rn]) + struct.pack('<I', -d))
                off = 0
            elif wb == 1:
                off = 0
            opf = OP_LOAD_FP if o['load'] else OP_STORE_FP
            step = 16 if o['q'] else (8 if o['sz'] else 4)
            emit(bytes([opf, o['rt'], rn]) + struct.pack('<H', off & 0xFFFF) + bytes([o['sz']]))
            emit(bytes([opf, o['rt2'], rn]) + struct.pack('<H', (off + step) & 0xFFFF) + bytes([o['sz']]))
            if wb == 1:      # post-index
                d = o['off']
                if d >= 0:
                    emit(bytes([OP_ADD_IMM, rn, rn]) + struct.pack('<I', d))
                else:
                    emit(bytes([OP_SUB_IMM, rn, rn]) + struct.pack('<I', -d))

        elif mn in ('stp', 'ldp'):
            sz = o['size']
            wb = o.get('wb', 0)
            off = o['off']
            # pre-index: 先调整基址, 再用 0 偏移; post-index: 先用 0 偏移, 再调整
            if wb == 3:
                d = off                       # ★ pre-index: sp += off（off 为负 → 减）
                if d >= 0:
                    emit(bytes([OP_ADD_IMM, o['rn'], o['rn']]) + struct.pack('<I', d))
                else:
                    emit(bytes([OP_SUB_IMM, o['rn'], o['rn']]) + struct.pack('<I', -d))
                off = 0
            elif wb == 1:
                off = 0
            if mn == 'stp':
                sop = {0: OP_STORE8, 1: OP_STORE16, 2: OP_STORE32, 3: OP_STORE64}[sz]
                emit(bytes([sop, o['rn'], o['rt']]) + struct.pack('<H', off & 0xFFFF))
                emit(bytes([sop, o['rn'], o['rt2']]) + struct.pack('<H', (off + (1 << sz)) & 0xFFFF))
            else:
                lop = {0: OP_LOAD8, 1: OP_LOAD16, 2: OP_LOAD32, 3: OP_LOAD64}[sz]
                emit(bytes([lop, o['rt'], o['rn']]) + struct.pack('<H', off & 0xFFFF))
                emit(bytes([lop, o['rt2'], o['rn']]) + struct.pack('<H', (off + (1 << sz)) & 0xFFFF))
            if wb == 1:
                d = off - o['off'] if False else o['off']
                if d >= 0:
                    emit(bytes([OP_ADD_IMM, o['rn'], o['rn']]) + struct.pack('<I', d))
                else:
                    emit(bytes([OP_SUB_IMM, o['rn'], o['rn']]) + struct.pack('<I', -d))

        elif mn == 'ret':
            emit(bytes([OP_HALT]))          # 函数返回: VM 停机, 结果留在 R0

        elif mn == 'fmov_reg':
            emit(bytes([OP_FMOV_REG, o['rd'], o['rn'], o['sf']]))
        elif mn == 'fneg':
            emit(bytes([OP_FNEG, o['rd'], o['rn'], o['sf']]))
        elif mn == 'fabs':
            emit(bytes([OP_FABS, o['rd'], o['rn'], o['sf']]))
        elif mn in ('fadd', 'fsub', 'fmul', 'fdiv'):
            opf = {'fadd': OP_FADD, 'fsub': OP_FSUB,
                   'fmul': OP_FMUL, 'fdiv': OP_FDIV}[mn]
            emit(bytes([opf, o['rd'], o['rn'], o['rm'], o['sf']]))
        elif mn in ('fmax', 'fmin'):
            opf = OP_FMAX if mn == 'fmax' else OP_FMIN
            emit(bytes([opf, o['rd'], o['rn'], o['rm'], o['sf']]))
        elif mn == 'fsqrt':
            emit(bytes([OP_FSQRT, o['rd'], o['rn'], o['sf']]))
        elif mn == 'fmov_imm':
            # 复用 OP_FMOV_IMM: [op][rd][imm64]  10B（单精度位模式放低 32 位）
            emit(bytes([OP_FMOV_IMM, o['rd'] & 31]) +
                 struct.pack('<Q', o['bits'] & 0xFFFFFFFFFFFFFFFF))
        elif mn == 'frint':
            emit(bytes([OP_FRINT, o['rd'], o['rn'], o['sf'] & 1, o['mode'] & 0xFF]))
        # ---- v-neon: NEON/AdvSIMD ----
        elif mn == 'vmovi':
            emit(bytes([OP_VMOVI, o['vd'] & 31]) +
                 struct.pack('<Q', o['lo']) + struct.pack('<Q', o['hi']))
        elif mn == 'vldr':
            emit(bytes([OP_VLDR, o['vt'] & 31, o['rn'] & 31]) +
                 struct.pack('<h', o['off']) + bytes([o['q'] & 1]))
        elif mn == 'vstr':
            emit(bytes([OP_VSTR, o['vt'] & 31, o['rn'] & 31]) +
                 struct.pack('<h', o['off']) + bytes([o['q'] & 1]))
        elif mn == 'v3s':
            emit(bytes([OP_V3S, o['vd'] & 31, o['vn'] & 31, o['vm'] & 31,
                        o['esz'] & 3, o['u'] & 1, o['opc'] & 0xFF, o['q'] & 1]))
        elif mn == 'vfma':
            emit(bytes([OP_VFMA, o['vd'] & 31, o['vn'] & 31, o['vm'] & 31,
                        o['esz'] & 3, o['sub'] & 1, o['q'] & 1]))
        elif mn == 'v2s':
            emit(bytes([OP_V2S, o['vd'] & 31, o['vn'] & 31,
                        o['esz'] & 3, o['u'] & 1, o['opc'] & 0xFF, o['q'] & 1]))
        elif mn == 'vdupe':
            emit(bytes([OP_VDUPE, o['vd'] & 31, o['vn'] & 31, o['esz'] & 3, o['idx'] & 0xFF, o['q'] & 1]))
        elif mn == 'vdupg':
            emit(bytes([OP_VDUPG, o['vd'] & 31, o['rn'] & 31, o['esz'] & 3, o['q'] & 1]))
        elif mn == 'vinse':
            emit(bytes([OP_VINSE, o['vd'] & 31, o['vn'] & 31, o['esz'] & 3, o['didx'] & 0xFF, o['sidx'] & 0xFF]))
        elif mn == 'vinsg':
            emit(bytes([OP_VINSG, o['vd'] & 31, o['rn'] & 31, o['esz'] & 3, o['didx'] & 0xFF]))
        elif mn == 'vumov':
            emit(bytes([OP_VUMOV, o['rd'] & 31, o['vn'] & 31, o['esz'] & 3, o['idx'] & 0xFF, o['sgn'] & 1]))
        elif mn == 'vext':
            emit(bytes([OP_VEXT, o['vd'] & 31, o['vn'] & 31, o['vm'] & 31, o['idx'] & 0xFF, o['q'] & 1]))
        elif mn == 'vperm':
            emit(bytes([OP_VPERM, o['vd'] & 31, o['vn'] & 31, o['vm'] & 31,
                        o['esz'] & 3, o['kind'] & 0xFF, o['q'] & 1]))
        elif mn == 'ldr_lit_fp':
            target = addr + o['off']
            if (o['rt'] & 31) != 31:
                emit(bytes([OP_LOAD_LIT_FP, o['rt'] & 31]) +
                     struct.pack('<I', target & 0xFFFFFFFF) + bytes([o['sz'] & 1]))
        elif mn == 'fcmp':
            emit(bytes([OP_FCMP, o['rn'], o['rm'], o['sf']]))
        elif mn == 'fcmp_zero':
            emit(bytes([OP_FCMP_Z, o['rn'] & 31, o['sf'] & 1]))
        elif mn == 'fcsel':
            emit(bytes([OP_FCSEL, o['rd'] & 31, o['rn'] & 31, o['rm'] & 31,
                        o['cond'] & 0xF, o['sf'] & 1]))
        elif mn == 'fmadd':
            emit(bytes([OP_FMADD, o['rd'] & 31, o['rn'] & 31, o['rm'] & 31,
                        o['ra'] & 31, o['sf'] & 1, (o['o0'] & 1) | ((o['o1'] & 1) << 1)]))
        elif mn == 'fcvt':
            emit(bytes([OP_FCVT, o['rd'], o['rn'], o['dir']]))
        elif mn == 'scvtf':
            emit(bytes([OP_SCVTF, o['rd'], o['rn'], o['fsf'], o['isw']]))
        elif mn == 'ucvtf':
            emit(bytes([OP_UCVTF, o['rd'], o['rn'], o['fsf'], o['isw']]))
        elif mn == 'fcvtzs':
            emit(bytes([OP_FCVTZS, o['rd'], o['rn'], o['fsf'], o['isw']]))
        elif mn == 'fcvtzu':
            emit(bytes([OP_FCVTZU, o['rd'], o['rn'], o['fsf'], o['isw']]))
        elif mn in ('ldr_fp', 'str_fp'):
            opf = OP_LOAD_FP if mn == 'ldr_fp' else OP_STORE_FP
            off = o['off'] & 0xFFFF
            emit(bytes([opf, o['rt'], o['rn']]) + struct.pack('<H', off & 0xFFFF) + bytes([o['sz']]))

        elif mn in ('sbfm', 'bfm', 'ubfm'):
            # VM 侧统一用 UBFM 语义处理, SBFM 额外做符号扩展
            emit(bytes([OP_UBFM, o['rd'], o['rn'], o['immr'], o['imms'], o['sf']]))
            if mn == 'sbfm':
                emit(bytes([OP_UBFM, o['rd'], o['rd'], 0, o['imms'] & 0x3F, o['sf']]))  # 占位, 精确符号扩展见 handler

        elif mn == 'ld_st_idx9':
            # pre-index : addr = Rn + off; Rn = addr; 再访问
            # post-index: 先访问 Rn; 然后 Rn += off
            rn, rt, off, sz = o['rn'], o['rt'], o['off'], o['size']
            lop = {0: OP_LOAD8, 1: OP_LOAD16, 2: OP_LOAD32, 3: OP_LOAD64}[sz]
            sop = {0: OP_STORE8, 1: OP_STORE16, 2: OP_STORE32, 3: OP_STORE64}[sz]
            def addsub_imm(reg, val):
                if val >= 0:
                    emit(bytes([OP_ADD_IMM, reg, reg]) + struct.pack('<I', val))
                else:
                    emit(bytes([OP_SUB_IMM, reg, reg]) + struct.pack('<I', -val))
            if o['mode'] == 'pre':
                addsub_imm(rn, off)                       # Rn += off
                if o['store']:
                    emit(bytes([sop, rn, rt]) + struct.pack('<H', 0))
                else:
                    emit(bytes([lop, rt, rn]) + struct.pack('<H', 0))
            else:  # post
                if o['store']:
                    emit(bytes([sop, rn, rt]) + struct.pack('<H', 0))
                else:
                    emit(bytes([lop, rt, rn]) + struct.pack('<H', 0))
                addsub_imm(rn, off)                       # 访问后再加

        elif mn in ('ldr_idx', 'str_idx'):
            sz = o['size']
            if mn == 'ldr_idx':
                opi = {0: OP_LOAD_IDX8, 1: OP_LOAD_IDX16, 2: OP_LOAD_IDX32, 3: OP_LOAD_IDX64}[sz]
            else:
                opi = {0: OP_STORE_IDX8, 1: OP_STORE_IDX16, 2: OP_STORE_IDX32, 3: OP_STORE_IDX64}[sz]
            emit(bytes([opi, o['rt'], o['rn'], o['rm'], o['shift'] & 0xF]))

        elif mn == 'bl':
            target = addr + o['off']
            emit(bytes([OP_CALL_LIT]) + struct.pack('<I', target & 0xFFFFFFFF))

        elif mn == 'ldr_lit':
            # PC 相对常量: 运行时地址 = image_base(R28) + target_offset
            target = addr + o['off']
            op = {0: OP_LOAD_LIT8, 1: OP_LOAD_LIT16,
                  2: OP_LOAD_LIT32, 3: OP_LOAD_LIT64}[o['size']]
            if (o['rt'] & 31) == 31:
                # ★ ldr xzr, #lit —— 加载到零寄存器（丢弃）
                #   绝不能生成 LOAD_LIT 写 R31！R31 是虚拟 SP
                pass
            else:
                emit(bytes([op, o['rt']]) + struct.pack('<I', target & 0xFFFFFFFF))

        elif mn in ('and_lit', 'orr_lit', 'eor_lit', 'ands_lit'):
            imm = o['imm']
            if imm <= 0xFFFFFFFF:
                opi = {'and_lit': OP_AND_IMM, 'orr_lit': OP_OR_IMM,
                       'eor_lit': OP_XOR_IMM, 'ands_lit': OP_AND_IMM}[mn]
                emit(bytes([opi, o['rd'], o['rn']]) + struct.pack('<I', imm))
                if mn == 'ands_lit':
                    # ANDS 会设标志, 这里用 CMP 补上(只关心常见用法)
                    emit(bytes([OP_CMP_IMM, o['rd']]) + struct.pack('<I', 0))
            else:
                # 64 位掩码：ADD_IMM/AND_IMM 的立即数字段只有 32 位，
                # 无法直接表达 >32 位的掩码。改成：把完整 64 位掩码装进
                # 临时寄存器 R30，再做寄存器-寄存器逻辑运算。
                #   MOV_IMM R30, imm64
                #   AND/ORR/EOR Rd, Rn, R30
                # R30 是本工具链约定的临时寄存器（见 ldr_fp_idx 等分支）。
                # 若 Rd/Rn 恰好用到 R30，退回报错以保持旧语义（极少见）。
                scratch = 30
                if (o['rd'] & 31) == scratch or (o['rn'] & 31) == scratch:
                    raise TransError("64 位掩码与临时寄存器 x30 冲突: 0x%x" % imm)
                regop = {'and_lit': OP_AND, 'orr_lit': OP_OR,
                         'eor_lit': OP_XOR, 'ands_lit': OP_AND}[mn]
                emit(bytes([OP_MOV_IMM, scratch]) + struct.pack('<Q', imm & 0xFFFFFFFFFFFFFFFF))
                if (o['rn'] & 31) == 31:
                    # Rn 为 ZR：and→0，orr/eor→mask（绝不能把 R31=SP 当操作数）
                    if mn == 'and_lit':
                        emit(bytes([OP_MOV_IMM32, o['rd'] & 31]) + struct.pack('<I', 0))
                    else:
                        emit(bytes([OP_MOV_REG, o['rd'] & 31, scratch]))
                else:
                    emit(bytes([regop, o['rd'] & 31, o['rn'] & 31, scratch]))
                if mn == 'ands_lit':
                    emit(bytes([OP_CMP_IMM, o['rd'] & 31]) + struct.pack('<I', 0))

        elif mn in ('ldr', 'str'):
            size = o['size']
            if mn == 'ldr':
                op = {0: OP_LOAD8, 1: OP_LOAD16, 2: OP_LOAD32, 3: OP_LOAD64}[size]
                emit(bytes([op, o['rt'], o['rn']]) + struct.pack('<H', o['off'] & 0xFFFF))
            else:
                op = {0: OP_STORE8, 1: OP_STORE16, 2: OP_STORE32, 3: OP_STORE64}[size]
                emit(bytes([op, o['rn'], o['rt']]) + struct.pack('<H', o['off'] & 0xFFFF))

        elif mn == 'ldrsw':
            # LDRSW Xt, [Xn, #off]: 载入 32 位并符号扩展到 64 位。
            # 只用已支持的 opcode 实现（无需新 handler）：
            #   LOAD32 Rt,[Rn,off]  (R[t] 低 32 位 = 内存值，高 32 位清零)
            #   SHL_IMM Rt,Rt,#32   (把符号位移到 bit63)
            #   ASR_IMM Rt,Rt,#32   (算术右移 32 位 → 完成符号扩展)
            # 注：Rt==31 为 XZR（丢弃结果），绝不能写 R[31]=虚拟 SP。
            if (o['rt'] & 31) == 31:
                pass  # ldrsw xzr, [...]：无副作用，直接丢弃
            else:
                rt = o['rt'] & 31
                emit(bytes([OP_LOAD32, rt, o['rn']]) + struct.pack('<H', o['off'] & 0xFFFF))
                emit(bytes([OP_SHL_IMM, rt, rt]) + struct.pack('<I', 32))
                emit(bytes([OP_ASR_IMM, rt, rt]) + struct.pack('<I', 32))

        elif mn == 'ldrs':
            # LDRSB/LDRSH Xt/Wt, [Xn, #off]: 载入字节/半字并符号扩展。
            # 同 ldrsw 思路（仅用已有 opcode）：LOAD8/16 零扩展 → SHL → ASR 符号扩展。
            #   size 0=字节(移 56), 1=半字(移 48); is32 则再掩掉高 32 位（Wt 变体）。
            if (o['rt'] & 31) == 31:
                pass
            else:
                rt = o['rt'] & 31
                ld = OP_LOAD8 if o['size'] == 0 else OP_LOAD16
                sh = 56 if o['size'] == 0 else 48
                emit(bytes([ld, rt, o['rn']]) + struct.pack('<H', o['off'] & 0xFFFF))
                emit(bytes([OP_SHL_IMM, rt, rt]) + struct.pack('<I', sh))
                emit(bytes([OP_ASR_IMM, rt, rt]) + struct.pack('<I', sh))
                if o.get('is32'):
                    emit(bytes([OP_AND_IMM, rt, rt]) + struct.pack('<I', 0xFFFFFFFF))

        elif mn in ('br', 'blr'):
            # v-cov80: 浮点参数问题已在 h_system.h 的 vm_call_native_fp 解决
            #   （调用时同时传 R0-R7 和 d0-d7）。故放开 br/blr：
            #     blr Xn → OP_CALL_REG（调用，执行后继续）
            #     br  Xn → OP_BR_REG（函数内查映射表跳转 / 函数外当尾调用）
            if mn == 'blr':
                emit(bytes([OP_CALL_REG, o['rn'] & 31]))
            else:
                emit(bytes([OP_BR_REG, o['rn'] & 31]))

        elif mn == 'b':
            tgt_idx = idx + o['off'] // 4
            if 0 <= tgt_idx <= len(insts):
                # 函数内部跳转（tgt_idx==len 表示跳到结尾=HALT，由回填处理）
                pos = vm_pos()
                emit(bytes([OP_JMP]) + struct.pack('<I', 0))
                fixups.append((pos + 1, tgt_idx, 'jmp'))
            else:
                # 越界 b = 尾调用另一个函数：等价 call target; return
                # （和 bl 同构：CALL_LIT 走 image_base+偏移，再 HALT 返回其结果）
                target = addr + o['off']
                emit(bytes([OP_CALL_LIT]) + struct.pack('<I', target & 0xFFFFFFFF))
                emit(bytes([OP_HALT]))

        elif mn == 'bcond':
            c = o['cond']
            pos = vm_pos()
            op = {0: OP_JE, 1: OP_JNE, 0xB: OP_JL, 0xA: OP_JGE,
                  0xC: OP_JGT, 0xD: OP_JLE, 3: OP_JB, 2: OP_JAE,
                  9: OP_JBE, 8: OP_JA}.get(c)
            if op is None:
                raise TransError("不支持的 cond 0x%x" % c)
            emit(bytes([op]) + struct.pack('<I', 0))
            fixups.append((pos + 1, idx + o['off'] // 4, 'jcc'))

        elif mn in ('cbz', 'cbnz'):
            # CMP Rt, #0 ; JE/JNE target
            emit(bytes([OP_CMP_IMM, o['rt']]) + struct.pack('<I', 0))
            pos = vm_pos()
            emit(bytes([OP_JE if mn == 'cbz' else OP_JNE]) + struct.pack('<I', 0))
            fixups.append((pos + 1, idx + o['off'] // 4, 'jcc'))

        elif mn in ('tbz', 'tbnz'):
            # TBZ/TBNZ 字节码: [op][reg][bit][target32]  7B
            op = OP_TBZ if mn == 'tbz' else OP_TBNZ
            pos = vm_pos()
            emit(bytes([op, o['rt'] & 31, o['bit'] & 63]) + struct.pack('<I', 0))
            fixups.append((pos + 3, idx + o['off'] // 4, 'jcc'))

        elif mn == 'tst':
            # [op][rn][rm][pad] 4B -> ANDS XZR: 只设 Z/N
            emit(bytes([OP_TST, o['rn'], o['rm'], 0]))

        elif mn == 'fmov_gen':
            emit(bytes([OP_FMOV_GEN, o['fd'], o['rn']]))

        elif mn == 'extr':
            emit(bytes([OP_EXTR, o['rd'], o['rn'], o['rm'], o['lsb'] & 63, o['sf'] & 1]))

        elif mn in ('lslv', 'lsrv', 'asrv', 'rorv'):
            op = {'lslv': OP_SHL, 'lsrv': OP_SHR, 'asrv': OP_ASR, 'rorv': OP_ROR}[mn]
            emit(bytes([op, o['rd'], o['rn'], o['rm']]))

        elif mn in ('ccmp_reg', 'ccmn_reg'):
            op = OP_CCMP_REG if mn == 'ccmp_reg' else OP_CCMN_REG
            emit(bytes([op, o['cond'] & 0xF, o['nzcv'] & 0xF,
                        o['rn'] & 31, o['rm'] & 31, o['sf'] & 1]))
        elif mn in ('ccmp_imm', 'ccmn_imm'):
            op = OP_CCMP_IMM if mn == 'ccmp_imm' else OP_CCMN_IMM
            emit(bytes([op, o['cond'] & 0xF, o['nzcv'] & 0xF,
                        o['rn'] & 31, o['imm'] & 0x1F, o['sf'] & 1]))

        else:
            raise TransError("未实现翻译: %s" % mn)

        # v-bcjunk: 真实指令之后以一定概率插中性垃圾(跳过无条件终止指令后,避免纯死码)
        if _BCJUNK and mn not in ('b', 'ret', 'br') and _bjr.random() < _BCJUNK_P:
            _emit_bcjunk()

    # 回填跳转
    tail = len(insts)
    for fpos, tgt_idx, kind in fixups:
        if tgt_idx == tail:
            target = len(code)          # 跳到结尾 -> HALT
        else:
            target = vm_off.get(tgt_idx)
            if target is None:
                raise TransError("跳转目标越界: +%d" % (tgt_idx * 4))
        struct.pack_into('<I', code, fpos, target)

    # 结尾补 HALT (返回 R0)
    emit(bytes([OP_HALT]))

    # ---- OpcodeCryptor: 只有 opcode 字节参与加密 ----
    # ★ v-bcenc: oc_key 从 0 改为每函数随机 32 位非零密钥。
    #   原来 oc_key=0 时 opcode 仅被公开常量 (pc*0x9E3779B9) 异或 —— 逆向者读一遍
    #   vm_interp 即可脱；非零 oc_key 让每个函数的字节码必须先从 trailer 取密钥才能解，
    #   __vmpbc 不再能被"读懂解释器后直接批量解码"。vm_interp 已从 trailer 读 oc_key 解密，
    #   路径本就在跑，仅密钥值变化，device 安全。可用环境变量 GCOBF_OCKEY=0 关掉以对拍调试。
    import os as _os
    if _os.environ.get("GCOBF_OCKEY") == "0":
        oc_key = 0
    else:
        import random as _rnd
        oc_key = _rnd.randint(1, 0xFFFFFFFF)
    for pos in op_pos:
        # 与 vm_interp 的 OC_DECRYPT 严格对称：按 pos&3 取 oc_key 的字节
        kb = (oc_key >> ((pos & 3) * 8)) & 0xFF
        code[pos] ^= (kb ^ (pos * 0x9E3779B9)) & 0xFF

    # ---- v-integ: 字节码完整性 CRC ----
    #   对 opcode 区(trailer 之前的全部字节, 即 vm_interp 解 xor 后 bc_buf[0:proper_len])
    #   求 CRC32(标准 0xEDB88320, 与 vm_crc.h / zlib 一致)。被 patch 则校验不过 →
    #   vm_interp 不崩溃, 改为破坏 oc_key → 后续指令解密全错 → 静默算错结果(红队 #14)。
    #   CRC=0 作"不校验"哨兵。默认开; GCOBF_INTEG=0 关(写 0)。
    import zlib as _zlib
    if _os.environ.get("GCOBF_INTEG") == "0":
        bc_crc = 0
    else:
        bc_crc = _zlib.crc32(bytes(code)) & 0xFFFFFFFF
        if bc_crc == 0:
            bc_crc = 1   # 避免与"不校验"哨兵冲突
    # ---- 25 字节 trailer: reverse(1) oc_key(4) map_count(4) func_addr(8) func_size(4) bc_crc(4) ----
    code.extend(bytes([0]) + struct.pack("<I", oc_key) + struct.pack("<I", 0) +
                struct.pack("<Q", 0) + struct.pack("<I", 0) + struct.pack("<I", bc_crc))
    return bytes(code)


# ============================================================
# 自测
# ============================================================
def selftest(binf):
    data = open(binf, 'rb').read()
    # 只取 .text 段的原始字节(调用方保证传入裸指令流)
    insts = [(i * 4, struct.unpack_from('<I', data, i * 4)[0]) for i in range(len(data) // 4)]
    ok = 0
    bad = []
    for addr, w in insts:
        d = decode(w)
        if d: ok += 1
        else: bad.append((addr, w))
    print("解码: %d/%d 成功" % (ok, len(insts)))
    for a, w in bad[:10]:
        print("   未知 0x%08x @ +0x%x" % (w, a))
    return ok, len(insts)


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'selftest':
        selftest(sys.argv[2])
    else:
        print(__doc__)

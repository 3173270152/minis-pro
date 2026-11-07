#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批量生成 VMP hook 代码 + 所有字节码"""
import sys, struct, subprocess, os, os
import random, zlib
# ★ v-stubpoly: 入口桩多态化的构建种子(可用 GCOBF_SEED 固定以复现构建)
_STUB_SEED = int(os.environ.get("GCOBF_SEED", "0")) or random.randint(1, 0x7FFFFFFF)

# 通用化: 脚本相对找 vmp 翻译器
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "vmp"))
import vmp

# 用法: python3 gen_multi_hooks.py <目标dylib> [输出目录]  (或设 GCOBF_DYLIB / GCOBF_OUTDIR)
DYLIB = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GCOBF_DYLIB", ""))
if not DYLIB:
    sys.exit("用法: gen_multi_hooks.py <目标dylib> [输出目录]  (或设环境变量 GCOBF_DYLIB)")
# ★ BC_FIXED: 单函数字节码固定槽位。1024 时约 36 个函数因超长被跳过。
#   提到 2048 可纳入这些函数；固定大小仍保证 __DATA,__vmpbc 大小不随
#   字节码内容变化（自举收敛的关键没变）。代价：__vmpbc 段约翻倍。
BC_FIXED = 8192   # v-bcjunk: 开字节码垃圾注入后单函数膨胀 ~1.8x,提到 8192 保住覆盖(字节覆盖仍 61%)
# ★ v-hide: VMP 段改名，去掉 "__vmpstub"/"__vmpbc" 这类一眼可查的指纹。
#   报告正是靠段名秒认出"用了 VMP"。改成中性名；要更强可每构建随机后缀。
STUB_SEG, STUB_SN = "__TEXT", "__textext"   # 原 __TEXT,__vmpstub（hook 代码）
BC_SEG,   BC_SN   = "__DATA", "__dataext"   # 原 __DATA,__vmpbc（字节码）

_OUTDIR = (sys.argv[2] if len(sys.argv) > 2
           else os.environ.get("GCOBF_OUTDIR",
                os.path.dirname(os.path.abspath(DYLIB)) or "."))
os.makedirs(_OUTDIR, exist_ok=True)
OUT_H = os.path.join(_OUTDIR, "g_bc_multi.h")
OUT_XM = os.path.join(_OUTDIR, "VMPHooks.xm")

# ================== 静态抹除 (wipe) 策略 ==================
# 抹除 = 把已虚拟化函数的原体从 __text 换成桩，让静态/dump 也看不到。
# 被抹函数一律 fail-closed：VM 跑崩不再降级调原函数（原体已没了），直接返回 0。
# ⚠️ 代价：抹除会去掉「VM 失败时回退原函数」的安全网。只有 VM 对该函数可靠时才安全。
#   WIPE_MODE:
#     "off"  —— 只生成候选名单(g_wipe_candidates.txt)，不实际抹、不改降级（最安全，先这个）
#     "named"—— 只抹命门(授权/反调试，见 WIPE_NAMED_SUBSTR)，这些本就该 fail-closed
#     "all"  —— 抹全部已虚拟化函数（冲静态覆盖 ~80%，需上机分批验证；起不来就缩名单）
WIPE_MODE = "off"
# 永不抹的函数名子串(保护器自身入口/反调试/初始化等), 避免递归与早期路径炸裂
WIPE_EXCLUDE_SUBSTR = (
    # C2#1 ObjC 初始化/生命周期
    "init", "load", "shared", "alloc", "new", "copy", "dealloc", "cxx", "ctor", "initialize",
    # C2#2 授权启动路径（虚拟化但不抹，保留降级，避免 VM 失败锁死启动）
    "authoriz", "silentverify", "deviceid", "verifywith", "verifyhttp",
    # C2#3 反调试基础设施（本就不虚拟化，belt-and-suspenders）
    "guard", "watchdog", "killer", "checkpoint", "sigaltstack", "ad_query", "ad_rescan",
    # C2#4 渲染/事件主循环（命名的；匿名的上机按 addr 剔除）
    "draw", "update", "layout", "display", "gesture", "mtkview",
    # C2#6 C++ 全局构造
    "global_var_init", "global__sub_i",
)
# "named" 模式要抹 + fail-closed 的函数名子串(逗号分隔), 由调用方按需指定; 默认空。
#   例: GCOBF_WIPE_NAMED=license_,secret_
WIPE_NAMED_SUBSTR = tuple(s for s in os.environ.get("GCOBF_WIPE_NAMED", "").split(",") if s.strip())


def _wipe_decide(name, raw_sym):
    """返回是否抹除该函数。"""
    hay = (name + " " + raw_sym).lower()
    if any(s.lower() in hay for s in WIPE_EXCLUDE_SUBSTR):
        return False
    if WIPE_MODE == "off":
        return False
    if WIPE_MODE == "named":
        return any(s.lower() in hay for s in WIPE_NAMED_SUBSTR)
    if WIPE_MODE == "all":
        return True
    return False

# 12 个可保护函数（pickvm 的结果）
_FAKE_SEL = {}
try:
    for _l in open("/tmp/sel_fake.txt"):
        _a, _b = _l.rstrip("\n").split("\t")
        if _b and _b != "None":
            _FAKE_SEL[_a] = _b
except Exception:
    pass


def scan_all_functions(buf):
    """★ 用 LC_FUNCTION_STARTS (0x26) 解析函数表 —— 链接器生成的权威数据，
    每个条目都是真函数入口（strip 后依然保留）。比 __unwind_info 可靠得多。"""
    o = 32
    n = struct.unpack_from('<I', buf, 16)[0]
    foff = fsize = 0
    for _ in range(n):
        cmd, sz = struct.unpack_from('<II', buf, o)
        if cmd == 0x26:
            foff, fsize = struct.unpack_from('<II', buf, o+8)
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
            b = buf[p]; p += 1
            delta |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80): break
        if delta == 0: break
        addr += delta
        funcs.append(addr)
    return funcs

def text_range(buf):
    o = 32; n = struct.unpack_from('<I', buf, 16)[0]; tr = None
    for _ in range(n):
        cmd, sz = struct.unpack_from('<II', buf, o)
        if cmd == 0x19:
            seg = buf[o+8:o+24].split(b'\0')[0].decode()
            ns = struct.unpack_from('<I', buf, o+64)[0]; so = o + 72
            for j in range(ns):
                sn = buf[so:so+16].split(b'\0')[0].decode()
                a, s2 = struct.unpack_from('<QQ', buf, so+32)
                if seg == '__TEXT' and sn == '__text': tr = (a, s2)
                so += 80
        o += sz
    return tr

# 额外强制虚拟化的函数名(逗号分隔,其余全自动扫描)。默认空=纯自动。
#   例: GCOBF_TARGETS=license_check,secret_init
TARGETS = [t for t in os.environ.get("GCOBF_TARGETS", "").split(",") if t.strip()]

raw = open(DYLIB, 'rb').read()
nmout = subprocess.run(["nm", DYLIB], capture_output=True, text=True).stdout

# 建符号表
syms = {}      # 友好名 -> (addr, 原始符号名)
for line in nmout.split("\n"):
    p = line.split()
    if len(p) >= 3 and p[1] in ("T", "t"):
        try:
            raw_sym = p[2]
            friendly = raw_sym.lstrip("_")
            syms[friendly] = (int(p[0], 16), raw_sym)
        except ValueError:
            pass

results = []   # (name, addr, bc)

for name in TARGETS:
    ent = syms.get(name)
    if ent is None:
        for k, v in syms.items():
            if name in k:
                ent = v
                break
    if ent is None:
        print("  ✗ 找不到符号: %s" % name)
        continue
    addr, raw_sym = ent
    insts = []
    pos = 0
    ok = True
    while pos < 0x2000:
        w = struct.unpack_from('<I', raw, addr + pos)[0]
        d = vmp.decode(w)
        if d is None:
            print("  ✗ %s: 解码失败 @ +0x%x (%08x)" % (name, pos, w))
            ok = False
            break
        insts.append((addr + pos, w))
        pos += 4
        if d[0] == 'ret':
            break
    if not ok:
        continue
    try:
        bc = vmp.translate(insts)
    except Exception as ex:
        print("  ✗ %s: 翻译失败 %s" % (name, ex))
        continue
    print("  ✓ %-24s @0x%06x  %2d 指令 -> %3d 字节" % (name, addr, len(insts), len(bc)))
    results.append((name, addr, bc, raw_sym))

# ===== 全自动：__unwind_info 扫描 + 只为地址无关函数生成 hook =====
_all = scan_all_functions(raw)
_tr = text_range(raw)
if _tr:
    _all = [a for a in _all if _tr[0] <= a < _tr[0] + _tr[1]]
print("  [auto] __text 内函数: %d" % len(_all))
# ★ 按 __TEXT,__vmpstub 段范围排除我们自己生成的 hook（否则数量会自我繁殖）
try:
    _o2 = 32; _n2 = struct.unpack_from('<I', raw, 16)[0]; _vs = None
    for _ in range(_n2):
        _c2, _s2 = struct.unpack_from('<II', raw, _o2)
        if _c2 == 0x19:
            _seg2 = raw[_o2+8:_o2+24].split(b'\0')[0].decode()
            _ns2 = struct.unpack_from('<I', raw, _o2+64)[0]; _so2 = _o2 + 72
            for _j2 in range(_ns2):
                _sn2 = raw[_so2:_so2+16].split(b'\0')[0].decode()
                _a2b, _s2b = struct.unpack_from('<QQ', raw, _so2+32)
                if _seg2 == STUB_SEG and _sn2 == STUB_SN:
                    _vs = (_a2b, _s2b)
                _so2 += 80
        _o2 += _s2
    if _vs and _vs[1] > 0:
        _b2 = len(_all)
        _all = [a for a in _all if not (_vs[0] <= a < _vs[0] + _vs[1])]
        print("  [auto] __vmpstub 排除: %d -> %d" % (_b2, len(_all)))
except Exception as _e2:
    print("  [auto] 段排除跳过:", _e2)
# ★ 索引锁定：第一次扫描确定"第几个函数"要保护，之后每次编译都按索引取新地址
_IDX_CACHE = os.path.join(_OUTDIR, "vmp_idx.lock")
_idx_list = None   # 索引锁定已废弃（对应关系不稳定）
try:
    import json as _j2
    if False and os.path.exists(_IDX_CACHE):
        _idx_list = _j2.load(open(_IDX_CACHE))
        print("  [auto] 使用索引锁: %d 个" % len(_idx_list))
except Exception:
    _idx_list = None   # 索引锁定已废弃（对应关系不稳定）
_new_idx = []
_okc = 0
for _i, _addr in enumerate(_all):
    if _idx_list is not None and _i not in _idx_list:
        continue
    _end = _all[_i+1] if _i+1 < len(_all) else _addr + 0x4000
    # ★ 全窗口 + 可达性守卫解码（见 vmp.decode_function），修复旧版在第一条
    #   内部 b 就截断导致「跳转越界」海量跳过的问题，同时防止误读字面量池。
    _insts, _err = vmp.decode_function(raw, _addr, min(_end, _addr + 0x4000))
    _bad = _err is not None
    if _bad or not _insts:
        continue
    # ★ 安全门槛 1（改进版）：hook 会覆盖函数开头若干字节，必须不越界到「下一个函数」。
    #   旧版用「指令<6条」做粗略代理，误杀了大量「小但后面有对齐填充」的函数（真正虚拟化率
    #   从天花板 ~82% 掉到 ~46%）。正确判据是「到下一函数的间距 ≥ hook 桩长」：
    #     MIN_HOOK_GAP=16  —— 对任何 Dobby 桩都安全（含 16B 的 LDR+BR 远跳），但只到 ~58%
    #     MIN_HOOK_GAP=8   —— Dobby 近距离用 4B 的 B 跳；留余量，~79%（默认，较稳）
    #     MIN_HOOK_GAP=4   —— 冲 >80%（干净版 80.5%）；赌 Dobby 全程用 4B 近跳，
    #                        **必须上机验证**（hook 全部后无崩、函数结果正确、下一函数未损坏）
    #   用环境变量 GCOBF_MINGAP 覆盖。
    _MIN_HOOK_GAP = int(os.environ.get("GCOBF_MINGAP", "8"))
    if (_end - _addr) < _MIN_HOOK_GAP:
        continue
    # ★ 安全门槛 2：函数不能靠近页尾（Substrate 会连续读 16~32 字节，跨页会崩）
    if (_addr & 0xFFF) > 0x1000 - 64:
        continue
    # ★ 安全门槛 3：排除 thunk（adrp + ldr + br 三指令跳转桩）
    if len(_insts) <= 4 and any(w & 0xFFFFFC1F == 0xD61F0000 for _, w in _insts):
        continue
    # 第一条指令必须是真实的函数入口（不能是 udf/brk/立即返回）
    _w0 = _insts[0][1]
    if _w0 in (0x00000000, 0xFFFFFFFF) or (_w0 & 0xFFFF0000) == 0xD4200000:
        continue
    try:
        _bc = vmp.translate(_insts)
    except Exception:
        continue
    if len(_bc) > BC_FIXED:
        continue
    _okc += 1
    _new_idx.append(_i)
    _name = "Auto_%x" % _addr
    results.append((_name, _addr, _bc, "IMP:0x%x" % _addr))
if False:
    try:
        import json as _j3
        _j3.dump(_new_idx, open(_IDX_CACHE, "w"))
        print("  [auto] 已锁定索引: %d 个" % len(_new_idx))
    except Exception as _e3:
        print("  [auto] 锁定失败:", _e3)
print("  [auto] 地址无关且可翻译: %d (其余不 hook)" % _okc)


# ===== 生成 g_bc_multi.h =====
# ★ v-bcenc: 每函数随机 xor_key（字节）。oc_key 只加密 opcode 字节，操作数(立即数/偏移)
#   仍明文；xor_key 对整条字节码按字节异或，盖住操作数。两者互补。vm_entry 第 4 参传此 key。
import random as _rnd_bc
BC_XOR = {}
for name, addr, bc, raw_sym in results:
    BC_XOR[name] = _rnd_bc.randint(1, 255)
h = ["// 自动生成：%d 个函数的 VM 字节码" % len(results), ""]
for name, addr, bc, raw_sym in results:
    _k = BC_XOR[name]
    h.append("// %s @ 0x%x (%d 字节)" % (name, addr, len(bc)))
    h.append('__attribute__((used, section("%s,%s")))' % (BC_SEG, BC_SN))
    h.append("static const unsigned char bc_%s[%d] = {" % (name, BC_FIXED))
    # 前 len(bc) 字节按 xor_key 加密（vm_entry 会解密这 bc_len 字节）；padding 保持 0
    enc = [(b ^ _k) & 0xFF for b in bc]
    padded = enc + [0] * (BC_FIXED - len(enc))
    for i in range(0, BC_FIXED, 12):
        h.append("    " + ", ".join("0x%02x" % b for b in padded[i:i+12]) + ",")
    h.append("};")
    h.append("static const unsigned int bc_%s_len = %d;" % (name, len(bc)))
    h.append("")
open(OUT_H, "w").write("\n".join(h))
print("\n已写 %s" % OUT_H)

# ===== 生成 VMPHooks.xm =====
x = []
x.append('// VMPHooks.xm — 自动生成，%d 个函数的 VMP hook' % len(results))
x.append('')
x.append('#import <substrate.h>')
x.append('#import <Foundation/Foundation.h>')
x.append('#include "dobby.h"')
x.append('#include <setjmp.h>')
x.append('#include <signal.h>')
x.append('#import <stdio.h>')
x.append('#import <stdarg.h>')
x.append('#import <stdlib.h>')
x.append('#import <string.h>')
x.append('#import <mach-o/dyld.h>')
x.append('#import <objc/runtime.h>')
x.append('#import <sys/mman.h>')
x.append('#import <stdlib.h>')
x.append('#import <dlfcn.h>')
x.append('')
x.append('#include "g_bc_multi.h"')
x.append('')
x.append('extern "C" unsigned long long vm_entry(unsigned long long *args,')
x.append('                                       unsigned char *enc_bc,')
x.append('                                       unsigned int bc_len,')
x.append('                                       unsigned char xor_key);')
x.append('')
x.append('/* vmlog: release 版 —— noinline 空函数（保留调用，防止 -Os 过度优化） */')
x.append('__attribute__((noinline)) static void vmlog(const char *fmt, ...) {')
x.append('    (void)fmt;')
x.append('}')
x.append('')
x.append('static void *vmp_image_base = 0;')
x.append('')
x.append('/* ★ hook 容错：DobbyHook 内部崩了不能拖垮整个 App，用 sigsetjmp 兜住 */')
x.append('static sigjmp_buf gcob_hook_jb;')
x.append('static volatile int gcob_hook_armed = 0;')
x.append('static volatile int gcob_hook_ok = 0, gcob_hook_skip = 0;')
x.append('extern "C" {')
x.append('extern sigjmp_buf g_vm_jb;')
x.append('extern volatile int g_vm_armed, g_vm_failed;')
x.append('}')
x.append('static void gcob_hook_segv(int sig) {')
x.append('    if (gcob_hook_armed) { gcob_hook_armed = 0; siglongjmp(gcob_hook_jb, 1); }')
x.append('    if (g_vm_armed) { g_vm_armed = 0; g_vm_failed = 1; siglongjmp(g_vm_jb, 1); }')
x.append('    signal(sig, SIG_DFL); raise(sig);')
x.append('}')
x.append('')
x.append('/* ★ 独立信号栈：栈溢出时原来的栈已经爆了，handler 必须跑在备用栈上 */')
x.append('static char gcob_sigstk[SIGSTKSZ * 4];')
x.append('static void gcob_install_sigaltstack(void) {')
x.append('    stack_t ss;')
x.append('    ss.ss_sp = gcob_sigstk;')
x.append('    ss.ss_size = sizeof(gcob_sigstk);')
x.append('    ss.ss_flags = 0;')
x.append('    sigaltstack(&ss, 0);')
x.append('    struct sigaction sa;')
x.append('    memset(&sa, 0, sizeof(sa));')
x.append('    sa.sa_handler = gcob_hook_segv;')
x.append('    sa.sa_flags = SA_ONSTACK | SA_NODEFER;')
x.append('    sigemptyset(&sa.sa_mask);')
x.append('    sigaction(SIGSEGV, &sa, 0);')
x.append('    sigaction(SIGBUS,  &sa, 0);')
x.append('    sigaction(SIGILL,  &sa, 0);')
x.append('    sigaction(SIGTRAP, &sa, 0);')
x.append('}')
x.append('')
x.append('typedef long (*fn8_t)(long, long, long, long, long, long, long, long);')
x.append('')
x.append('/* C 函数前置声明（必须在文件作用域，且用 extern "C" 避免 C++ mangling） */')
for name, addr, bc, raw_sym in results:
    if not raw_sym.startswith("0x") and not raw_sym.startswith("__Z"):
        x.append('extern "C" void %s(void);' % name)
x.append('')
x.append('')

for name, addr, bc, raw_sym in results:
    x.append('/* ---- %s @ 0x%x  (%s) ---- */' % (name, addr, raw_sym))
    x.append('static void *addr_%s = 0;' % name)
    x.append('static fn8_t orig_%s = 0;' % name)
    # ★ v-threadsafe: 寄存器快照改为 naked asm 在「自己的栈帧」上分配，
    #   不再用全局 snap_%s[] 数组——否则多线程同时进同一 hook 会互相覆盖
    #   彼此的参数（STATUS 缺陷 A）。栈上快照天然每调用独立、可重入、免锁。
    x.append('extern "C" __attribute__((used, noinline)) long hook_%s_impl(unsigned long long *args);' % name)
    x.append('extern "C" __attribute__((used, noinline, section("%s,%s"))) long hook_%s_impl(unsigned long long *args) {' % (STUB_SEG, STUB_SN, name))
    x.append('    args[20]=(unsigned long long)vmp_image_base;')
    # ★ 被抹函数 fail-closed：原体已换成桩，orig_%s 不可用，VM 跑崩只能返回 0。
    _wiped = _wipe_decide(name, raw_sym)
    x.append('    const int _wiped = %d;' % (1 if _wiped else 0))
    x.append('    {')
    x.append('        static volatile int _broken = 0;')
    x.append('        if (_broken) {')
    x.append('            if (_wiped) return 0;')
    x.append('            fn8_t _o = (fn8_t)orig_%s;' % name)
    x.append('            if (!_o) return 0;')
    x.append('            return _o(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);')
    x.append('        }')
    x.append('        g_vm_armed = 1; g_vm_failed = 0;')
    x.append('        if (sigsetjmp(g_vm_jb, 1) != 0) {')
    x.append('            g_vm_armed = 0; _broken = 1;')
    x.append('            if (_wiped) return 0;')
    x.append('            fn8_t _o = (fn8_t)orig_%s;' % name)
    x.append('            if (!_o) return 0;')
    x.append('            return _o(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);')
    x.append('        }')
    x.append('    }')
    x.append('    args[21]=(unsigned long long)addr_%s;' % name)
    x.append('    vmlog("[enter] %s");' % name)
    # ★ 生产版移除逐调用文件日志：原来每次 hook 都 fopen/fprintf/fclose 写
    #   vmin.log（实测 80 万+ 次调用 = 80 万+ 次磁盘 IO，严重拖慢且留取证痕迹）。
    x.append('    unsigned long long vr = vm_entry(args, (unsigned char*)bc_%s, bc_%s_len, %d);' % (name, name, BC_XOR[name]))
    x.append('    g_vm_armed = 0;')
    x.append('    vmlog("[vm] %s ret=%%llu a0=0x%%llx a1=0x%%llx R0=0x%%llx", vr);' % name)
    x.append('    vmlog("[vm] %s ret=%%llu R0=%%llx", vr, args[0]);' % name)
    x.append('    return (long)vr;   /* ★ 返回值必须取 VM 结果 R0，不是入参 a0 */')
    x.append('}')
    x.append('')
    # ★ naked asm (v-threadsafe + v-float)：
    #   在自己的栈帧上分配 40 槽(320B)快照 → 每次调用独立、线程安全、可重入。
    #   args 槽位布局（与 vm_entry / vm_ctx_init 约定，字节偏移 = i*8）:
    #     [0..7]   x0-x7            （整数/指针参数）
    #     [8]      x29 (caller FP)  [9]  x30 (caller LR) —— 作为数据保存
    #     [10..19] x19-x28          （callee-saved 快照，保持旧偏移不变）
    #     [20]     image_base       （hook_impl 写）
    #     [21]     func_addr        （hook_impl 写）
    #     [22]     caller SP        （新增：供取栈地址的 handler 使用）
    #     [23]     FP 返回值出参     （新增：vm_entry 把 d0 结果写这里）
    #     [24..39] q0-q7            （新增：8×128bit 浮点参数，修复「浮点参数丢失」）
    #   用 bl + ret（不再 tail-branch），hook 作为函数天然替调用方保住 x19-x28。
    x.append('__attribute__((naked, section("%s,%s"))) static void hook_%s(void) {' % (STUB_SEG, STUB_SN, name))
    x.append('  __asm__ volatile(')
    # ★ v-stubpoly: 入口桩多态化(消除固定 asm 签名)。
    #   安全前提: 这 16 条保存指令各写不同栈偏移、只读寄存器(不改), 任意重排语义完全等价;
    #   帧只放大不缩小 → 所有固定偏移(≤0x170)仍有效, args 布局不变。
    #   默认开; GCOBF_NOSTUBPOLY=1 关(退回固定顺序, 便于对照调试)。
    _poly = os.environ.get("GCOBF_NOSTUBPOLY") != "1"
    _sr = random.Random(zlib.crc32(name.encode()) ^ _STUB_SEED)
    _frame = 0x180 + ((_sr.randint(0, 7) if _poly else 0) * 0x10)   # 0x180..0x1F0, 16 对齐
    _saves = [
        '"stp  x0,  x1,  [sp, #0x00]\\n"',
        '"stp  x2,  x3,  [sp, #0x10]\\n"',
        '"stp  x4,  x5,  [sp, #0x20]\\n"',
        '"stp  x6,  x7,  [sp, #0x30]\\n"',
        '"stp  x29, x30, [sp, #0x40]\\n"',
        '"stp  x19, x20, [sp, #0x50]\\n"',
        '"stp  x21, x22, [sp, #0x60]\\n"',
        '"stp  x23, x24, [sp, #0x70]\\n"',
        '"stp  x25, x26, [sp, #0x80]\\n"',
        '"stp  x27, x28, [sp, #0x90]\\n"',
        '"str  x16, [sp, #0xB0]\\n"',
        '"stp  q0,  q1,  [sp, #0xC0]\\n"',
        '"stp  q2,  q3,  [sp, #0xE0]\\n"',
        '"stp  q4,  q5,  [sp, #0x100]\\n"',
        '"stp  q6,  q7,  [sp, #0x120]\\n"',
        '"str  x30, [sp, #0x170]\\n"',
    ]
    if _poly:
        _sr.shuffle(_saves)
    # ★ v-stubpoly2: 变长垃圾(只碰 x17=IP1, 本桩全程不用它→安全), 破掉"每桩固定 24 条指令=
    #   等长等距可推断"的规律(红队 P0 #5/#6)。条数随机 → 桩长 ~80..200B 随机分布。
    def _stub_junk():
        out = []
        if not _poly:
            return out
        for _ in range(_sr.randint(2, 20)):
            k = _sr.randint(0, 0xffff)
            op = _sr.randint(0, 4)
            if op == 0:   out.append('      "movz x17, #0x%x\\n"' % k)
            elif op == 1: out.append('      "movk x17, #0x%x, lsl #16\\n"' % k)
            elif op == 2: out.append('      "eor  x17, x17, #0x%x\\n"' % ((k | 1) & 0xfff))
            elif op == 3: out.append('      "add  x17, x17, #0x%x\\n"' % (k & 0xfff))
            else:         out.append('      "sub  x17, x17, #0x%x\\n"' % (k & 0xfff))
        return out
    x.append('      "mov  x16, sp\\n"                 /* 先抓调用方 SP (x16=IP0 可随意覆盖) */')
    x.append('      "sub  sp, sp, #0x%x\\n"' % _frame)
    # 交错: 在保存序列前后各撒一段变长垃圾, 使总长度逐桩不同
    _blk = _stub_junk() + ['      ' + _s for _s in _saves] + _stub_junk()
    if _poly:
        # 垃圾与保存都已就绪; 保存必须全部出现在 bl 之前(顺序无关), 这里整体顺序即可
        pass
    for _ln in _blk:
        x.append(_ln)
    x.append('      "mov  x0, sp\\n"                  /* x0 = args 指针 */')
    x.append('      "bl   _hook_%s_impl\\n"           /* 返回值在 x0 (整数/指针) */' % name)
    x.append('      "ldr  d0, [sp, #0xB8]\\n"         /* args[23] → d0：浮点/double 返回值 */')
    x.append('      "ldr  x30, [sp, #0x170]\\n"       /* 恢复自身 LR */')
    x.append('      "add  sp, sp, #0x%x\\n"' % _frame)
    x.append('      "ret\\n"')
    x.append('  );')
    x.append('}')
    x.append('')

x.append('/* VMP_DISABLE_HOOKS 已移除：正式版真正执行 hook */')
x.append('static int _vmp_inited = 0;')
x.append('/* ===== selector 还原: 假名 -> 真名 (对抗 rename-selectors) ===== */')
x.append('#ifdef INCLUDE_SEL_MAP')
x.append('#include "sel_map.h"')
x.append('static void restore_selectors(void) {')
x.append('    unsigned char *map = (unsigned char *)malloc(_sel_map_len + 4);')
x.append('    if (!map) return;')
x.append('    for (unsigned int i = 0; i < _sel_map_len; i++)')
x.append('        map[i] = (unsigned char)(_sel_map[i] ^ 0x5A);')
x.append('    /* 类列表只取一次（性能） */')
x.append('    unsigned int nc = objc_getClassList(NULL, 0);')
x.append('    Class *cls = (Class *)malloc(nc * sizeof(Class));')
x.append('    if (!cls) { free(map); return; }')
x.append('    objc_getClassList(cls, nc);')
x.append('    unsigned char *q = map;')
x.append('    unsigned int count = *(unsigned int *)q; q += 4;')
x.append('    unsigned int ok = 0;')
x.append('    for (unsigned int i = 0; i < count; i++) {')
x.append('        unsigned short l = *(unsigned short *)q; q += 2;')
x.append('        char *real = (char *)q; q += l;')
x.append('        char *fake = (char *)q; q += l;')
x.append('        SEL real_sel = sel_registerName(real);')
x.append('        SEL fake_sel = sel_registerName(fake);')
x.append('        int found = 0;')
x.append('        for (unsigned int c = 0; c < nc; c++) {')
x.append('            Method m = class_getInstanceMethod(cls[c], fake_sel);')
x.append('            if (m) {')
x.append('                if (class_addMethod(cls[c], real_sel, method_getImplementation(m), method_getTypeEncoding(m)))')
x.append('                    found++;')
x.append('            }')
x.append('            m = class_getClassMethod(cls[c], fake_sel);')
x.append('            if (m) {')
x.append('                if (class_addMethod(object_getClass(cls[c]), real_sel, method_getImplementation(m), method_getTypeEncoding(m)))')
x.append('                    found++;')
x.append('            }')
x.append('        }')
x.append('        if (found) ok++;')
x.append('    }')
x.append('    free(cls);')
x.append('    free(map);')
x.append('    vmlog("[restore] %u/%u selectors restored", ok, count);')
x.append('}')
x.append('#endif')
x.append('')
x.append('/* ===== 类名还原: 改 class_ro_t.name 指针（不碰字符串表） ===== */')
x.append('#ifdef INCLUDE_SEL_MAP')
x.append('static void restore_classnames(void) {')
x.append('    unsigned int _nc_all = objc_getClassList(NULL, 0);')
x.append('    Class *_cls_all = (Class *)malloc(_nc_all * sizeof(Class));')
x.append('    if (!_cls_all) return;')
x.append('    objc_getClassList(_cls_all, _nc_all);')
x.append('    unsigned char *map = (unsigned char *)malloc(_sel_map_len + 4);')
x.append('    if (!map) return;')
x.append('    for (unsigned int i = 0; i < _sel_map_len; i++)')
x.append('        map[i] = (unsigned char)(_sel_map[i] ^ 0x5A);')
x.append('    unsigned char *q = map;')
x.append('    unsigned int count = *(unsigned int *)q; q += 4;')
x.append('    unsigned int fixed = 0;')
x.append('    for (unsigned int i = 0; i < count; i++) {')
x.append('        unsigned short l = *(unsigned short *)q; q += 2;')
x.append('        char *real = (char *)q; q += l;')
x.append('        char *fake = (char *)q; q += l;')
x.append('        Class c = 0;')
x.append('        for (unsigned int k = 0; k < _nc_all; k++) {')
x.append('            const char *cn = class_getName(_cls_all[k]);')
x.append('            if (cn && strcmp(cn, fake) == 0) { c = _cls_all[k]; break; }')
x.append('        }')
x.append('        if (!c) continue;')
x.append('        /* 只处理类名（第一个字符是字母且不含冒号），跳过 selector */')
x.append('        if (strchr(fake, 0x3A)) continue;')
x.append('        /* 去掉大写过滤 */')
x.append('        /* class_ro_t: flags(4) instanceStart(4) instanceSize(4) reserved(4) ivarLayout(8) name(8) */')
x.append('        uint64_t _bits = *(uint64_t *)((uint64_t)c + 32);  /* class_data_bits_t 在 +32 */')
x.append('        uint64_t ro = _bits & ~0xFULL;')
x.append('        if (!ro) continue;')
x.append('        const char **namep = (const char **)(ro + 24);')
x.append('        /* 真名拷贝到堆（映射表在 map 里，生命周期够长） */')
x.append('        char *realcopy = (char *)malloc(l + 1);')
x.append('        if (!realcopy) continue;')
x.append('        memcpy(realcopy, real, l); realcopy[l] = 0;')
x.append('        /* mprotect 该页为 RW */')
x.append('        uintptr_t page = (uintptr_t)namep & ~0xFFFULL;')
x.append('        if (mprotect((void *)page, 0x2000, PROT_READ|PROT_WRITE) == 0) {')
x.append('            *namep = realcopy;')
x.append('            mprotect((void *)page, 0x2000, PROT_READ);')
x.append('            fixed++;')
x.append('        }')
x.append('    }')
x.append('    free(map);')
x.append('    vmlog("[restore] %u classnames fixed", fixed);')
x.append('}')
x.append('#endif')
x.append('')
x.append('/* ===== 反调试扩展：P_TRACED / hook 检测 / 时钟校验 ===== */')
x.append('#import <sys/sysctl.h>')
x.append('#import <sys/time.h>')
x.append('#import <dlfcn.h>')
x.append('')
x.append('static int _ad_check_traced(void) {')
x.append('    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};')
x.append('    struct kinfo_proc info;')
x.append('    size_t size = sizeof(info);')
x.append('    memset(&info, 0, sizeof(info));')
x.append('    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return 0;')
x.append('    return (info.kp_proc.p_flag & P_TRACED) ? 1 : 0;')
x.append('}')
x.append('')
x.append('static int _ad_check_hook(void) {')
x.append('    /* ptrace 是否被 inline hook（首条指令被改成 b） */')
x.append('    void *p = dlsym(RTLD_DEFAULT, "ptrace");')
x.append('    if (!p) return 0;')
x.append('    unsigned int w = *(unsigned int *)p;')
x.append('    if ((w & 0xFC000000) == 0x14000000) return 1;   /* b xxx = 被 hook */')
x.append('    return 0;')
x.append('}')
x.append('')
x.append('static int _ad_check_clock(void) {')
x.append('    /* gettimeofday 与 mach_absolute_time 交叉校验（调试器会拉长） */')
x.append('    struct timeval t1, t2;')
x.append('    gettimeofday(&t1, NULL);')
x.append('    volatile unsigned long long n = 0;')
x.append('    for (unsigned long long i = 0; i < 200000ULL; i++) n += i;')
x.append('    gettimeofday(&t2, NULL);')
x.append('    long long us = (long long)(t2.tv_sec - t1.tv_sec) * 1000000LL + (t2.tv_usec - t1.tv_usec);')
x.append('    return (us > 5000000) ? 1 : 0;   /* 20 万次循环超 5 秒 = 被单步 */')
x.append('}')
x.append('')
x.append('static void antidebug_extra(void) {')
x.append('    int hit = 0;')
x.append('    hit |= _ad_check_traced();')
x.append('    hit |= _ad_check_hook();')
x.append('    hit |= _ad_check_clock();')
x.append('    if (hit) {')
x.append('        /* 静默退出（不写日志，不留痕） */')
x.append('        kill(getpid(), 9);')
x.append('    }')
x.append('}')
x.append('')
x.append('%ctor {')
x.append('    antidebug_extra();')
x.append('#ifdef INCLUDE_SEL_MAP')
x.append('    restore_classnames();')
x.append('#endif')
x.append('/* restore 已移除: tweak 内部自洽，改名后 hook 用假名即可 */')
x.append('    if (_vmp_inited) {')
x.append('        vmlog("==== VMP already inited, skip (second load) ====");')
x.append('        return;')
x.append('    }')
x.append('    _vmp_inited = 1;')
x.append('    vmlog("==== VMP multi-hook loaded (%d funcs) ====");' % len(results))
x.append('    Dl_info info;')
x.append('    /* ★ 安装崩溃兜底 + 独立信号栈 */')
x.append('    gcob_install_sigaltstack();')
x.append('    if (dladdr((void *)&hook_%s, &info)) {' % results[0][0])
x.append('        vmp_image_base = info.dli_fbase;')
x.append('        vmlog("[ctor] base=%%p (%%s)", info.dli_fbase, info.dli_fname ? info.dli_fname : "?");')
x.append('    }')
for name, addr, bc, raw_sym in results:
    if raw_sym.startswith("IMP:"):
        # 自动扩展：已经有了 IMP 地址，直接用 MSHookFunction 挂
        x.append('    addr_%s = (void *)%s;' % (name, raw_sym[4:]))
        x.append('    if (addr_%s) {' % name)
        x.append('        gcob_hook_armed = 1;')
        x.append('        if (sigsetjmp(gcob_hook_jb, 1) == 0) {')
        x.append('            DobbyHook(addr_%s, (void *)hook_%s, (void **)&orig_%s);' % (name, name, name))
        x.append('            gcob_hook_armed = 0; gcob_hook_ok++;')
        x.append('        } else {')
        x.append('            gcob_hook_armed = 0; gcob_hook_skip++;')
        x.append('        }')
        x.append('    }')
        x.append('    vmlog("[ctor] %s hooked(IMP) orig=%%p", orig_%s);' % (name, name))
        continue
    if raw_sym.startswith("__Z"):
        # C++ mangled：用 dlsym
        if raw_sym.startswith("IMP:"):
            x.append('    addr_%s = (void *)%s;   /* 自动扩展: 直接用 IMP 地址 */' % (name, raw_sym[4:]))
        elif raw_sym.startswith("0x"):
            x.append('    addr_%s = (void *)%s;' % (name, raw_sym))
        else:
            x.append('    addr_%s = dlsym(RTLD_DEFAULT, "%s");' % (name, raw_sym))
    else:
        # 纯 C 函数：直接取地址（最可靠）
        x.append('    addr_%s = (void *)&%s;' % (name, name))
    x.append('    vmlog("[ctor] %s = %%p", addr_%s);' % (name, name))
    #ifndef VMP_DISABLE_HOOKS
    x.append('    if (addr_%s) DobbyHook(addr_%s, (void *)hook_%s, (void **)&orig_%s);' % (name, name, name, name))
    #endif
    x.append('    vmlog("[ctor] %s hooked, orig=%%p", orig_%s);' % (name, name))
x.append('    vmlog("==== all hooked ====");')
x.append('}')

open(OUT_XM, "w").write("\n".join(x))
print("已写 %s" % OUT_XM)
print("\n共 %d 个函数" % len(results))

# ===== 生成抹除名单（候选 + 实际）=====
#   g_wipe_candidates.txt : 全部已虚拟化函数（addr size name），供人工挑选/分批
#   g_wipe_list.txt       : 按 WIPE_MODE 决定实际要抹的子集（喂给 gcobf-post.py wipe --list）
_full = scan_all_functions(raw)           # 全量函数入口（含边界，用于算 size）
_fs = sorted(set(_full))
_sz_map = {}
for _i, _a in enumerate(_fs):
    _nx = _fs[_i + 1] if _i + 1 < len(_fs) else _a + 0x40
    _sz_map[_a] = max(8, _nx - _a)
_OUT_DIR = os.path.dirname(OUT_XM)
_cand = []
_wipe = []
for name, addr, bc, raw_sym in results:
    sz = _sz_map.get(addr, len(bc))
    _cand.append("%x %d %s" % (addr, sz, name))
    if _wipe_decide(name, raw_sym):
        _wipe.append("%x %d closed" % (addr, sz))
open(os.path.join(_OUT_DIR, "g_wipe_candidates.txt"), "w").write("\n".join(_cand) + "\n")
open(os.path.join(_OUT_DIR, "g_wipe_list.txt"), "w").write("\n".join(_wipe) + "\n")
print("抹除: WIPE_MODE=%s  候选=%d  实际抹=%d  (名单: g_wipe_list.txt)" %
      (WIPE_MODE, len(_cand), len(_wipe)))
print("  → 后处理最后一步: python3 tools/gcobf-post.py wipe <final.dylib> --list <VMP目录>/g_wipe_list.txt")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gcobf-post.py - GCObf 二进制后处理与效果自检

用途:
  verify        混淆效果自检 (对应《混淆器诊断与改造方案》§6.1 的度量表)
  strip         抹掉 __TEXT,__text 里的 `mov x29, x29` (0xAA1D03FD) 标记
  write-crc     把 anti 函数的校验和写进 __gcob_crc (integ 用)
  hide-exports  导出符号改名 (等长原地替换 export trie + symtab, 不改结构)
  report        段表 / 符号 / 段大小概览

用法:
  ./gcobf-post.py verify app.dylib
  ./gcobf-post.py strip  app.dylib -o app.stripped.dylib
  ./gcobf-post.py report app.dylib

说明:
  * 只支持 64 位小端 Mach-O (arm64), 不支持 fat 包
  * strip 会改动 __text 内容 → 必须重新签名 (ldid -S / 巨魔重签)
  * 纯标准库, python3.6+ 即可, 可在越狱设备上直接跑
"""

import hashlib
import os
import re
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
MH_OBJECT, MH_EXECUTE, MH_DYLIB, MH_DYLINKER, MH_BUNDLE = 1, 2, 6, 7, 8
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_CHAINED_FIXUPS = 0x80000034

MOV_X29_X29 = 0xAA1D03FD
ARM64_NOP = 0xD503201F

FILETYPE_NAMES = {
    1: "MH_OBJECT (目标文件)",
    2: "MH_EXECUTE (可执行)",
    6: "MH_DYLIB (动态库)",
    7: "MH_DYLINKER",
    8: "MH_BUNDLE",
}


class MachO(object):
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.raw = bytearray(f.read())
        if len(self.raw) < 32:
            raise SystemExit("文件太小, 不是 Mach-O")
        magic = struct.unpack_from("<I", self.raw, 0)[0]
        if magic == MH_CIGAM_64:
            raise SystemExit("这是大端 Mach-O, 不支持")
        if magic != MH_MAGIC_64:
            if struct.unpack_from(">I", self.raw, 0)[0] == MH_MAGIC_64:
                raise SystemExit("这是大端 Mach-O, 不支持")
            raise SystemExit("不是 64 位 Mach-O (magic=0x%08X), fat 包请先 lipo -thin" % magic)
        (self.cputype, self.cpusubtype, self.filetype, self.ncmds,
         self.sizeofcmds, self.flags) = struct.unpack_from("<iiIIII", self.raw, 4)
        self.sections = []
        self.symtab = None
        self.export_trie = None      # (file_off, size)
        self.bind_ranges = []        # [(file_off, size)] bind / weak_bind / lazy_bind
        self.chained_fixups = None   # (file_off, size) LC_DYLD_CHAINED_FIXUPS
        self._parse_lc()

    def _parse_lc(self):
        off = 32
        for _ in range(self.ncmds):
            cmd, cmdsize = struct.unpack_from("<II", self.raw, off)
            if cmd == LC_SEGMENT_64:
                segname = self.raw[off + 8:off + 24].split(b"\0")[0].decode("latin-1")
                nsects = struct.unpack_from("<I", self.raw, off + 64)[0]
                soff = off + 72
                for _s in range(nsects):
                    sectname = self.raw[soff:soff + 16].split(b"\0")[0].decode("latin-1")
                    sseg = self.raw[soff + 16:soff + 32].split(b"\0")[0].decode("latin-1")
                    addr, size, offset = struct.unpack_from("<QQI", self.raw, soff + 32)
                    self.sections.append({
                        "seg": sseg, "name": sectname, "addr": addr,
                        "size": size, "offset": offset,
                    })
                    soff += 80
            elif cmd == LC_SYMTAB:
                symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", self.raw, off + 8)
                self.symtab = (symoff, nsyms, stroff, strsize)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                (r_off, r_sz, b_off, b_sz, wb_off, wb_sz,
                 lb_off, lb_sz, e_off, e_sz) = struct.unpack_from("<10I", self.raw, off + 8)
                if e_sz:
                    self.export_trie = (e_off, e_sz)
                for o, s in ((b_off, b_sz), (wb_off, wb_sz), (lb_off, lb_sz)):
                    if s:
                        self.bind_ranges.append((o, s))
            elif cmd == LC_DYLD_EXPORTS_TRIE:
                doff, dsize = struct.unpack_from("<II", self.raw, off + 8)
                self.export_trie = (doff, dsize)
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                doff, dsize = struct.unpack_from("<II", self.raw, off + 8)
                self.chained_fixups = (doff, dsize)
            off += cmdsize

    def section(self, name, seg=None):
        for s in self.sections:
            if s["name"] == name and (seg is None or s["seg"] == seg):
                return s
        return None

    def data(self, sec):
        return bytes(self.raw[sec["offset"]:sec["offset"] + sec["size"]])

    def exported_symbols(self):
        """返回 [(name, n_type)] , 只取 N_EXT 且有段/绝对地址的"""
        if not self.symtab:
            return []
        symoff, nsyms, stroff, strsize = self.symtab
        strtab = bytes(self.raw[stroff:stroff + strsize])
        out = []
        for i in range(nsyms):
            o = symoff + i * 16
            if o + 16 > len(self.raw):
                break
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", self.raw, o)
            if not (n_type & 0x01):        # N_EXT
                continue
            if (n_type & 0x0E) == 0:       # N_UNDF
                continue
            end = strtab.find(b"\0", n_strx)
            name = strtab[n_strx:end].decode("latin-1") if end > 0 else ""
            if name:
                out.append((name, n_type))
        return out


# ---------------- 导出符号隐藏 (链接后处理) ----------------
def _uleb(buf, p):
    v = 0
    shift = 0
    while True:
        b = buf[p]
        p += 1
        v |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return v, p


def _sleb(buf, p):
    v = 0
    shift = 0
    while True:
        b = buf[p]
        p += 1
        v |= (b & 0x7F) << shift
        shift += 7
        if not (b & 0x80):
            if b & 0x40:
                v -= (1 << shift)
            break
    return v, p


def parse_export_trie(data):
    """-> [(path, [(edge_off, edge_len)...], flags, addr)]"""
    out = []

    def walk(node, path, segs, depth):
        if depth > 48:
            return
        p = node
        term, p = _uleb(data, p)
        if term:
            end = p + term
            flags, q = _uleb(data, p)
            addr, q = _uleb(data, q)
            out.append((path, list(segs), flags, addr))
            p = end
        nchild = data[p]
        p += 1
        for _ in range(nchild):
            e = p
            while data[e] != 0:
                e += 1
            label = data[p:e].decode("latin-1")
            child, q = _uleb(data, e + 1)
            segs.append((p, e - p))
            walk(child, path + label, segs, depth + 1)
            segs.pop()
            p = q

    walk(0, "", [], 0)
    return out


def chained_import_names(raw, base, size):
    """解析 LC_DYLD_CHAINED_FIXUPS 的 imports 表, 拿到所有被绑定的符号名"""
    if not size:
        return set()
    d = raw[base:base + size]
    try:
        (ver, starts, imp_off, syms_off, count, fmt, symfmt) = struct.unpack_from("<7I", d, 0)
    except struct.error:
        return set()
    names = set()
    step = {1: 4, 2: 8, 3: 16}.get(fmt, 4)
    for i in range(count):
        o = imp_off + i * step
        if o + step > len(d):
            break
        if fmt == 3:
            v = struct.unpack_from("<Q", d, o)[0]
            noff = v >> 32
        else:
            v = struct.unpack_from("<I", d, o)[0]
            noff = v >> 9
        s = syms_off + noff
        if s >= len(d):
            continue
        e = d.find(b"\0", s)
        if e < 0:
            continue
        names.add(d[s:e].decode("latin-1"))
    return names


def bind_names(raw, ranges, chained=None):
    """收集 bind / lazy_bind / weak_bind / chained imports 里被引用的符号名"""
    names = set()
    if chained:
        names |= chained_import_names(raw, chained[0], chained[1])
    for off, size in ranges:
        p = off
        end = min(off + size, len(raw))
        while p < end:
            b = raw[p]
            p += 1
            op = b & 0xF0
            if op == 0x40:      # SET_SYMBOL_TRAILING_FLAGS_IMM
                e = p
                while raw[e] != 0:
                    e += 1
                names.add(raw[p:e].decode("latin-1"))
                p = e + 1
            elif op == 0x20:    # SET_DYLIB_ORDINAL_ULEB
                _, p = _uleb(raw, p)
            elif op == 0x60:    # SET_ADDEND_SLEB
                _, p = _sleb(raw, p)
            elif op == 0x70:    # SET_SEGMENT_AND_OFFSET_ULEB
                _, p = _uleb(raw, p)
            elif op == 0x80:    # ADD_ADDR_ULEB
                _, p = _uleb(raw, p)
            elif op == 0xA0:    # DO_BIND_ADD_ADDR_ULEB
                _, p = _uleb(raw, p)
            elif op == 0xC0:    # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                _, p = _uleb(raw, p)
                _, p = _uleb(raw, p)
            elif op == 0x00:    # DONE
                break
    return names


def _rand_bytes(n):
    """生成 n 个十六进制字符 (等长替换用)"""
    h = hashlib.sha256(os.urandom(16)).hexdigest()
    while len(h) < n:
        h += hashlib.sha256(h.encode()).hexdigest()
    return h[:n].encode("latin-1")


def _new_name(old, used):
    """生成长度完全一致的新符号名 (trie 原地替换, 不改任何偏移)"""
    if len(old) < 3:
        return None
    n = len(old)
    for i in range(64):
        h = hashlib.sha256(("%s|%d|%d" % (old, n, i)).encode()).hexdigest()
        cand = "_g" + h
        while len(cand) < n:          # 关键: 必须严格等长, 否则会改变段长度
            cand += h
        cand = cand[:n]
        if cand not in used:
            used.add(cand)
            return cand
    return None


def cmd_hide_exports(path, out_path):
    m = MachO(path)
    if not m.export_trie:
        raise SystemExit("没有 export trie (不是 dylib/可执行?)")
    if not m.symtab:
        raise SystemExit("没有 LC_SYMTAB")

    eoff, esize = m.export_trie
    trie = bytearray(m.raw[eoff:eoff + esize])
    items = parse_export_trie(bytes(trie))
    bound = bind_names(bytes(m.raw), m.bind_ranges, m.chained_fixups)

    keep = ("main", "_InitFunc", "___gcob_", "__gcob_")   # __gcob_* 是插件的锚点符号, 后处理要用
    used = set()
    mapping = []
    skipped = 0
    for name, segs, flags, addr in items:
        if not name:
            continue
        if name in bound or name.startswith(keep):
            skipped += 1
            continue
        nn = _new_name(name, used)
        if not nn:
            continue
        pos = 0
        for soff, slen in segs:
            for k in range(slen):
                if pos < len(nn):
                    trie[soff + k] = ord(nn[pos])
                pos += 1
        mapping.append((name, nn))

    if not mapping:
        print("[!] 没有可改名的导出符号 (全部被 bind 引用或已处理)")
        return 0

    symoff, nsyms, stroff, strsize = m.symtab
    strtab = m.raw[stroff:stroff + strsize]
    for old, new in mapping:
        pat = old.encode("latin-1") + b"\0"
        idx = 0
        while True:
            k = strtab.find(pat, idx)
            if k < 0:
                break
            strtab[k:k + len(old)] = new.encode("latin-1")
            idx = k + len(pat)
    m.raw[stroff:stroff + strsize] = strtab
    m.raw[eoff:eoff + esize] = trie

    # 清掉改名符号的 N_EXT 位 → nm -g / rabin2 -E 直接归零
    # (dyld 的导出由 export trie 决定, 与 nlist 的 N_EXT 无关, 不影响加载)
    renamed_set = set(n for _o, n in mapping)
    cleared = 0
    for i in range(nsyms):
        o = symoff + i * 16
        if o + 16 > len(m.raw):
            break
        n_strx, n_type = struct.unpack_from("<IB", m.raw, o)
        if not (n_type & 0x01):
            continue
        e = strtab.find(b"\0", n_strx)
        if e < 0:
            continue
        nm = bytes(strtab[n_strx:e]).decode("latin-1")
        if nm in renamed_set:
            struct.pack_into("<B", m.raw, o + 4, n_type & 0xFE)
            cleared += 1

    if out_path is None:
        bak = path + ".bak"
        if not os.path.exists(bak):
            with open(bak, "wb") as f:
                f.write(open(path, "rb").read())
            print("[*] 已备份: %s" % bak)
        out_path = path
    with open(out_path, "wb") as f:
        f.write(m.raw)

    print("[+] 改名 %d 个导出符号 (保留 %d 个被绑定/受保护的)" % (len(mapping), skipped))
    for old, new in mapping[:8]:
        print("      %-36s -> %s" % (old, new))
    if len(mapping) > 8:
        print("      ... 共 %d 条" % len(mapping))
    print("[+] 输出: %s" % out_path)
    print("[!] 请重新签名: ldid -S \"%s\"" % out_path)

    return 0


# ---------------- selector 改名 (链接后处理) ----------------
# 系统回调/协议方法白名单: 这些名字必须保留, 否则系统按名字找不到实现
SYS_EXACT = set("""
dealloc load initialize new alloc copy mutableCopy
description debugDescription hash isEqual: isKindOfClass: isMemberOfClass:
respondsToSelector: conformsToProtocol: performSelector: performSelector:withObject:
methodSignatureForSelector: forwardInvocation: forwardingTargetForSelector:
valueForKey: setValue:forKey: observeValueForKeyPath:ofObject:change:context:
encodeWithCoder: initWithCoder: copyWithZone: mutableCopyWithZone: zone retain release autorelease retainCount
layoutSubviews layoutIfNeeded setNeedsLayout drawRect: didMoveToWindow didMoveToSuperview
willMoveToSuperview: setFrame: setBounds: setCenter: setHidden: setAlpha: setBackgroundColor:
tintColorDidChange sizeThatFits: intrinsicContentSize updateConstraints safeAreaInsetsDidChange
traitCollectionDidChange: touchesBegan:withEvent: touchesMoved:withEvent: touchesEnded:withEvent:
touchesCancelled: hitTest:withEvent: pointInside:withEvent: canBecomeFirstResponder
becomeFirstResponder resignFirstResponder viewDidLoad viewWillAppear: viewDidAppear:
viewWillDisappear: viewDidDisappear: loadView viewWillLayoutSubviews viewDidLayoutSubviews
drawInMTKView: mtkView:drawableSizeWillChange: layoutSublayersOfLayer:
actionForLayer:forKey: displayLayer: drawLayer:inContext: layerWillDraw:
class superclass window methodForSelector: methodSignatureForSelector:
selectRowAtIndexPath:animated:scrollPosition: moveRowAtIndexPath:toIndexPath:
.cxx_destruct .cxx_construct layoutSubviews layoutIfNeeded layoutSublayersOfLayer:
movedToWindow moveFromIndex:toIndex: setNeedsDisplay setNeedsLayout
""".split())

# 以这些前缀开头的一律保留 (系统回调 + setter/getter + 常见框架约定)
SYS_PREFIX = (
    "init", "set", ".", "copy", "mutableCopy", "encode", "decode",
    "is", "has", "should", "will", "did", "can", "may",
    "accessibility", "touches", "draw", "view", "application", "scene",
    "scroll", "table", "collection", "text", "gesture", "animate",
    "target", "action", "responds", "perform", "forward",
    "retain", "release", "autorelease", "observe", "validate",
    "update", "prepare", "begin", "end", "insert", "delete", "reload",
    "present", "dismiss", "add", "remove",
    "numberOf", "cellFor", "heightFor", "widthFor", "sizeFor", "shouldShow",
    "supportedInterface", "preferredStatus", "childView", "parentView",
)


_SYS_TABLE = None


def load_sys_table():
    """加载系统 selector 白名单 (从 dyld shared cache 提取)

    查找顺序:
      1. 环境变量 GCOBF_SYS_TABLE 指定的文件
      2. 工具同目录 / 上级目录的 sys_selectors.txt
    找不到就退回内置的规则表 (SYS_EXACT + SYS_PREFIX)。
    """
    global _SYS_TABLE
    if _SYS_TABLE is not None:
        return _SYS_TABLE
    cands = []
    env = os.environ.get("GCOBF_SYS_TABLE")
    if env:
        cands.append(env)
    here = os.path.dirname(os.path.abspath(__file__))
    cands.append(os.path.join(here, "sys_selectors.txt"))
    cands.append(os.path.join(os.path.dirname(here), "sys_selectors.txt"))
    for path in cands:
        if path and os.path.exists(path):
            with open(path, "r", errors="ignore") as f:
                _SYS_TABLE = set(x.strip() for x in f if x.strip())
            print("[i] 系统 selector 表: %s (%d 条)" % (path, len(_SYS_TABLE)))
            return _SYS_TABLE
    _SYS_TABLE = set()
    return _SYS_TABLE


# ---- 运行时生命周期方法（改名会让 [super init] / NSObject 协议失效）----
LIFECYCLE = {
    "init", "dealloc", "load", "initialize",
    "alloc", "new", "copy", "mutableCopy", "copyWithZone:",
    "class", "self", "superclass", "description", "debugDescription",
    "hash", "isEqual:", "isKindOfClass:", "isMemberOfClass:",
    "respondsToSelector:", "conformsToProtocol:",
    "retain", "release", "autorelease", "retainCount",
    "forwardInvocation:", "methodSignatureForSelector:",
    "doesNotRecognizeSelector:", "zone",
    ".cxx_destruct", ".cxx_construct",
}


def is_system_selector(name):
    # 无论有没有表, 这几类都必须保留
    if name in SYS_EXACT:
        return True
    if name.startswith(".cxx_") or name.startswith(".objc_"):
        return True
    # ivar 名 (_camelCase): 极短的 (_sw/_on/_btn) 保留, 长的和含中文的一律改
    if name.startswith("_") and name.count("_") == 1 and ":" not in name:
        try:
            name.encode("ascii")
            return len(name) <= 8
        except UnicodeEncodeError:
            return False
    table = load_sys_table()
    if table:
        # 精确匹配: shared cache 里有 = 系统里已存在的方法/类名/C 符号, 一律保留
        return name in table
    # 没有表时退回规则判断
    if name in SYS_EXACT:
        return True
    for p in SYS_PREFIX:
        if name.startswith(p):
            return True
    return False


def own_selectors(m, path):
    """从 __objc_classlist 提取「本 dylib 自己实现」的 selector 名。

    这是关键区分:
      - 自己实现的方法 -> 名字由我们决定, 可以改
      - 只调用不实现的方法 -> 名字是别人(系统/其它库)定的, 改了就会
        unrecognized selector
    """
    try:
        import subprocess
        out = subprocess.run(["otool", "-ov", path], capture_output=True, text=True).stdout
    except Exception:
        return None
    raw = m.raw
    own = set()
    for line in out.split("\n"):
        st = line.strip()
        if not st.startswith("name ") or "(" not in st:
            continue
        try:
            a = int(st.split("(")[-1].rstrip(")"), 16)
            ptr = struct.unpack_from("<Q", raw, a)[0]
            off = ptr & 0xFFFFFFFFF
            if off >= len(raw):
                continue
            e = raw.find(b"\0", off)
            nm = bytes(raw[off:e]).decode("latin-1")
            if nm and all(32 <= ord(c) < 127 for c in nm):
                own.add(nm)
        except Exception:
            pass
    return own or None


def cmd_rename_selectors(path, out_path, save_map=None, keep_classnames=False,
                         skip_selrefs=False, force_classes=False,
                         only_set=None, exclude_set=None):
    """only_set 非空 = 定向模式：只改这些 selector（已人工确认安全），
       其余一律不动；exclude_set 里的即使在 only_set 也不改。"""
    m = MachO(path)
    sec = m.section("__objc_methname", "__TEXT")
    if not sec:
        raise SystemExit("找不到 __TEXT,__objc_methname")
    base, size = sec["offset"], sec["size"]
    data = bytes(m.raw[base:base + size])
    out = bytearray(data)

    _orig_len = len(m.raw)
    own = own_selectors(m, path)

    # ---- 被 __objc_selrefs 引用的 selector 不能改名 ----
    #   selref 是运行时 objc_msgSend 用的, 指向 __objc_methname 的同一批字符串
    #   改名后系统类找不到方法 -> doesNotRecognizeSelector -> 崩
    selref_names = set()
    if skip_selrefs:
        sref = m.section("__objc_selrefs")   # 在 __DATA 段
        mnh = m.section("__objc_methname", "__TEXT")
        if sref and mnh:
            so, ss = sref["offset"], sref["size"]
            mo, mv = mnh["offset"], mnh["addr"]
            for k in range(0, ss, 8):
                v = struct.unpack_from("<Q", m.raw, so + k)[0] & 0xFFFFFFFF
                if v >= mv and v < mv + mnh["size"]:
                    o = mo + (v - mv)
                    e = m.raw.find(b"\0", o)
                    if e > o:
                        selref_names.add(bytes(m.raw[o:e]).decode("latin-1"))
        print("[i] selrefs 引用的 selector: %d 个（不改名）" % len(selref_names))
    if own:
        print("[i] 本 dylib 自己实现的 selector: %d 个" % len(own))
    mapping = {}          # 原名 -> 新名 (同名必须一起改, 保持 dispatch 一致)
    used = set()
    renamed = kept_sys = kept_attr = attr_var = kept_ext = 0
    ivar_renamed = 0

    pos = 0
    L = len(data)
    while pos < L:
        end = data.find(b"\0", pos)
        if end < 0:
            end = L
        raw = data[pos:end]
        if len(raw) >= 2:
            name = raw.decode("latin-1")
            if only_set is not None:
                # ★ 定向模式：只改 only_set、且不在 exclude_set 的 selector；其余全部跳过
                if name in only_set and (not exclude_set or name not in exclude_set):
                    new = mapping.get(name)
                    if new is None:
                        new = _new_name(name, used)
                        if new:
                            mapping[name] = new
                    if new is not None:
                        assert len(new) == len(name), "长度不一致 %r" % name
                        out[pos:pos + len(name)] = new.encode("latin-1")
                        renamed += 1
                pos = end + 1
                continue
            if "," in name or name.startswith("T@") or name.startswith("T{"):
                kept_attr += 1                      # property attribute, 不是 selector
                # V_ 后面是 ivar 名字(可能带中文), @"Xxx" 是属性类型类名, 都等长抹掉
                seg = name
                k = seg.rfind(",V")
                if k >= 0:
                    tail = seg[k + 2:]
                    # V_ 后面是 ivar 名字，KVC/属性运行时按它查找，
                    # 改了会导致 setValue:forKey: 找不到 -> SIGABRT。保持原样。
                    if False and tail and not tail.startswith("_g"):
                        seg = seg[:k + 2] + _rand_bytes(len(tail)).decode("latin-1")
                        attr_var += 1
                # 不能改 @"ClassName" 里的类名！
                # 这是 property 的类型编码，运行时 ObjC 会按它查找类。
                # 改掉 -> 找不到类 -> NSException -> SIGABRT（稳定复现，无崩溃报告）
                seg2 = seg
                if seg2 != name:
                    assert len(seg2) == len(name), "attribute 长度变了"
                    out[pos:pos + len(name)] = seg2.encode("latin-1")
            elif name.startswith("_") and not name.startswith("__") and len(name) >= 3 \
                 and ":" not in name and not name.startswith("_g"):
                # ivar 名（_config / _kKey / _secret）—— 与 selector 共用 methname 段
                new = mapping.get(name)
                if new is None:
                    new = _new_name(name, used)
                    if new:
                        mapping[name] = new
                if new is None:
                    kept_ext += 1
                else:
                    assert len(new) == len(name), "ivar 长度不一致 %r" % name
                    out[pos:pos + len(name)] = new.encode("latin-1")
                    renamed += 1
                    ivar_renamed += 1
            elif is_system_selector(name):
                kept_sys += 1
            elif own is not None and name not in own:
                kept_ext += 1                       # 外部方法, 名字不是我们定的
            elif selref_names and name in selref_names:
                kept_ext += 1                       # 被 selref 引用, 不改（否则 objc_msgSend 崩）
            else:
                new = mapping.get(name)
                if new is None:
                    new = _new_name(name, used)
                    if new:
                        mapping[name] = new
                if new is None:
                    kept_sys += 1
                else:
                    assert len(new) == len(name), "长度不一致 %r" % name
                    out[pos:pos + len(name)] = new.encode("latin-1")
                    renamed += 1
        pos = end + 1

    if not mapping:
        print("[!] 没有可改名的 selector")
        return 0

    assert len(out) == size, "methname 段长度变了 %d != %d" % (len(out), size)
    m.raw[base:base + size] = out
    assert len(m.raw) == _orig_len, "methname 写入后文件长度变了"

    # ---- 类名 (__objc_classname): 不在系统表里的也一起长改 ----
    #   注意: 类名改名后 objc_getClass/NSClassFromString 用原名会失败,
    #   而类名还原需要 hack runtime 结构(危险), 所以默认保留类名(--keep-classnames)
    cls_sec = m.section("__objc_classname", "__TEXT")
    cls_renamed = 0
    if cls_sec and only_set is None and (force_classes or not keep_classnames):
        cb, cs = cls_sec["offset"], cls_sec["size"]
        cdata = bytes(m.raw[cb:cb + cs])
        cout = bytearray(cdata)
        cmap = {}
        cpos = 0
        while cpos < cs:
            e = cdata.find(b"\0", cpos)
            if e < 0:
                e = cs
            raw = cdata[cpos:e]
            if len(raw) >= 3:
                nm = raw.decode("latin-1")
                if not is_system_selector(nm):
                    nn = cmap.get(nm)
                    if nn is None:
                        nn = _new_name(nm, used)
                        if nn:
                            cmap[nm] = nn
                    if nn:
                        assert len(nn) == len(nm)
                        cout[cpos:cpos + len(nm)] = nn.encode("latin-1")
                        cls_renamed += 1
            cpos = e + 1
        if cmap:
            assert len(cout) == cs, "classname 长度变了"
            m.raw[cb:cb + cs] = cout
            assert len(m.raw) == _orig_len, "classname 写入后长度变了"

    # ---- 类型编码里的结构体字段名 ----
    # {"showLoot"B"showCoffin"B"showMonster"...} 会直接把功能清单列出来
    mt_renamed = 0
    mt = m.section("__objc_methtype", "__TEXT")
    if mt:
        mb, ms = mt["offset"], mt["size"]
        md = bytes(m.raw[mb:mb + ms])
        mout = bytearray(md)
        for mm in re.finditer(rb'"([^"]{1,64})"', md):
            g = mm.group(1)
            mout[mm.start(1):mm.end(1)] = _rand_bytes(len(g))
            mt_renamed += 1
        for mm in re.finditer(rb'\{([A-Za-z_][A-Za-z0-9_]{1,40})=', md):
            g = mm.group(1)
            mout[mm.start(1):mm.end(1)] = _rand_bytes(len(g))
        assert len(mout) == ms
        m.raw[mb:mb + ms] = mout
        assert len(m.raw) == _orig_len, "methtype 写入后长度变了"

    # ---- 符号表里的局部符号名 (strip 后仍保留, _OBJC_CLASS_$_Xxx 会泄露类名) ----
    n_local = 0
    if m.symtab:
        symoff, nsyms, stroff, strsize = m.symtab
        st = m.raw[stroff:stroff + strsize]
        for i in range(nsyms):
            o = symoff + i * 16
            if o + 16 > len(m.raw):
                break
            n_strx, n_type = struct.unpack_from("<IB", m.raw, o)
            if (n_type & 0x01) or n_strx == 0:      # 全局符号已由 hide-exports 处理
                continue
            e = st.find(b"\0", n_strx)
            if e < 0:
                continue
            nm = bytes(st[n_strx:e]).decode("latin-1")
            if len(nm) < 3 or nm.startswith("_g") or nm.startswith("__gcob_"):
                continue
            new = _new_name(nm, used)
            if new and len(new) == len(nm):
                st[n_strx:e] = new.encode("latin-1")
                n_local += 1
        assert len(st) == strsize, "strtab 长度变了 %d != %d" % (len(st), strsize)
        m.raw[stroff:stroff + strsize] = st
        assert len(m.raw) == _orig_len, "strtab 写入后长度变了"

    if out_path is None:
        bak = path + ".bak"
        if not os.path.exists(bak):
            with open(bak, "wb") as f:
                f.write(open(path, "rb").read())
            print("[*] 已备份: %s" % bak)
        out_path = path
    with open(out_path, "wb") as f:
        f.write(m.raw)

    print("[+] ObjC selector: 改名 %d 处 / %d 个唯一名, 保留系统回调 %d, 外部方法 %d, 属性串 %d (ivar 名抹除 %d, ivar 名混淆 %d)"
          % (renamed, len(mapping), kept_sys, kept_ext, kept_attr, attr_var, ivar_renamed))

    # ---- 输出映射表（XOR 加密 C 数组，供运行时 +load 还原）----
    if save_map:
        allmap = {}
        allmap.update(mapping)          # 方法名: 原名->假名
        if 'cmap' in locals() and cmap:
            allmap.update(cmap)         # 类名
        blob = struct.pack("<I", len(allmap))
        for real, fake in sorted(allmap.items()):
            r = real.encode("latin-1"); f = fake.encode("latin-1")
            blob += struct.pack("<H", len(r)) + r + f
        enc = bytes(b ^ 0x5A for b in blob)
        lines = []
        for i in range(0, len(enc), 12):
            lines.append("    " + ", ".join("0x%02x" % b for b in enc[i:i+12]) + ",")
        h = ("// sel_map.h - auto-generated: fake->real map (XOR 0x5A)\n"
             "// format: [u32 count][u16 len][real][fake]...\n"
             "static const unsigned char _sel_map[] = {\n%s\n};\n"
             "static const unsigned int _sel_map_len = %d;\n"
             % ("\n".join(lines), len(enc)))
        open(save_map, "w").write(h)
        print("[+] map %d entries -> %s (%d bytes enc)" % (len(allmap), save_map, len(enc)))
    if cls_renamed:
        print("[+] ObjC 类名: 改名 %d 个 (剩余为系统类)" % cls_renamed)
    for k, v in list(mapping.items())[:8]:
        print("      %-34s -> %s" % (k, v))
    if len(mapping) > 8:
        print("      ... 共 %d 个" % len(mapping))
    print("[+] 输出: %s" % out_path)
    print("[!] 请重新签名: ldid -S \"%s\"" % out_path)
    return 0


def _sym_addr(m, name):
    """按名字找符号的 n_value (vmaddr)"""
    if not m.symtab:
        return None
    symoff, nsyms, stroff, strsize = m.symtab
    st = bytes(m.raw[stroff:stroff + strsize])
    for i in range(nsyms):
        o = symoff + i * 16
        if o + 16 > len(m.raw):
            break
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", m.raw, o)
        if n_strx == 0 or (n_type & 0x0E) == 0:
            continue
        e = st.find(b"\0", n_strx)
        if e < 0:
            continue
        nm = st[n_strx:e].decode("latin-1")
        if nm == name or nm == "_" + name:
            return n_value
    return None


def _vm2file(m, addr):
    for s in m.sections:
        if s["addr"] and s["addr"] <= addr < s["addr"] + s["size"]:
            return s["offset"] + (addr - s["addr"])
    return None


def cmd_write_crc(path, out_path):
    """把 anti 函数 256 字节的校验和写进 __gcob_crc

    必须在 strip 之后、rename-selectors 之前跑。
    """
    m = MachO(path)
    p = _sym_addr(m, "__gcob_anti_ptr")
    c = _sym_addr(m, "__gcob_crc")
    if p is None or c is None:
        raise SystemExit("找不到 __gcob_anti_ptr / __gcob_crc (没开 anti/integ?)")
    po = _vm2file(m, p)
    co = _vm2file(m, c)
    if po is None or co is None:
        raise SystemExit("符号地址映射失败")
    # 全局里存的是 anti 函数地址 (chained fixup 编码, 取低 36 位)
    rawptr = struct.unpack_from("<Q", m.raw, po)[0]
    fn = rawptr & 0xFFFFFFFFF
    fo = _vm2file(m, fn)
    if fo is None:
        raise SystemExit("anti 函数地址 0x%x 映射失败" % fn)
    s = 0
    for i in range(64):
        s = (s + struct.unpack_from("<I", m.raw, fo + i * 4)[0]) & 0xFFFFFFFF
    struct.pack_into("<I", m.raw, co, s)

    if out_path is None:
        out_path = path
        bak = path + ".bak"
        if not os.path.exists(bak):
            with open(bak, "wb") as f:
                f.write(open(path, "rb").read())
    with open(out_path, "wb") as f:
        f.write(m.raw)
    print("[+] crc: anti@0x%x 计算 %08x -> 写入 __gcob_crc@0x%x" % (fn, s, c))
    print("[!] 请重新签名: ldid -S \"%s\"" % out_path)
    return 0


# ---------------- 度量 ----------------
def cjk_runs(data, min_len=2, filter_ascii=True):
    """UTF-16LE 中文字符连续段

    filter_ascii=True 时排除「ASCII 字节对伪装成 CJK」的情况 (全文件扫描用);
    扫 __ustring 段时应关掉, 否则会漏掉 全/密 这类低位字节恰好可打印的汉字。
    """
    runs = []
    cur = []
    for i in range(0, len(data) - 1, 2):
        u = data[i] | (data[i + 1] << 8)
        real = 0x4E00 <= u <= 0x9FFF and (not filter_ascii or not (0x20 <= (u & 0xFF) <= 0x7E))
        if real:
            cur.append(chr(u))
        else:
            if len(cur) >= min_len:
                runs.append("".join(cur))
            cur = []
    if len(cur) >= min_len:
        runs.append("".join(cur))
    return runs


def count_ascii_strings(data, minlen=8):
    n = 0
    run = 0
    for b in data:
        if 0x20 <= b <= 0x7E:
            run += 1
        else:
            if run >= minlen:
                n += 1
            run = 0
    if run >= minlen:
        n += 1
    return n


def count_cstrings(data):
    """统计 NUL 分隔的可见串条数 (ObjC 元数据段用)"""
    n = 0
    i = 0
    L = len(data)
    while i < L:
        end = data.find(b"\0", i)
        if end < 0:
            end = L
        chunk = data[i:end]
        if len(chunk) >= 2 and all(0x21 <= c <= 0x7E for c in chunk):
            n += 1
        i = end + 1
    return n


def count_markers(m):
    sec = m.section("__text", "__TEXT")
    if not sec:
        return 0
    data = m.data(sec)
    n = 0
    for i in range(0, len(data) - 3, 4):
        if struct.unpack_from("<I", data, i)[0] == MOV_X29_X29:
            n += 1
    return n


def cmd_verify(path, strict=False):
    m = MachO(path)
    print("=" * 62)
    print("  GCObf 混淆效果自检: %s" % os.path.basename(path))
    print("  类型: %s" % FILETYPE_NAMES.get(m.filetype, m.filetype))
    print("=" * 62)

    problems = 0

    # 1) __ustring (中文 UI 文案)
    us = m.section("__ustring", "__TEXT")
    if us:
        runs = cjk_runs(m.data(us), min_len=2, filter_ascii=False)
        print("[1] __TEXT,__ustring  存在, %d 字节, 中文段 %d 条  ❌ 明文中文" %
              (us["size"], len(runs)))
        for r in runs[:10]:
            print("      - %s" % r)
        if len(runs) > 10:
            print("      ... 共 %d 条" % len(runs))
        problems += 1
    else:
        print("[1] __TEXT,__ustring  不存在 (已加密到 __data / 或本就没有中文串)  ✅")

    # 2) 全文件中文残留 (参考值)
    all_runs = cjk_runs(bytes(m.raw), min_len=4)
    print("[2] 全文件中文段 (>=4 字, 仅供参考): %d 条" % len(all_runs))
    for r in all_runs[:5]:
        print("      - %s" % r)

    # 3) ObjC 方法名 / 类名 / 类型编码
    for label, sect in (("方法名", "__objc_methname"),
                        ("类名  ", "__objc_classname"),
                        ("类型编码", "__objc_methtype")):
        s = m.section(sect)
        if s:
            cnt = count_cstrings(m.data(s))
            print("[3] %-16s %6d 字节 / %4d 条  (明文, 静态可见)" % (sect, s["size"], cnt))

    # 4) 导出符号 (ObjC 类符号必须保留, 单独统计)
    exps = m.exported_symbols()
    objc_exps = [n for n, _t in exps if n.startswith("_OBJC_")]
    other = [n for n, _t in exps if not n.startswith("_OBJC_")]
    bad = len(other) > 10
    print("[4] 导出符号: 共 %d 个 (ObjC 类 %d, 其它 %d)%s" %
          (len(exps), len(objc_exps), len(other), "  ❌" if bad else "  ✅"))
    for nm in other[:8]:
        print("      - %s" % nm)
    if len(other) > 8:
        print("      ... 共 %d 个" % len(other))
    if bad:
        problems += 1

    # 5) mov x29,x29
    mk = count_markers(m)
    print("[5] __text 中 mov x29,x29: %d 处%s" % (mk, "  ❌ (IDA 靠它识别 objc_msgSend)" if mk else "  ✅"))
    if mk:
        problems += 1

    # 6) 可读 ASCII 串
    n_str = count_ascii_strings(bytes(m.raw), 8)
    print("[6] 可读 ASCII 串 (>=8 字符): %d 条" % n_str)

    # 7) 段表
    print("[7] 段: " + ", ".join(sorted({s["seg"] + "," + s["name"] for s in m.sections})))
    print("-" * 62)
    if problems:
        print("结论: 仍有 %d 类可静态识别的问题 (见 ❌)" % problems)
    else:
        print("结论: 未发现明显的静态可识别特征 ✅")
    return 0 if (not strict or problems == 0) else 1


def cmd_strip(path, out_path):
    m = MachO(path)
    sec = m.section("__text", "__TEXT")
    if not sec:
        raise SystemExit("找不到 __TEXT,__text")
    start, size = sec["offset"], sec["size"]
    n = 0
    for i in range(start, start + size - 3, 4):
        if struct.unpack_from("<I", m.raw, i)[0] == MOV_X29_X29:
            struct.pack_into("<I", m.raw, i, ARM64_NOP)
            n += 1
    if out_path is None:
        bak = path + ".bak"
        if not os.path.exists(bak):
            with open(bak, "wb") as f:
                f.write(open(path, "rb").read())
            print("[*] 已备份: %s" % bak)
        out_path = path
    with open(out_path, "wb") as f:
        f.write(m.raw)
    print("[+] 抹掉 %d 处 mov x29,x29 -> nop" % n)
    print("[+] 输出: %s" % out_path)
    print("[!] 二进制已改动, 请重新签名: ldid -S %s" % out_path)
    return 0


ARM64_MOV_X0_0 = 0xD2800000   # mov x0, #0
ARM64_RET      = 0xD65F03C0   # ret


def cmd_wipe(path, out_path, list_path, entry_keep=4, fill="nop", dry_run=False):
    """静态抹除：把「已虚拟化且安全」的函数体改成桩，使静态/ dump 看不到原逻辑。

    名单文件每行：  <addr_hex> <size_dec> [mode]
      addr = 函数相对 image base 的 vmaddr（= LC_FUNCTION_STARTS 的值）
      size = 函数字节大小
      mode = closed(默认，命门/普通均 fail-closed) —— 仅作标注，抹法相同

    桩布局：入口保留 entry_keep 条安全指令 `mov x0,#0; ret`（供 Dobby 安全重定位 hook），
    其余填充（nop / junk）。被抹函数若未被 hook 命中则返回 0（fail-closed）。
    ⚠️ 必须在 gen_multi_hooks 选定虚拟化名单之后执行，且名单须排除 init/单例/+load/早期路径。
    """
    m = MachO(path)
    sec = m.section("__text", "__TEXT")
    if not sec:
        raise SystemExit("找不到 __TEXT,__text")
    taddr, toff, tsize = sec["addr"], sec["offset"], sec["size"]
    entries = []
    for ln in open(list_path, encoding="utf-8"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        p = ln.split()
        a = int(p[0], 16); sz = int(p[1]); md = p[2] if len(p) > 2 else "closed"
        entries.append((a, sz, md))
    import random as _r
    done = skip = 0
    if dry_run:
        print("[dry-run] 只校验名单，不改二进制：")
        bad = 0
        for a, sz, md in entries:
            ok = (taddr <= a < taddr + tsize) and sz >= 8 and (a + sz) <= (taddr + tsize)
            w0 = struct.unpack_from("<I", m.raw, toff + (a - taddr))[0] if ok else 0
            if not ok:
                bad += 1
                print("  ✗ addr=0x%x size=%d  越界/过小，会被跳过" % (a, sz))
            else:
                print("  ✓ addr=0x%x size=%d  首指令=0x%08x → 将抹成 mov x0,#0;ret;…" % (a, sz, w0))
        print("[dry-run] 可抹 %d，跳过 %d（名单共 %d）" % (len(entries) - bad, bad, len(entries)))
        return 0
    for a, sz, md in entries:
        if not (taddr <= a < taddr + tsize):
            skip += 1; continue
        if sz < 8 or (a + sz) > (taddr + tsize):
            skip += 1; continue
        foff = toff + (a - taddr)
        # 入口安全桩: mov x0,#0 ; ret （非 PC 相对，Dobby 可安全重定位）
        struct.pack_into("<I", m.raw, foff, ARM64_MOV_X0_0)
        struct.pack_into("<I", m.raw, foff + 4, ARM64_RET)
        # 其余填充
        i = foff + 8
        end = foff + sz
        while i + 4 <= end:
            if fill == "junk":
                struct.pack_into("<I", m.raw, i, _r.getrandbits(32))
            else:
                struct.pack_into("<I", m.raw, i, ARM64_NOP)
            i += 4
        done += 1
    if out_path is None:
        bak = path + ".bak"
        if not os.path.exists(bak):
            open(bak, "wb").write(open(path, "rb").read())
            print("[*] 已备份: %s" % bak)
        out_path = path
    open(out_path, "wb").write(m.raw)
    print("[+] 抹除 %d 个函数体 (跳过 %d)，填充=%s" % (done, skip, fill))
    print("[+] 输出: %s" % out_path)
    print("[!] 已改 __text，请重签: ldid -S %s" % out_path)
    return 0


def cmd_report(path):
    m = MachO(path)
    print("%s  (%s)" % (os.path.basename(path), FILETYPE_NAMES.get(m.filetype, m.filetype)))
    print("%-12s %-24s %10s %10s" % ("segment", "section", "size", "fileoff"))
    total = 0
    for s in m.sections:
        print("%-12s %-24s %10d 0x%08X" % (s["seg"], s["name"], s["size"], s["offset"]))
        total += s["size"]
    print("-" * 60)
    print("段内容合计 %d 字节 / 文件 %d 字节" % (total, len(m.raw)))
    exps = m.exported_symbols()
    print("导出符号 %d 个" % len(exps))
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd = argv[1]
    path = argv[2]
    if not os.path.exists(path):
        raise SystemExit("找不到文件: %s" % path)
    if cmd == "verify":
        return cmd_verify(path, strict=("--strict" in argv))
    if cmd == "strip":
        out = None
        if "-o" in argv:
            out = argv[argv.index("-o") + 1]
        return cmd_strip(path, out)
    if cmd == "report":
        return cmd_report(path)
    if cmd == "hide-exports":
        out = None
        if "-o" in argv:
            out = argv[argv.index("-o") + 1]
        return cmd_hide_exports(path, out)
    if cmd == "write-crc":
        out = None
        if "-o" in argv:
            out = argv[argv.index("-o") + 1]
        return cmd_write_crc(path, out)
    if cmd == "wipe":
        out = None
        if "-o" in argv:
            out = argv[argv.index("-o") + 1]
        if "--list" not in argv:
            raise SystemExit("用法: wipe <dylib> --list <名单文件> [-o out] [--fill junk|nop]")
        lst = argv[argv.index("--list") + 1]
        fill = argv[argv.index("--fill") + 1] if "--fill" in argv else "nop"
        return cmd_wipe(path, out, lst, fill=fill, dry_run=("--dry-run" in argv))
    if cmd == "rename-selectors":
        out = None
        if "-o" in argv:
            out = argv[argv.index("-o") + 1]
        save_map = None
        if "--save-map" in argv:
            save_map = argv[argv.index("--save-map") + 1]
        keep_cls = "--keep-classnames" in argv
        skip_sr = "--skip-selrefs" in argv
        force_cls = "--rename-classes" in argv
        only_set = exclude_set = None
        if "--only" in argv:
            only_set = set(l.strip() for l in open(argv[argv.index("--only") + 1], encoding="utf-8")
                           if l.strip() and not l.startswith("#"))
        if "--exclude" in argv:
            exclude_set = set(l.strip() for l in open(argv[argv.index("--exclude") + 1], encoding="utf-8")
                              if l.strip() and not l.startswith("#"))
        return cmd_rename_selectors(path, out, save_map, keep_cls, skip_sr, force_cls,
                                    only_set, exclude_set)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

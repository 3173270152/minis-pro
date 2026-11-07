/*
 * h_mem.h — 内存访问指令 handler
 *
 * LDRB / LDR(32/64) / STRB / STR(32/64)
 * 编码: [op | d/base | n/src | offset16]  共 5B
 * offset16 按 signed int16 解释以支持 LDUR/STUR 负偏移
 *
 * 保护:
 *   1. SP(R31) 栈边界检查 —— 防止栈溢出
 *   2. 通用地址检查 —— R[n] < 0x10000 视为无效指针
 *      记录日志并跳过（原来会 SIGBUS 崩）
 */
#ifndef H_MEM_H
#define H_MEM_H

#include "../vm_decode.h"
#include "../vm_types.h"

/* SP 栈访问边界检查: 地址在 vm_stk 范围内才执行 */
#define VM_STK_CHECK(vm, addr, width) \
  ((addr) >= VM_STK_LO(vm) && ((addr) + (width)) <= VM_STK_HI(vm))

/* 通用地址有效性: 低于 0x10000 一定是无效指针（空页） */
#define VM_ADDR_BAD(addr) ((addr) < 0x10000ULL)

/* ==================================================================
 * ★ 页权限保护（不降级：只加检查，不跳过任何合法访问）
 *
 * 根因: 崩溃 SIGBUS / KERN_PROTECTION_FAILURE —— VM 对只读页(__TEXT)
 *       发起了写操作。原来的 VM_ADDR_BAD 只查 <0x10000，
 *       挡不住 r-x 页、挡不住已解映射页。
 *
 * 做法: 用 mach_vm_region 查询目标页的 current_protection：
 *         - 读   -> 要求 VM_PROT_READ
 *         - 写   -> 要求 VM_PROT_WRITE
 *       未映射 / 权限不足 -> 视为非法访问，handler 安全跳过并记日志，
 *       而不是让 CPU 抛 SIGBUS 把进程打死。
 *
 * 缓存: 按 4KB 页做 16 项直接映射缓存，命中不产生 syscall。
 * ================================================================== */
#include <mach/mach.h>
#include <mach/vm_region.h>

#define VM_PGCACHE_N 16

typedef struct {
  u64 page;   /* 页基址, 0 = 空 */
  u32 prot;   /* current_protection, 0xFFFFFFFF = 未映射 */
} vm_pgcache_t;

/* 查询 addr 所在页的有效权限位 (读=1, 写=2, 执行=4)；未映射返回 0 */
static inline u32 vm_page_prot(vm_ctx_t *vm, u64 addr) {
  u64 page = addr & ~0xFFFULL;
  u32 slot = (u32)((page >> 12) & (VM_PGCACHE_N - 1));
  vm_pgcache_t *c = &vm->pgc[slot];
  if (c->page == page) return c->prot;

  u32 prot = 0;
  vm_address_t q = (vm_address_t)page;
  vm_size_t sz = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t obj = MACH_PORT_NULL;
  if (vm_region_64(mach_task_self(), &q, &sz, VM_REGION_BASIC_INFO_64,
                   (vm_region_info_t)&info, &cnt, &obj) == KERN_SUCCESS) {
    /* ★ 修复: vm_region_64 返回的 q 是"包含该地址的区域起始"，不是请求的页本身。
     *   原先要求 q == page，导致 __TEXT 这种几 MB 的大映射里除首页外
     *   全部被判成"未映射" -> CALL_LIT/NOREAD 大面积失败 -> VM 返回 0。
     *   正确判定: 请求页必须落在 [q, q+sz) 区间内。*/
    if (q <= page && page < q + sz) {
      if (info.protection & VM_PROT_READ)    prot |= 1;
      if (info.protection & VM_PROT_WRITE)   prot |= 2;
      if (info.protection & VM_PROT_EXECUTE) prot |= 4;
    }
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
  } else {
    prot = 0;                 /* 未映射 */
  }
  c->page = page;
  c->prot = prot;
  return prot;
}

/* 可读: 页已映射且允许读 */
static inline int vm_can_read(vm_ctx_t *vm, u64 addr, u32 width) {
  if (VM_ADDR_BAD(addr)) return 0;
  if ((vm_page_prot(vm, addr) & 1) == 0) return 0;
  /* 跨页尾部也要可读 */
  if ((addr & 0xFFF) + width > 0x1000)
    if ((vm_page_prot(vm, addr + width - 1) & 1) == 0) return 0;
  return 1;
}

/* 可写: 同时要求可读（STR 也要先有映射）+ 页可写 */
static inline int vm_can_write(vm_ctx_t *vm, u64 addr, u32 width) {
  if (VM_ADDR_BAD(addr)) return 0;
  u32 p = vm_page_prot(vm, addr);
  if ((p & 1) == 0 || (p & 2) == 0) return 0;
  if ((addr & 0xFFF) + width > 0x1000) {
    u32 p2 = vm_page_prot(vm, addr + width - 1);
    if ((p2 & 1) == 0 || (p2 & 2) == 0) return 0;
  }
  return 1;
}

/* 可执行: 页已映射且带 VM_PROT_EXECUTE（CALL_LIT / BR_REG 用） */
static inline int vm_can_exec(vm_ctx_t *vm, u64 addr) {
  if (VM_ADDR_BAD(addr)) return 0;
  return (vm_page_prot(vm, addr) & 4) != 0;
}

/* ---- 加载 (LDR) ---- */

/* LDRB Wd, [Xn, #off16] */
static inline u32 h_load8(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[n & 31] + off;
  if ((n & 31) == 31 && !VM_STK_CHECK(vm, addr, 1))
    return 5; /* SP 越界, 静默跳过 */
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD ldr8 n=%u R[n]=0x%llx off=%d pc=%u",
          n & 31, vm->R[n & 31], (int)off, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  if (!vm_can_read(vm, addr, 1)) {
    VMDBG("[vm] NOREAD ldr8 addr=0x%llx pc=%u", addr, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  vm->R[d & 31] = *(u8 *)addr;
  return 5;
}

/* LDR Wd, [Xn, #off16] */
static inline u32 h_load32(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[n & 31] + off;
  if ((n & 31) == 31 && !VM_STK_CHECK(vm, addr, 4))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD ldr32 n=%u R[n]=0x%llx off=%d pc=%u",
          n & 31, vm->R[n & 31], (int)off, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  if (!vm_can_read(vm, addr, 4)) {
    VMDBG("[vm] NOREAD ldr32 addr=0x%llx pc=%u", addr, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  vm->R[d & 31] = *(u32 *)addr;
  return 5;
}

/* LDR Xd, [Xn, #off16] */
static inline u32 h_load64(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[n & 31] + off;
  if ((n & 31) == 31 && !VM_STK_CHECK(vm, addr, 8))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD ldr64 n=%u R[n]=0x%llx off=%d pc=%u",
          n & 31, vm->R[n & 31], (int)off, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  if (!vm_can_read(vm, addr, 8)) {
    VMDBG("[vm] NOREAD ldr64 addr=0x%llx pc=%u", addr, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  vm->R[d & 31] = *(u64 *)addr;
  return 5;
}

/* LDRH Wd, [Xn, #off16] */
static inline u32 h_load16(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[n & 31] + off;
  if ((n & 31) == 31 && !VM_STK_CHECK(vm, addr, 2))
    return 5; /* SP 越界, 静默跳过 */
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD ldr16 n=%u R[n]=0x%llx off=%d pc=%u",
          n & 31, vm->R[n & 31], (int)off, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  if (!vm_can_read(vm, addr, 2)) {
    VMDBG("[vm] NOREAD ldr16 addr=0x%llx pc=%u", addr, vm->pc);
    vm->R[d & 31] = 0;
    return 5;
  }
  vm->R[d & 31] = *(u16 *)addr;
  return 5;
}

/* ---- 存储 (STR) ---- */

/* STRB Wn, [Xb, #off16] */
static inline u32 h_store8(vm_ctx_t *vm) {
  u8 b = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[b & 31] + off;
  if ((b & 31) == 31 && !VM_STK_CHECK(vm, addr, 1))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD str8 b=%u R[b]=0x%llx off=%d pc=%u",
          b & 31, vm->R[b & 31], (int)off, vm->pc);
    return 5;
  }
  if (!vm_can_write(vm, addr, 1)) {
    VMDBG("[vm] NOWRITE str8 addr=0x%llx pc=%u", addr, vm->pc);
    return 5;
  }
  *(u8 *)addr = (u8)vm->R[n & 31];
  return 5;
}

/* STRH Wn, [Xb, #off16] */
static inline u32 h_store16(vm_ctx_t *vm) {
  u8 b = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[b & 31] + off;
  if ((b & 31) == 31 && !VM_STK_CHECK(vm, addr, 2))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD str16 b=%u R[b]=0x%llx off=%d pc=%u",
          b & 31, vm->R[b & 31], (int)off, vm->pc);
    return 5;
  }
  if (!vm_can_write(vm, addr, 2)) {
    VMDBG("[vm] NOWRITE str16 addr=0x%llx pc=%u", addr, vm->pc);
    return 5;
  }
  *(u16 *)addr = (u16)vm->R[n & 31];
  return 5;
}

/* STR Wn, [Xb, #off16] */
static inline u32 h_store32(vm_ctx_t *vm) {
  u8 b = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[b & 31] + off;
  if ((b & 31) == 31 && !VM_STK_CHECK(vm, addr, 4))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD str32 b=%u R[b]=0x%llx off=%d pc=%u",
          b & 31, vm->R[b & 31], (int)off, vm->pc);
    return 5;
  }
  if (!vm_can_write(vm, addr, 4)) {
    VMDBG("[vm] NOWRITE str32 addr=0x%llx pc=%u", addr, vm->pc);
    return 5;
  }
  *(u32 *)addr = (u32)vm->R[n & 31];
  return 5;
}

/* STR Xn, [Xb, #off16] */
static inline u32 h_store64(vm_ctx_t *vm) {
  u8 b = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u64 addr = vm->R[b & 31] + off;
  if ((b & 31) == 31 && !VM_STK_CHECK(vm, addr, 8))
    return 5;
  if (VM_ADDR_BAD(addr)) {
    VMDBG("[vm] BAD str64 b=%u R[b]=0x%llx off=%d pc=%u",
          b & 31, vm->R[b & 31], (int)off, vm->pc);
    return 5;
  }
  if (!vm_can_write(vm, addr, 8)) {
    VMDBG("[vm] NOWRITE str64 addr=0x%llx pc=%u", addr, vm->pc);
    return 5;
  }
  *(u64 *)addr = vm->R[n & 31];
  return 5;
}


/* ---- 寄存器偏移寻址 (LDR/STR Xt,[Xn,Xm,LSL#s]) ---- */
/* [op][rt][rn][rm][shift]  5B */

#define DEF_IDX_LOAD(name, ty)                                       \
static inline u32 name(vm_ctx_t *vm) {                               \
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];                 \
  u8 m = vm->bc[vm->pc + 3], sh = vm->bc[vm->pc + 4] & 0x3F;         \
  u64 addr = vm->R[n & 31] + (vm->R[m & 31] << sh);                  \
  if (VM_ADDR_BAD(addr)) {                                           \
    VMDBG("[vm] BAD idxld n=%u R[n]=0x%llx m=%u R[m]=0x%llx pc=%u",  \
          n & 31, vm->R[n & 31], m & 31, vm->R[m & 31], vm->pc);     \
    vm->R[d & 31] = 0;                                               \
    return 5;                                                        \
  }                                                                  \
  if (!vm_can_read(vm, addr, (u32)sizeof(ty))) {                     \
    VMDBG("[vm] NOREAD idxld addr=0x%llx pc=%u", addr, vm->pc);      \
    vm->R[d & 31] = 0;                                               \
    return 5;                                                        \
  }                                                                  \
  vm->R[d & 31] = (u64)(*(ty *)addr);                                \
  return 5;                                                          \
}

#define DEF_IDX_STORE(name, ty)                                      \
static inline u32 name(vm_ctx_t *vm) {                               \
  u8 b = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];                 \
  u8 m = vm->bc[vm->pc + 3], sh = vm->bc[vm->pc + 4] & 0x3F;         \
  u64 addr = vm->R[b & 31] + (vm->R[n & 31] << sh);                  \
  if (VM_ADDR_BAD(addr)) {                                           \
    VMDBG("[vm] BAD idxst b=%u R[b]=0x%llx pc=%u",                   \
          b & 31, vm->R[b & 31], vm->pc);                            \
    return 5;                                                        \
  }                                                                  \
  if (!vm_can_write(vm, addr, (u32)sizeof(ty))) {                    \
    VMDBG("[vm] NOWRITE idxst addr=0x%llx pc=%u", addr, vm->pc);     \
    return 5;                                                        \
  }                                                                  \
  *(ty *)addr = (ty)vm->R[m & 31];                                   \
  return 5;                                                          \
}

DEF_IDX_LOAD(h_load_idx8,  u8)
DEF_IDX_LOAD(h_load_idx16, u16)
DEF_IDX_LOAD(h_load_idx32, u32)
DEF_IDX_LOAD(h_load_idx64, u64)
DEF_IDX_STORE(h_store_idx8,  u8)
DEF_IDX_STORE(h_store_idx16, u16)
DEF_IDX_STORE(h_store_idx32, u32)
DEF_IDX_STORE(h_store_idx64, u64)


/* ---- LDR literal: R[rt] = *(type*)(R28 + imm32) ----
 * R28 = image base（跳板/调用方设置）
 * [op][rt][imm32]  6B
 */
static inline u32 h_load_lit8(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1];
  u32 off = rd32(&vm->bc[vm->pc + 2]);
  u64 a = vm->image_base + (u64)off;  /* v3.3: literal 用 image 绝对偏移 */
  if (!vm_can_read(vm, a, 1)) {
    VMDBG("[vm] NOREAD lit8 off=0x%x pc=%u", off, vm->pc);
    vm->R[rt & 31] = 0;
    return 6;
  }
  vm->R[rt & 31] = *(u8 *)a;
  return 6;
}
static inline u32 h_load_lit16(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1];
  u32 off = rd32(&vm->bc[vm->pc + 2]);
  u64 a = vm->image_base + (u64)off;  /* v3.3: literal 用 image 绝对偏移 */
  if (!vm_can_read(vm, a, 2)) {
    VMDBG("[vm] NOREAD lit16 off=0x%x pc=%u", off, vm->pc);
    vm->R[rt & 31] = 0;
    return 6;
  }
  vm->R[rt & 31] = *(u16 *)a;
  return 6;
}
static inline u32 h_load_lit32(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1];
  u32 off = rd32(&vm->bc[vm->pc + 2]);
  u64 a = vm->image_base + (u64)off;  /* v3.3: literal 用 image 绝对偏移 */
  if (!vm_can_read(vm, a, 4)) {
    VMDBG("[vm] NOREAD lit32 off=0x%x pc=%u", off, vm->pc);
    vm->R[rt & 31] = 0;
    return 6;
  }
  vm->R[rt & 31] = *(u32 *)a;
  return 6;
}
static inline u32 h_load_lit64(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1];
  u32 off = rd32(&vm->bc[vm->pc + 2]);
  u64 a = vm->image_base + (u64)off;  /* v3.3: literal 用 image 绝对偏移 */
  if (!vm_can_read(vm, a, 8)) {
    VMDBG("[vm] NOREAD lit64 off=0x%x pc=%u", off, vm->pc);
    vm->R[rt & 31] = 0;
    return 6;
  }
  vm->R[rt & 31] = *(u64 *)a;
  return 6;
}

/* ---- v-cov80: LDR 浮点字面量 (LDR St/Dt, =lit)  [op][rt][imm32][sz] 7B ----
 * 把 PC 相对加载的 FP 常量读进 V[rt]；sz:0=S(32) 1=D(64)。地址 = image_base+off。*/
static inline u32 h_load_lit_fp(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1];
  u32 off = rd32(&vm->bc[vm->pc + 2]);
  u8 sz = vm->bc[vm->pc + 6] & 1;
  u64 a = vm->image_base + (u64)off;
  if (!vm_can_read(vm, a, sz ? 8 : 4)) {
    vm->V[2 * (rt & 31)] = 0;
    return 7;
  }
  vm->V[2 * (rt & 31)] = sz ? *(u64 *)a : (u64)*(u32 *)a;
  return 7;
}

#endif /* H_MEM_H */

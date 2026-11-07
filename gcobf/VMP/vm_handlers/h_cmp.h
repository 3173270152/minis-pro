/*
 * h_cmp.h — 比较指令 handler
 *
 * CMP Xn, Xm     [3B]    设置 FL (ZF/SF/CF)
 * CMP Xn, #imm32 [6B]
 */
#ifndef H_CMP_H
#define H_CMP_H

#include "../vm_decode.h"
#include "../vm_types.h"


/* 内部: 根据两个操作数设置标志位 */
static inline void vm_set_flags(vm_ctx_t *vm, u64 va, u64 vb) {
  vm->FL = 0;
  if (va == vb)
    vm->FL |= FL_ZERO; /* Z: 相等 */
  if ((i64)va < (i64)vb)
    vm->FL |= FL_SIGN; /* N: 有符号小于 */
  if (va < vb)
    vm->FL |= FL_CARRY; /* C: 无符号小于 */
}


/* TST Xn, Xm  [4B: op | n | m | pad]
 * = ANDS XZR, Xn, Xm: 只影响 Z(结果是否 0) 和 N(结果符号位)，C=V=0。*/
static inline u32 h_tst(vm_ctx_t *vm) {
  u8 a = vm->bc[vm->pc + 1], b = vm->bc[vm->pc + 2];
  u64 r = vm->R[a & 31] & vm->R[b & 31];
  vm->FL = 0;
  if (r == 0) vm->FL |= FL_ZERO;
  if ((i64)r < 0) vm->FL |= FL_SIGN;
  return 4;
}

/* CMP Xn, Xm      [3B: op | n | m] */
static inline u32 h_cmp(vm_ctx_t *vm) {
  u8 a = vm->bc[vm->pc + 1], b = vm->bc[vm->pc + 2];
  vm_set_flags(vm, vm->R[a & 31], vm->R[b & 31]);
  return 3;
}

/* CMP Xn, #imm32  [6B: op | n | imm32] */
static inline u32 h_cmp_imm(vm_ctx_t *vm) {
  u8 r = vm->bc[vm->pc + 1];
  u32 imm = rd32(&vm->bc[vm->pc + 2]);
  vm_set_flags(vm, vm->R[r & 31], (u64)imm);
  return 6;
}

/* ---- 条件码判断辅助 ---- */
/* 根据 ARM64 条件码和当前 VM 标志位判断条件是否成立 */
static inline int vm_cond_holds(vm_ctx_t *vm, u8 cond) {
  u32 fl = vm->FL;
  switch (cond & 0xF) {
  case 0x0: return  (fl & FL_ZERO);                    /* EQ: Z=1 */
  case 0x1: return !(fl & FL_ZERO);                    /* NE: Z=0 */
  case 0x2: return !(fl & FL_CARRY);                   /* CS/HS: C=0 in our encoding means no borrow → carry set */
  case 0x3: return  (fl & FL_CARRY);                   /* CC/LO: C=1 → borrow → carry clear */
  case 0x4: return  (fl & FL_SIGN);                    /* MI: N=1 */
  case 0x5: return !(fl & FL_SIGN);                    /* PL: N=0 */
  case 0x6: return 0;                                  /* VS: not tracked */
  case 0x7: return 1;                                  /* VC: not tracked, assume true */
  case 0x8: return !(fl & FL_CARRY) && !(fl & FL_ZERO); /* HI: C=1 && Z=0 (our C inverted) */
  case 0x9: return  (fl & FL_CARRY) ||  (fl & FL_ZERO); /* LS: C=0 || Z=1 */
  case 0xA: return !(fl & FL_SIGN);                    /* GE: N==V, simplified to N=0 */
  case 0xB: return  (fl & FL_SIGN);                    /* LT: N!=V, simplified to N=1 */
  case 0xC: return !(fl & FL_ZERO) && !(fl & FL_SIGN); /* GT: Z=0 && N==V */
  case 0xD: return  (fl & FL_ZERO) ||  (fl & FL_SIGN); /* LE: Z=1 || N!=V */
  case 0xE: return 1;                                  /* AL: always */
  default:  return 1;
  }
}

/* 将 ARM64 NZCV 4-bit 值转换为 VM 标志位 */
static inline void vm_set_nzcv(vm_ctx_t *vm, u8 nzcv) {
  vm->FL = 0;
  if (nzcv & 0x4) vm->FL |= FL_ZERO;  /* Z bit (bit 2) */
  if (nzcv & 0x8) vm->FL |= FL_SIGN;  /* N bit (bit 3) */
  if (nzcv & 0x2) vm->FL |= FL_CARRY; /* C bit (bit 1) — note: our FL_CARRY = unsigned-less-than, ARM C is inverted */
  /* V bit (bit 0) not tracked */
}

/* CCMP Xn, Xm, #nzcv, cond  [6B: op | cond | nzcv | rn | rm | sf]
 * if (cond holds) flags = CMP(Rn, Rm); else flags = nzcv */
static inline u32 h_ccmp_reg(vm_ctx_t *vm) {
  u8 cond = vm->bc[vm->pc + 1];
  u8 nzcv = vm->bc[vm->pc + 2];
  u8 rn   = vm->bc[vm->pc + 3];
  u8 rm   = vm->bc[vm->pc + 4];
  u8 sf   = vm->bc[vm->pc + 5];
  if (vm_cond_holds(vm, cond)) {
    u64 va = vm->R[rn & 31];
    u64 vb = vm->R[rm & 31];
    if (!sf) { va &= 0xFFFFFFFF; vb &= 0xFFFFFFFF; }
    vm_set_flags(vm, va, vb);
  } else {
    vm_set_nzcv(vm, nzcv);
  }
  return 6;
}

/* CCMP Xn, #imm5, #nzcv, cond  [6B: op | cond | nzcv | rn | imm5 | sf] */
static inline u32 h_ccmp_imm(vm_ctx_t *vm) {
  u8 cond  = vm->bc[vm->pc + 1];
  u8 nzcv  = vm->bc[vm->pc + 2];
  u8 rn    = vm->bc[vm->pc + 3];
  u8 imm5  = vm->bc[vm->pc + 4];
  u8 sf    = vm->bc[vm->pc + 5];
  if (vm_cond_holds(vm, cond)) {
    u64 va = vm->R[rn & 31];
    u64 vb = (u64)(imm5 & 0x1F);
    if (!sf) { va &= 0xFFFFFFFF; }
    vm_set_flags(vm, va, vb);
  } else {
    vm_set_nzcv(vm, nzcv);
  }
  return 6;
}

/* CCMN Xn, Xm, #nzcv, cond  [6B: op | cond | nzcv | rn | rm | sf]
 * if (cond holds) flags = CMN(Rn, Rm) = CMP(Rn, -Rm); else flags = nzcv */
static inline u32 h_ccmn_reg(vm_ctx_t *vm) {
  u8 cond = vm->bc[vm->pc + 1];
  u8 nzcv = vm->bc[vm->pc + 2];
  u8 rn   = vm->bc[vm->pc + 3];
  u8 rm   = vm->bc[vm->pc + 4];
  u8 sf   = vm->bc[vm->pc + 5];
  if (vm_cond_holds(vm, cond)) {
    u64 va = vm->R[rn & 31];
    u64 vb = vm->R[rm & 31];
    if (!sf) { va &= 0xFFFFFFFF; vb &= 0xFFFFFFFF; }
    /* CMN: compare Rn + Rm against 0 → equivalent to CMP(Rn, -Rm) */
    u64 sum = va + vb;
    if (!sf) sum &= 0xFFFFFFFF;
    vm->FL = 0;
    if (sum == 0) vm->FL |= FL_ZERO;
    if (!sf) {
      if ((i32)sum < 0) vm->FL |= FL_SIGN;
    } else {
      if ((i64)sum < 0) vm->FL |= FL_SIGN;
    }
    if ((!sf && (va + vb) > 0xFFFFFFFF) || (sf && va > (u64)~(u64)0 - vb))
      vm->FL |= FL_CARRY;
  } else {
    vm_set_nzcv(vm, nzcv);
  }
  return 6;
}

/* CCMN Xn, #imm5, #nzcv, cond  [6B: op | cond | nzcv | rn | imm5 | sf] */
static inline u32 h_ccmn_imm(vm_ctx_t *vm) {
  u8 cond  = vm->bc[vm->pc + 1];
  u8 nzcv  = vm->bc[vm->pc + 2];
  u8 rn    = vm->bc[vm->pc + 3];
  u8 imm5  = vm->bc[vm->pc + 4];
  u8 sf    = vm->bc[vm->pc + 5];
  if (vm_cond_holds(vm, cond)) {
    u64 va = vm->R[rn & 31];
    u64 vb = (u64)(imm5 & 0x1F);
    if (!sf) { va &= 0xFFFFFFFF; }
    u64 sum = va + vb;
    if (!sf) sum &= 0xFFFFFFFF;
    vm->FL = 0;
    if (sum == 0) vm->FL |= FL_ZERO;
    if (!sf) {
      if ((i32)sum < 0) vm->FL |= FL_SIGN;
    } else {
      if ((i64)sum < 0) vm->FL |= FL_SIGN;
    }
    if ((!sf && (va + vb) > 0xFFFFFFFF) || (sf && va > (u64)~(u64)0 - vb))
      vm->FL |= FL_CARRY;
  } else {
    vm_set_nzcv(vm, nzcv);
  }
  return 6;
}

#endif /* H_CMP_H */

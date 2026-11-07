/*
 * h_fp.h — 浮点指令 handler
 *
 * V[0]..V[31] 既是 S0-S31（低32位）也是 D0-D31（64位）
 * sf=0 -> 单精度(float, 32位)，sf=1 -> 双精度(double, 64位)
 */
#ifndef H_FP_H
#define H_FP_H

#include "../vm_decode.h"
#include "../vm_types.h"

typedef union { u64 u; double d; } fp64_u;
typedef union { u32 u; float  f; } fp32_u;

/* ---- 四则运算 ---- */
#define DEF_FP_ARITH(name, op)                                        \
static inline u32 name(vm_ctx_t *vm) {                                \
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];                  \
  u8 m = vm->bc[vm->pc + 3], sf = vm->bc[vm->pc + 4] & 1;             \
  if (sf) {                                                          \
    fp64_u a, b, r;                                                  \
    a.u = vm->V[2 * (n & 31)]; b.u = vm->V[2 * (m & 31)];                        \
    r.d = a.d op b.d;                                                \
    vm->V[2 * (d & 31)] = r.u;                                             \
  } else {                                                           \
    fp32_u a, b, r;                                                  \
    a.u = (u32)vm->V[2 * (n & 31)]; b.u = (u32)vm->V[2 * (m & 31)];              \
    r.f = a.f op b.f;                                                \
    vm->V[2 * (d & 31)] = r.u;                                             \
  }                                                                  \
  return 5;                                                          \
}

DEF_FP_ARITH(h_fadd, +)
DEF_FP_ARITH(h_fsub, -)
DEF_FP_ARITH(h_fmul, *)
DEF_FP_ARITH(h_fdiv, /)

/* ---- FMOV 寄存器: Vd = Vn ---- */

/* FMOV Dd, Xn  [3B: op | fd | rn]
 * 整数寄存器的 64 位直接搬进浮点寄存器的低 64 位（位模式不变）。*/
static inline u32 h_fmov_gen(vm_ctx_t *vm) {
  u8 fd = vm->bc[vm->pc + 1], rn = vm->bc[vm->pc + 2];
  vm->V[2 * (fd & 31)] = vm->R[rn & 31];
  return 3;
}

static inline u32 h_fmov_reg(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 sf = vm->bc[vm->pc + 3] & 1;
  if (sf) vm->V[2 * (d & 31)] = vm->V[2 * (n & 31)];
  else    vm->V[2 * (d & 31)] = (u32)vm->V[2 * (n & 31)];
  return 4;
}

/* ---- FNEG / FABS ---- */
static inline u32 h_fneg(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], sf = vm->bc[vm->pc + 3] & 1;
  if (sf) { fp64_u a, r; a.u = vm->V[2 * (n & 31)]; r.d = -a.d; vm->V[2 * (d & 31)] = r.u; }
  else    { fp32_u a, r; a.u = (u32)vm->V[2 * (n & 31)]; r.f = -a.f; vm->V[2 * (d & 31)] = r.u; }
  return 4;
}

static inline u32 h_fabs(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], sf = vm->bc[vm->pc + 3] & 1;
  if (sf) vm->V[2 * (d & 31)] = vm->V[2 * (n & 31)] & 0x7FFFFFFFFFFFFFFFULL;
  else    vm->V[2 * (d & 31)] = vm->V[2 * (n & 31)] & 0x7FFFFFFFULL;
  return 4;
}

/* ---- 精度转换: S<->D ---- */
/* dir: 0 = S->D, 1 = D->S */
static inline u32 h_fcvt(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], dir = vm->bc[vm->pc + 3] & 1;
  if (dir == 0) {                       /* float -> double */
    fp32_u a; fp64_u r;
    a.u = (u32)vm->V[2 * (n & 31)];
    r.d = (double)a.f;
    vm->V[2 * (d & 31)] = r.u;
  } else {                              /* double -> float */
    fp64_u a; fp32_u r;
    a.u = vm->V[2 * (n & 31)];
    r.f = (float)a.d;
    vm->V[2 * (d & 31)] = r.u;
  }
  return 4;
}

/* ---- 整数 -> 浮点 ---- */
static inline u32 h_scvtf(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];      /* n = R 寄存器 */
  u8 sf = vm->bc[vm->pc + 3] & 1;                          /* 浮点宽度 */
  u8 isw = vm->bc[vm->pc + 4] & 1;                         /* 整数宽度: 0=W 1=X */
  if (sf) {
    fp64_u r;
    r.d = isw ? (double)(i64)vm->R[n & 31] : (double)(i32)(u32)vm->R[n & 31];
    vm->V[2 * (d & 31)] = r.u;
  } else {
    fp32_u r;
    r.f = isw ? (float)(i64)vm->R[n & 31] : (float)(i32)(u32)vm->R[n & 31];
    vm->V[2 * (d & 31)] = r.u;
  }
  return 5;
}

static inline u32 h_ucvtf(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 sf = vm->bc[vm->pc + 3] & 1;
  u8 isw = vm->bc[vm->pc + 4] & 1;
  if (sf) {
    fp64_u r;
    r.d = isw ? (double)vm->R[n & 31] : (double)(u32)vm->R[n & 31];
    vm->V[2 * (d & 31)] = r.u;
  } else {
    fp32_u r;
    r.f = isw ? (float)vm->R[n & 31] : (float)(u32)vm->R[n & 31];
    vm->V[2 * (d & 31)] = r.u;
  }
  return 5;
}

/* ---- 浮点 -> 整数（向零截断）---- */
static inline u32 h_fcvtzs(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];   /* d = R 寄存器, n = V 寄存器 */
  u8 sf = vm->bc[vm->pc + 3] & 1;                       /* 浮点宽度 */
  u8 isw = vm->bc[vm->pc + 4] & 1;                      /* 整数宽度 */
  if (sf) {
    fp64_u a; a.u = vm->V[2 * (n & 31)];
    vm->R[d & 31] = isw ? (u64)(i64)a.d : (u64)(u32)(i32)a.d;
  } else {
    fp32_u a; a.u = (u32)vm->V[2 * (n & 31)];
    vm->R[d & 31] = isw ? (u64)(i64)a.f : (u64)(u32)(i32)a.f;
  }
  return 5;
}

static inline u32 h_fcvtzu(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 sf = vm->bc[vm->pc + 3] & 1;
  u8 isw = vm->bc[vm->pc + 4] & 1;
  if (sf) {
    fp64_u a; a.u = vm->V[2 * (n & 31)];
    vm->R[d & 31] = isw ? (u64)a.d : (u64)(u32)a.d;
  } else {
    fp32_u a; a.u = (u32)vm->V[2 * (n & 31)];
    vm->R[d & 31] = isw ? (u64)a.f : (u64)(u32)a.f;
  }
  return 5;
}

/* ---- FCMP: 设置 FL（与整数比较同一套标志）---- */
static inline u32 h_fcmp(vm_ctx_t *vm) {
  u8 n = vm->bc[vm->pc + 1], m = vm->bc[vm->pc + 2], sf = vm->bc[vm->pc + 3] & 1;
  int lt, eq;
  if (sf) {
    fp64_u a, b; a.u = vm->V[2 * (n & 31)]; b.u = vm->V[2 * (m & 31)];
    lt = (a.d < b.d); eq = (a.d == b.d);
  } else {
    fp32_u a, b; a.u = (u32)vm->V[2 * (n & 31)]; b.u = (u32)vm->V[2 * (m & 31)];
    lt = (a.f < b.f); eq = (a.f == b.f);
  }
  vm->FL = 0;
  if (eq) vm->FL |= FL_ZERO;
  if (lt) vm->FL |= FL_SIGN | FL_CARRY;   /* N=1, C=1(借用) */
  return 4;
}

/* ---- FP 存取: [op][rt][rn][off16][sz]  sz: 0=S 1=D ---- */
static inline u32 h_load_fp(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1], rn = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u8 sz = vm->bc[vm->pc + 5] & 1;
  u64 addr = vm->R[rn & 31] + off;
  if (sz) vm->V[2 * (rt & 31)] = *(u64 *)addr;
  else    vm->V[2 * (rt & 31)] = *(u32 *)addr;
  return 6;
}

static inline u32 h_store_fp(vm_ctx_t *vm) {
  u8 rt = vm->bc[vm->pc + 1], rn = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u8 sz = vm->bc[vm->pc + 5] & 1;
  u64 addr = vm->R[rn & 31] + off;
  if (sz) *(u64 *)addr = vm->V[2 * (rt & 31)];
  else    *(u32 *)addr = (u32)vm->V[2 * (rt & 31)];
  return 6;
}

/* ---- FMOV 立即数（浮点常量）: [op][rd][imm64][sf] ---- */
static inline u32 h_fmov_imm(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1];
  vm->V[2 * (d & 31)] = rd64(&vm->bc[vm->pc + 2]);
  return 10;
}

/* ---- v-cov80: FMAX / FMIN  [op][d][n][m][sf]  5B ----
 * FMAXNM/FMINNM 也映射到这里（仅 NaN 传播语义不同，对业务逻辑可忽略）。*/
static inline u32 h_fmax(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 m = vm->bc[vm->pc + 3], sf = vm->bc[vm->pc + 4] & 1;
  if (sf) { fp64_u a,b,r; a.u=vm->V[2*(n&31)]; b.u=vm->V[2*(m&31)];
            r.d = a.d > b.d ? a.d : b.d; vm->V[2*(d&31)] = r.u; }
  else    { fp32_u a,b,r; a.u=(u32)vm->V[2*(n&31)]; b.u=(u32)vm->V[2*(m&31)];
            r.f = a.f > b.f ? a.f : b.f; vm->V[2*(d&31)] = r.u; }
  return 5;
}
static inline u32 h_fmin(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 m = vm->bc[vm->pc + 3], sf = vm->bc[vm->pc + 4] & 1;
  if (sf) { fp64_u a,b,r; a.u=vm->V[2*(n&31)]; b.u=vm->V[2*(m&31)];
            r.d = a.d < b.d ? a.d : b.d; vm->V[2*(d&31)] = r.u; }
  else    { fp32_u a,b,r; a.u=(u32)vm->V[2*(n&31)]; b.u=(u32)vm->V[2*(m&31)];
            r.f = a.f < b.f ? a.f : b.f; vm->V[2*(d&31)] = r.u; }
  return 5;
}

/* ---- v-cov80: FSQRT  [op][d][n][sf]  4B ---- */
static inline u32 h_fsqrt(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], sf = vm->bc[vm->pc + 3] & 1;
  if (sf) { fp64_u a,r; a.u=vm->V[2*(n&31)]; r.d=__builtin_sqrt(a.d);  vm->V[2*(d&31)]=r.u; }
  else    { fp32_u a,r; a.u=(u32)vm->V[2*(n&31)]; r.f=__builtin_sqrtf(a.f); vm->V[2*(d&31)]=r.u; }
  return 4;
}

/* ---- v-cov80: FRINTx  [op][d][n][sf][mode]  5B ----
 * mode: 0=N(nearest-even) 1=P(ceil) 2=M(floor) 3=Z(trunc) 4=A(nearest-away) 其它=X/I(当前模式) */
static inline u32 h_frint(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  u8 sf = vm->bc[vm->pc + 3] & 1, mode = vm->bc[vm->pc + 4];
  if (sf) {
    fp64_u a,r; a.u=vm->V[2*(n&31)];
    switch (mode) {
      case 1: r.d=__builtin_ceil(a.d);  break;
      case 2: r.d=__builtin_floor(a.d); break;
      case 3: r.d=__builtin_trunc(a.d); break;
      case 4: r.d=__builtin_round(a.d); break;
      default: r.d=__builtin_rint(a.d); break;  /* N/X/I 用当前舍入 */
    }
    vm->V[2*(d&31)] = r.u;
  } else {
    fp32_u a,r; a.u=(u32)vm->V[2*(n&31)];
    switch (mode) {
      case 1: r.f=__builtin_ceilf(a.f);  break;
      case 2: r.f=__builtin_floorf(a.f); break;
      case 3: r.f=__builtin_truncf(a.f); break;
      case 4: r.f=__builtin_roundf(a.f); break;
      default: r.f=__builtin_rintf(a.f); break;
    }
    vm->V[2*(d&31)] = r.u;
  }
  return 5;
}

/* ---- v-neon: 标量 FMADD/FMSUB/FNMADD/FNMSUB  [op][d][n][m][a][sf][flags] 7B ----
 * flags bit0=o0(sub), bit1=o1(neg). d = (o1?-a:a) + (o0?-:+)(n*m) 按 4 种组合。*/
static inline u32 h_fmadd(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc+1], n = vm->bc[vm->pc+2], m = vm->bc[vm->pc+3];
  u8 a = vm->bc[vm->pc+4], sf = vm->bc[vm->pc+5] & 1, fl = vm->bc[vm->pc+6];
  int o0 = fl & 1, o1 = (fl >> 1) & 1;
  if (sf) {
    fp64_u vn, vm_, va, r;
    vn.u = vm->V[2*(n&31)]; vm_.u = vm->V[2*(m&31)]; va.u = vm->V[2*(a&31)];
    double prod = vn.d * vm_.d;
    if (!o1 && !o0) r.d =  va.d + prod;   /* FMADD  */
    else if (!o1 && o0) r.d =  va.d - prod; /* FMSUB  */
    else if (o1 && !o0) r.d = -va.d - prod; /* FNMADD */
    else r.d = -va.d + prod;              /* FNMSUB */
    vm->V[2*(d&31)] = r.u;
  } else {
    fp32_u vn, vm_, va, r;
    vn.u = (u32)vm->V[2*(n&31)]; vm_.u = (u32)vm->V[2*(m&31)]; va.u = (u32)vm->V[2*(a&31)];
    float prod = vn.f * vm_.f;
    if (!o1 && !o0) r.f =  va.f + prod;
    else if (!o1 && o0) r.f =  va.f - prod;
    else if (o1 && !o0) r.f = -va.f - prod;
    else r.f = -va.f + prod;
    vm->V[2*(d&31)] = r.u;
  }
  return 7;
}

/* ---- v-neon: 条件判定(与 VM 条件跳转同约定, V 位不跟踪按 0) ---- */
static inline int vm_cond_true(u32 FL, u8 cond) {
  int Z = (FL & FL_ZERO) != 0, N = (FL & FL_SIGN) != 0, C = (FL & FL_CARRY) != 0;
  switch (cond & 0xF) {
    case 0:  return Z;            /* EQ */
    case 1:  return !Z;           /* NE */
    case 2:  return C;            /* CS/HS */
    case 3:  return !C;           /* CC/LO */
    case 4:  return N;            /* MI */
    case 5:  return !N;           /* PL */
    case 6:  return 0;            /* VS (V 未跟踪) */
    case 7:  return 1;            /* VC */
    case 8:  return C && !Z;      /* HI */
    case 9:  return !C || Z;      /* LS */
    case 10: return !N;           /* GE (V=0 → N==0) */
    case 11: return N;            /* LT */
    case 12: return !Z && !N;     /* GT */
    case 13: return Z || N;       /* LE */
    default: return 1;            /* AL */
  }
}

/* ---- v-neon: FCSEL Vd, Vn, Vm, cond  [op][d][n][m][cond][sf] 6B ---- */
static inline u32 h_fcsel(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc+1], n = vm->bc[vm->pc+2], m = vm->bc[vm->pc+3];
  u8 cond = vm->bc[vm->pc+4], sf = vm->bc[vm->pc+5] & 1;
  u8 sel = vm_cond_true(vm->FL, cond) ? n : m;
  if (sf) vm->V[2*(d&31)] = vm->V[2*(sel&31)];
  else    vm->V[2*(d&31)] = (u32)vm->V[2*(sel&31)];
  return 6;
}

/* ---- v-neon: FCMP Vn, #0.0  复用 h_fcmp 的标志语义, m 当作 0 ----
 * [op][n][sf] 3B (与寄存器 FCMP 区分: 这里只有 n) */
static inline u32 h_fcmp_zero(vm_ctx_t *vm) {
  u8 n = vm->bc[vm->pc+1], sf = vm->bc[vm->pc+2] & 1;
  int lt, eq;
  if (sf) { fp64_u a; a.u = vm->V[2*(n&31)]; lt = (a.d < 0.0); eq = (a.d == 0.0); }
  else    { fp32_u a; a.u = (u32)vm->V[2*(n&31)]; lt = (a.f < 0.0f); eq = (a.f == 0.0f); }
  vm->FL = 0;
  if (eq) vm->FL |= FL_ZERO;
  if (lt) vm->FL |= FL_SIGN | FL_CARRY;
  return 3;
}

#endif /* H_FP_H */

/*
 * h_vec.h — NEON / AdvSIMD 向量指令 handler
 *
 * V 寄存器文件: vm->V[2*r] = Qr 低 64 位, vm->V[2*r+1] = Qr 高 64 位。
 * 处理模型: 把 Vn/Vm 拷进 16 字节缓冲 → 按 lane 处理 → 写回 Vd。
 * 保证 lane 语义正确(宽度/有符号/浮点),不追求性能。
 *
 * esz: 0=8bit 1=16bit 2=32bit 3=64bit (FP: 2=float 3=double)
 * q:   1=128位(全 16 字节) 0=64位(低 8 字节, 高 8 字节清零)
 */
#ifndef H_VEC_H
#define H_VEC_H

#include "../vm_decode.h"
#include "../vm_types.h"

/* ---- 读/写 128 位向量到 16 字节缓冲 ---- */
static inline void vreg_get(vm_ctx_t *vm, u8 r, u8 out[16]) {
  u64 lo = vm->V[2 * (r & 31)], hi = vm->V[2 * (r & 31) + 1];
  for (int i = 0; i < 8; i++) { out[i] = (u8)(lo >> (i * 8)); out[8 + i] = (u8)(hi >> (i * 8)); }
}
static inline void vreg_put(vm_ctx_t *vm, u8 r, const u8 in[16]) {
  u64 lo = 0, hi = 0;
  for (int i = 0; i < 8; i++) { lo |= (u64)in[i] << (i * 8); hi |= (u64)in[8 + i] << (i * 8); }
  vm->V[2 * (r & 31)] = lo; vm->V[2 * (r & 31) + 1] = hi;
}

/* lane 读取(按宽度+符号) */
static inline u64 lane_get(const u8 b[16], int esz, int idx) {
  int sz = 1 << esz; const u8 *p = b + idx * sz; u64 v = 0;
  for (int i = 0; i < sz; i++) v |= (u64)p[i] << (i * 8);
  return v;
}
static inline void lane_put(u8 b[16], int esz, int idx, u64 v) {
  int sz = 1 << esz; u8 *p = b + idx * sz;
  for (int i = 0; i < sz; i++) p[i] = (u8)(v >> (i * 8));
}
static inline i64 sext(u64 v, int esz) {
  int bits = 8 << esz;
  if (bits >= 64) return (i64)v;
  u64 m = 1ULL << (bits - 1);
  return (i64)((v ^ m) - m);
}

typedef union { u32 u; float f; } vf32_u;
typedef union { u64 u; double d; } vf64_u;

/* ================================================================
 * OP_VMOVI 0x3A — 修饰立即数: Vd = {lo64, hi64}  [op][vd][lo:8][hi:8] 18B
 * (翻译器预计算 movi/mvni/fmov-vec-imm 的 128 位常量)
 * ================================================================ */
static inline u32 h_vmovi(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1];
  vm->V[2 * (d & 31)]     = rd64(&vm->bc[vm->pc + 2]);
  vm->V[2 * (d & 31) + 1] = rd64(&vm->bc[vm->pc + 10]);
  return 18;
}

/* ================================================================
 * OP_VLDR 0x3B / OP_VSTR 0x3E — 128/64 位访存
 * [op][vt][rn][off16][q] 6B   addr = R[rn]+off; q:1=16B 0=8B
 * ================================================================ */
static inline u32 h_vldr(vm_ctx_t *vm) {
  u8 t = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u8 q = vm->bc[vm->pc + 5] & 1;
  u64 addr = vm->R[n & 31] + off;
  vm->V[2 * (t & 31)] = *(u64 *)addr;
  vm->V[2 * (t & 31) + 1] = q ? *(u64 *)(addr + 8) : 0;
  return 6;
}
static inline u32 h_vstr(vm_ctx_t *vm) {
  u8 t = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  i16 off = (i16)rd16(&vm->bc[vm->pc + 3]);
  u8 q = vm->bc[vm->pc + 5] & 1;
  u64 addr = vm->R[n & 31] + off;
  *(u64 *)addr = vm->V[2 * (t & 31)];
  if (q) *(u64 *)(addr + 8) = vm->V[2 * (t & 31) + 1];
  return 6;
}

/* ================================================================
 * OP_V3S 0x3F — three-same 通用: [op][vd][vn][vm][esz][u][opc][q] 8B
 *   opc<32  整数; opc>=32 浮点(esz:2=float 3=double)
 * ================================================================ */
static inline u32 h_v3s(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], m = vm->bc[vm->pc + 3];
  int esz = vm->bc[vm->pc + 4] & 3, U = vm->bc[vm->pc + 5] & 1;
  u8 opc = vm->bc[vm->pc + 6], q = vm->bc[vm->pc + 7] & 1;
  u8 bn[16], bm[16], br[16]; for (int i=0;i<16;i++) br[i]=0;
  vreg_get(vm, n, bn); vreg_get(vm, m, bm);
  int bytes = q ? 16 : 8, sz = 1 << esz, nl = bytes / sz;
  if (opc < 32) {
    for (int l = 0; l < nl; l++) {
      u64 a = lane_get(bn, esz, l), b = lane_get(bm, esz, l), r = 0;
      switch (opc) {
        case 0: r = a + b; break;                 /* add */
        case 1: r = a - b; break;                 /* sub */
        case 2: r = a * b; break;                 /* mul */
        case 3: r = a & b; break;                 /* and */
        case 4: r = a | b; break;                 /* orr */
        case 5: r = a ^ b; break;                 /* eor */
        case 6: r = a & ~b; break;                /* bic */
        case 7: r = a | ~b; break;                /* orn */
        case 8: r = (a == b) ? ~0ULL : 0; break;  /* cmeq */
        case 9: r = (U ? (a > b) : (sext(a,esz) > sext(b,esz))) ? ~0ULL : 0; break;  /* cmhi/cmgt */
        case 10: r = (U ? (a >= b) : (sext(a,esz) >= sext(b,esz))) ? ~0ULL : 0; break; /* cmhs/cmge */
        case 13: r = U ? (a > b ? a : b) : ((sext(a,esz) > sext(b,esz)) ? a : b); break; /* max */
        case 14: r = U ? (a < b ? a : b) : ((sext(a,esz) < sext(b,esz)) ? a : b); break; /* min */
        default: r = 0; break;
      }
      lane_put(br, esz, l, r);
    }
  } else {
    for (int l = 0; l < nl; l++) {
      if (esz == 3) {
        vf64_u a, b, r; a.u = lane_get(bn,3,l); b.u = lane_get(bm,3,l); r.d = 0;
        switch (opc) {
          case 32: r.d = a.d + b.d; break; case 33: r.d = a.d - b.d; break;
          case 34: r.d = a.d * b.d; break; case 35: r.d = a.d / b.d; break;
          case 36: r.d = a.d > b.d ? a.d : b.d; break; case 37: r.d = a.d < b.d ? a.d : b.d; break;
          case 38: r.u = (a.d == b.d) ? ~0ULL : 0; break;
          case 39: r.u = (a.d >  b.d) ? ~0ULL : 0; break;
          case 40: r.u = (a.d >= b.d) ? ~0ULL : 0; break;
          case 41: r.d = a.d > b.d ? a.d - b.d : b.d - a.d; break; /* fabd */
          default: r.d = 0; break;
        }
        lane_put(br, 3, l, r.u);
      } else {
        vf32_u a, b, r; a.u=(u32)lane_get(bn,2,l); b.u=(u32)lane_get(bm,2,l); r.f=0;
        switch (opc) {
          case 32: r.f = a.f + b.f; break; case 33: r.f = a.f - b.f; break;
          case 34: r.f = a.f * b.f; break; case 35: r.f = a.f / b.f; break;
          case 36: r.f = a.f > b.f ? a.f : b.f; break; case 37: r.f = a.f < b.f ? a.f : b.f; break;
          case 38: r.u = (a.f == b.f) ? 0xFFFFFFFFu : 0; break;
          case 39: r.u = (a.f >  b.f) ? 0xFFFFFFFFu : 0; break;
          case 40: r.u = (a.f >= b.f) ? 0xFFFFFFFFu : 0; break;
          case 41: r.f = a.f > b.f ? a.f - b.f : b.f - a.f; break;
          default: r.f = 0; break;
        }
        lane_put(br, 2, l, r.u);
      }
    }
  }
  vreg_put(vm, d, br);
  return 8;
}

/* ================================================================
 * OP_VFMA 0x67 — fmla/fmls(向量): Vd += (±)Vn*Vm
 *   [op][vd][vn][vm][esz][sub][q] 7B  esz:2=float 3=double
 * ================================================================ */
static inline u32 h_vfma(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2], m = vm->bc[vm->pc + 3];
  int esz = vm->bc[vm->pc + 4] & 3, sub = vm->bc[vm->pc + 5] & 1, q = vm->bc[vm->pc + 6] & 1;
  u8 bn[16], bm[16], bd[16]; vreg_get(vm,n,bn); vreg_get(vm,m,bm); vreg_get(vm,d,bd);
  int bytes = q ? 16 : 8, nl = bytes / (1 << esz);
  for (int l = 0; l < nl; l++) {
    if (esz == 3) {
      vf64_u a,b,c; a.u=lane_get(bn,3,l); b.u=lane_get(bm,3,l); c.u=lane_get(bd,3,l);
      c.d = sub ? c.d - a.d*b.d : c.d + a.d*b.d; lane_put(bd,3,l,c.u);
    } else {
      vf32_u a,b,c; a.u=(u32)lane_get(bn,2,l); b.u=(u32)lane_get(bm,2,l); c.u=(u32)lane_get(bd,2,l);
      c.f = sub ? c.f - a.f*b.f : c.f + a.f*b.f; lane_put(bd,2,l,c.u);
    }
  }
  if (!q) { bd[8]=bd[9]=bd[10]=bd[11]=bd[12]=bd[13]=bd[14]=bd[15]=0; }
  vreg_put(vm, d, bd);
  return 7;
}

/* ================================================================
 * OP_V2S 0x5C — 两寄存器 misc: [op][vd][vn][esz][u][opc][q] 7B
 * ================================================================ */
static inline u32 h_v2s(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  int esz = vm->bc[vm->pc + 3] & 3, U = vm->bc[vm->pc + 4] & 1;
  u8 opc = vm->bc[vm->pc + 5], q = vm->bc[vm->pc + 6] & 1;
  u8 bn[16], br[16]; for (int i=0;i<16;i++) br[i]=0;
  vreg_get(vm, n, bn);
  int bytes = q ? 16 : 8, sz = 1 << esz, nl = bytes / sz;
  for (int l = 0; l < nl; l++) {
    u64 a = lane_get(bn, esz, l), r = 0;
    switch (opc) {
      case 0: r = (u64)(-(i64)a); break;                 /* neg */
      case 1: { i64 s = sext(a,esz); r = (u64)(s<0?-s:s); } break; /* abs */
      case 2: r = ~a; break;                             /* not */
      case 7: { /* rbit (byte-wise) */
        for (int bi=0; bi<sz; bi++){ u8 x=(u8)(a>>(bi*8)),y=0; for(int k=0;k<8;k++) if(x&(1<<k)) y|=(1<<(7-k)); r|=(u64)y<<(bi*8);} } break;
      case 32: { /* fneg */ if(esz==3){vf64_u t;t.u=a;t.d=-t.d;r=t.u;}else{vf32_u t;t.u=(u32)a;t.f=-t.f;r=t.u;} } break;
      case 33: { /* fabs */ if(esz==3){vf64_u t;t.u=a;t.d=t.d<0?-t.d:t.d;r=t.u;}else{vf32_u t;t.u=(u32)a;t.f=t.f<0?-t.f:t.f;r=t.u;} } break;
      case 34: { /* fsqrt */ if(esz==3){vf64_u t;t.u=a;t.d=__builtin_sqrt(t.d);r=t.u;}else{vf32_u t;t.u=(u32)a;t.f=__builtin_sqrtf(t.f);r=t.u;} } break;
      case 40: { /* scvtf */ if(esz==3){vf64_u t;t.d=(double)(i64)a;r=t.u;}else{vf32_u t;t.f=(float)(i32)(u32)a;r=t.u;} } break;
      case 41: { /* ucvtf */ if(esz==3){vf64_u t;t.d=(double)a;r=t.u;}else{vf32_u t;t.f=(float)(u32)a;r=t.u;} } break;
      case 42: { /* fcvtzs */ if(esz==3){vf64_u t;t.u=a;r=(u64)(i64)t.d;}else{vf32_u t;t.u=(u32)a;r=(u64)(u32)(i32)t.f;} } break;
      case 43: { /* fcvtzu */ if(esz==3){vf64_u t;t.u=a;r=(u64)t.d;}else{vf32_u t;t.u=(u32)a;r=(u64)(u32)t.f;} } break;
      default: r = a; break;
    }
    lane_put(br, esz, l, r);
  }
  vreg_put(vm, d, br);
  return 7;
}

/* ================================================================
 * OP_VDUPE 0x5D — dup Vd, Vn[idx]  [op][vd][vn][esz][idx][q] 6B
 * OP_VDUPG 0x5E — dup Vd, Rn        [op][vd][rn][esz][q] 5B
 * ================================================================ */
static inline u32 h_vdupe(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc+1], n = vm->bc[vm->pc+2];
  int esz = vm->bc[vm->pc+3]&3, idx = vm->bc[vm->pc+4], q = vm->bc[vm->pc+5]&1;
  u8 bn[16], br[16]; for(int i=0;i<16;i++) br[i]=0; vreg_get(vm,n,bn);
  u64 v = lane_get(bn, esz, idx);
  int nl = (q?16:8) / (1<<esz);
  for (int l=0;l<nl;l++) lane_put(br, esz, l, v);
  vreg_put(vm, d, br); return 6;
}
static inline u32 h_vdupg(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc+1], n = vm->bc[vm->pc+2];
  int esz = vm->bc[vm->pc+3]&3, q = vm->bc[vm->pc+4]&1;
  u8 br[16]; for(int i=0;i<16;i++) br[i]=0;
  u64 v = vm->R[n & 31];
  int nl = (q?16:8) / (1<<esz);
  for (int l=0;l<nl;l++) lane_put(br, esz, l, v);
  vreg_put(vm, d, br); return 5;
}

/* ================================================================
 * OP_VINSE 0x5F — ins Vd[didx], Vn[sidx]  [op][vd][vn][esz][didx][sidx] 6B
 * OP_VINSG 0x60 — ins Vd[didx], Rn         [op][vd][rn][esz][didx] 5B
 * ================================================================ */
static inline u32 h_vinse(vm_ctx_t *vm) {
  u8 d=vm->bc[vm->pc+1], n=vm->bc[vm->pc+2];
  int esz=vm->bc[vm->pc+3]&3, didx=vm->bc[vm->pc+4], sidx=vm->bc[vm->pc+5];
  u8 bd[16], bn[16]; vreg_get(vm,d,bd); vreg_get(vm,n,bn);
  lane_put(bd, esz, didx, lane_get(bn, esz, sidx));
  vreg_put(vm, d, bd); return 6;
}
static inline u32 h_vinsg(vm_ctx_t *vm) {
  u8 d=vm->bc[vm->pc+1], n=vm->bc[vm->pc+2];
  int esz=vm->bc[vm->pc+3]&3, didx=vm->bc[vm->pc+4];
  u8 bd[16]; vreg_get(vm,d,bd);
  lane_put(bd, esz, didx, vm->R[n & 31]);
  vreg_put(vm, d, bd); return 5;
}

/* ================================================================
 * OP_VUMOV 0x61 — umov/smov Rd, Vn[idx]  [op][rd][vn][esz][idx][sgn] 6B
 * ================================================================ */
static inline u32 h_vumov(vm_ctx_t *vm) {
  u8 d=vm->bc[vm->pc+1], n=vm->bc[vm->pc+2];
  int esz=vm->bc[vm->pc+3]&3, idx=vm->bc[vm->pc+4], sgn=vm->bc[vm->pc+5]&1;
  u8 bn[16]; vreg_get(vm,n,bn);
  u64 v = lane_get(bn, esz, idx);
  vm->R[d & 31] = sgn ? (u64)sext(v, esz) : v;
  return 6;
}

/* ================================================================
 * OP_VEXT 0x62 — ext Vd, Vn, Vm, #idx(byte)  [op][vd][vn][vm][idx][q] 6B
 * ================================================================ */
static inline u32 h_vext(vm_ctx_t *vm) {
  u8 d=vm->bc[vm->pc+1], n=vm->bc[vm->pc+2], m=vm->bc[vm->pc+3];
  int idx=vm->bc[vm->pc+4], q=vm->bc[vm->pc+5]&1;
  u8 bn[16], bm[16], br[16]; for(int i=0;i<16;i++) br[i]=0;
  vreg_get(vm,n,bn); vreg_get(vm,m,bm);
  int bytes = q?16:8;
  for (int i=0;i<bytes;i++) br[i] = (idx+i < bytes) ? bn[idx+i] : bm[idx+i-bytes];
  vreg_put(vm, d, br); return 6;
}

/* ================================================================
 * OP_VPERM 0x66 — zip/uzp/trn  [op][vd][vn][vm][esz][kind][q] 7B
 *   kind: 0=zip1 1=zip2 2=uzp1 3=uzp2 4=trn1 5=trn2
 * ================================================================ */
static inline u32 h_vperm(vm_ctx_t *vm) {
  u8 d=vm->bc[vm->pc+1], n=vm->bc[vm->pc+2], m=vm->bc[vm->pc+3];
  int esz=vm->bc[vm->pc+4]&3, kind=vm->bc[vm->pc+5], q=vm->bc[vm->pc+6]&1;
  u8 bn[16], bm[16], br[16]; for(int i=0;i<16;i++) br[i]=0;
  vreg_get(vm,n,bn); vreg_get(vm,m,bm);
  int bytes=q?16:8, sz=1<<esz, nl=bytes/sz;
  switch (kind) {
    case 0: case 1: { /* zip1/zip2 */
      int base = (kind==1) ? nl/2 : 0;
      for (int l=0; l<nl/2; l++) {
        lane_put(br, esz, 2*l,   lane_get(bn, esz, base+l));
        lane_put(br, esz, 2*l+1, lane_get(bm, esz, base+l));
      }
    } break;
    case 2: case 3: { /* uzp1/uzp2 */
      int off = (kind==3) ? 1 : 0;
      for (int l=0; l<nl; l++) {
        if (l < nl/2) lane_put(br, esz, l, lane_get(bn, esz, 2*l+off));
        else          lane_put(br, esz, l, lane_get(bm, esz, 2*(l-nl/2)+off));
      }
    } break;
    case 4: case 5: { /* trn1/trn2 */
      int off = (kind==5) ? 1 : 0;
      for (int l=0; l<nl/2; l++) {
        lane_put(br, esz, 2*l,   lane_get(bn, esz, 2*l+off));
        lane_put(br, esz, 2*l+1, lane_get(bm, esz, 2*l+off));
      }
    } break;
    default: break;
  }
  vreg_put(vm, d, br); return 7;
}

#endif /* H_VEC_H */

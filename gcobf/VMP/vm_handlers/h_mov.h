/*
 * h_mov.h — 数据移动指令 handler
 *
 * MOV Xd, #imm64    | MOV Wd, #imm32    | MOV Xd, Xn
 */
#ifndef H_MOV_H
#define H_MOV_H

#include "../vm_decode.h"
#include "../vm_types.h"


/* MOV Xd, #imm64   [10B: op | d | imm64] */
static inline u32 h_mov_imm(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1];
  vm->R[d & 31] = rd64(&vm->bc[vm->pc + 2]);
  return 10;
}

/* MOV Wd, #imm32   [6B: op | d | imm32]  (零扩展到 64 位) */
static inline u32 h_mov_imm32(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1];
  vm->R[d & 31] = (u64)rd32(&vm->bc[vm->pc + 2]);
  return 6;
}

/* MOV Xd, Xn       [3B: op | d | n] */
static inline u32 h_mov_reg(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1], n = vm->bc[vm->pc + 2];
  vm->R[d & 31] = vm->R[n & 31];
  return 3;
}


/* MOVK Xd, #imm16, LSL #(16*hw)   [5B: op | d | imm16 | hw] */
static inline u32 h_movk(vm_ctx_t *vm) {
  u8 d = vm->bc[vm->pc + 1];
  u16 imm = rd16(&vm->bc[vm->pc + 2]);
  u8 hw = vm->bc[vm->pc + 4] & 3;
  u64 sh = 16ULL * hw;
  vm->R[d & 31] = (vm->R[d & 31] & ~(0xFFFFULL << sh)) | ((u64)imm << sh);
  return 5;
}

#endif /* H_MOV_H */

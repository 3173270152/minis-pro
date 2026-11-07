/*
 * h_callstack.h — 带栈参数的函数调用（naked 版 v2）
 *
 * 修正：fn 必须放在 callee-saved 寄存器（x23），不能被参数载入覆盖。
 *
 * call_thunk(fn=x0, regs=x1, src=x2, depth=x3) -> x0
 */
#ifndef H_CALLSTACK_H
#define H_CALLSTACK_H

#include "../vm_types.h"

#define CALL_THUNK_ASM  \
  "  sub  sp, sp, #96            \n"  /* 本地帧 */ \
  "  stp  x19, x20, [sp, #0]    \n" \
  "  stp  x21, x22, [sp, #16]   \n" \
  "  stp  x23, x24, [sp, #32]   \n" \
  "  str  x30, [sp, #48]        \n" \
  "  mov  x19, sp               \n"  /* 本帧 sp */ \
  "  mov  x20, x1               \n"  /* regs */ \
  "  mov  x21, x2               \n"  /* src */ \
  "  mov  x22, x3               \n"  /* depth */ \
  "  mov  x23, x0               \n"  /* ★ fn 存 callee-saved */ \
  /* ---- 搬虚拟栈参数到真实栈 ---- */ \
  "  and  x9, x22, #~15         \n" \
  "  add  x9, x9, #16           \n" \
  "  sub  sp, sp, x9            \n" \
  "  mov  x10, sp               \n" \
  "  mov  x11, x21              \n" \
  "  mov  x12, x22              \n" \
  "  cbz  x12, 2f               \n" \
  "1:                           \n" \
  "  ldr  x13, [x11], #8        \n" \
  "  str  x13, [x10], #8        \n" \
  "  subs x12, x12, #8          \n" \
  "  b.ne 1b                    \n" \
  "2:                           \n" \
  /* ---- 载入 8 个寄存器参数 ---- */ \
  "  ldp  x0, x1, [x20, #0]     \n" \
  "  ldp  x2, x3, [x20, #16]    \n" \
  "  ldp  x4, x5, [x20, #32]    \n" \
  "  ldp  x6, x7, [x20, #48]    \n" \
  /* ---- 调用 ---- */ \
  "  blr  x23                   \n" \
  /* ---- 恢复 ---- */ \
  "  mov  sp, x19               \n" \
  "  ldp  x19, x20, [sp, #0]    \n" \
  "  ldp  x21, x22, [sp, #16]   \n" \
  "  ldp  x23, x24, [sp, #32]   \n" \
  "  ldr  x30, [sp, #48]        \n" \
  "  add  sp, sp, #96           \n" \
  "  ret                        \n"

__attribute__((naked, noinline, section("__TEXT,__text2")))
static u64 call_thunk(native_fn_t fn, const u64 *regs, const void *src, u64 depth) {
  __asm__ volatile(CALL_THUNK_ASM);
}

static inline u64 call_fn_with_stack(native_fn_t fn, const u64 *regs,
                                     const void *src, u64 depth) {
  return call_thunk(fn, regs, src, depth);
}

#endif /* H_CALLSTACK_H */

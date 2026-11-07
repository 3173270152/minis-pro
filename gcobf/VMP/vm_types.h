/*
 * vm_types.h — VM 类型定义 + CPU 上下文结构体
 *
 * 所有 VM 状态封装在 vm_ctx_t 中，方便传递和扩展。
 */
#ifndef VM_TYPES_H
#define VM_TYPES_H

/* ---- 基础类型 ---- */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef int i32;
typedef long long i64;
typedef short i16;

/* ---- VM 配置常量 ---- */
/* ★ R[0..30] = X0..X30, R[31] = SP —— 必须 32 及以上才装得下 SP，
   原来定义成 32 时 R[31] 正好越界一档（写坏 pgc/eval 等后续字段） */
#define VM_REG_COUNT 33        /* X0-X30 + SP(R31) */
#define VM_CS_MIN 19           /* callee-saved 起始: X19 */
#define VM_CS_MAX 28           /* callee-saved 结束: X28 */
#define VM_STACK_SIZE 32       /* PUSH/POP 操作栈深度 */
#define VM_EVAL_STACK_SIZE 256 /* 栈机器操作栈深度 */
#define VM_MEM_STACK 16384     /* 内存栈 (SP 指向的空间, 16KB) */
#define VM_BYTECODE_MAX 65536  /* 最大字节码长度 (64KB, 含映射表) */
#define VM_SIMD_BUF 64         /* SIMD 临时缓冲大小 */

/* ---- 标志位 (NZCV 简化) ---- */
#define FL_ZERO 1  /* Z: 结果为零 */
#define FL_SIGN 2  /* N: 有符号小于 */
#define FL_CARRY 4 /* C: 无符号小于 */

/* ---- 原生函数指针类型 ---- */
typedef u64 (*native_fn_t)(u64, u64, u64, u64, u64, u64, u64, u64);

/* ---- BR 间接跳转映射表条目 ---- */
typedef struct {
  u32 arm64_off; /* ARM64 函数内偏移 */
  u32 vm_off;    /* 对应的 VM 字节码偏移 */
} addr_map_entry_t;

/* ---- VM CPU 上下文 ---- */
typedef struct {
  /* 寄存器文件: R[0]-R[30] = X0-X30, R[31] = SP */
  u64 R[VM_REG_COUNT];

  /* FP/SIMD 寄存器: 每个 V[i] 占 128 位 = V[2i](低64) + V[2i+1](高64) */
  u64 V[64];

  /* 条件标志 */
  u32 FL;

  /* 虚拟程序计数器 */
  u32 pc;

  /* 字节码 (解密后) */
  u8 *bc;
  u32 bc_len;

  /* image base（adrp/call_lit 用；不占用 R28，避免覆盖原函数 x28） */
  u64 image_base;

  /* PUSH/POP 操作栈 (旧 register-based 兼容) */
  u64 stk[VM_STACK_SIZE];
  int sp;

  /* 栈机器操作栈 (Stack Machine eval stack) */
  u64 eval_stk[VM_EVAL_STACK_SIZE];
  int eval_sp; /* 栈顶指针, -1 = 空 */

  /* 内存栈 (R[31] 指向这里的末尾) */
  u8 vm_stk[VM_MEM_STACK];

  /* SIMD 临时缓冲 */
  u8 vtmp[VM_SIMD_BUF];

  /* BR 间接跳转支持 */
  u64 func_addr;              /* 被保护函数的原始起始地址 */
  u32 func_size;              /* 被保护函数的大小 */

  /* ★ v-float/v-sp: 调用方真实 SP 快照（args[22]）。
     供需要「取栈上地址」(ADD Xn, SP, #imm) 的 handler 使用；
     不覆盖 R[31]（R[31] 仍指向 VM 自己的 vm_stk，维持栈机模型）。 */
  u64 caller_sp;
  addr_map_entry_t *addr_map; /* ARM64偏移→VM偏移 映射表 */
  u32 map_count;              /* 映射表条目数 */

  /* OpcodeCryptor: 逐指令 opcode 加密 */
  u32 oc_key; /* opcode 加密密钥 (4B, 从 trailer 读取) */

  /* PC 反向遍历 */
  u8 reverse; /* 1=反向执行 (pc 递减), 0=正向 */

  /* 页权限缓存 (h_mem.h 的 vm_page_prot 用; 每项 16B, 共 256B) */
  struct { u64 page; u32 prot; u32 _pad; } pgc[16];
} vm_ctx_t;

/* ---- SP 栈边界检查 ---- */
/* 检查地址是否在 vm_stk 范围内 (仅对 SP 相关访问使用) */
#define VM_STK_LO(vm) ((u64)(vm)->vm_stk)
#define VM_STK_HI(vm) ((u64)(vm)->vm_stk + VM_MEM_STACK)

/* ---- VM 初始化 ---- */
static inline void vm_ctx_init(vm_ctx_t *vm, u64 *args, u8 *bytecode, u32 len, u64 func_base) {
  /* 清零所有寄存器 */
  for (int i = 0; i < VM_REG_COUNT; i++)
    vm->R[i] = 0;
  for (int i = 0; i < 64; i++)
    vm->V[i] = 0;

  /* 从 args 指针恢复参数寄存器 X0-X7 */
  for (int i = 0; i < 8; i++)
    vm->R[i] = args[i];

  /* ★ callee-saved 通用寄存器 X19-X28: 必须从调用方快照恢复，
     否则 VM 内部拿到的初值是 0，原函数依赖的值全部丢失
     （历史上 x28 被误当 image base 崩溃就是这个根源的另一面） */
  for (int i = VM_CS_MIN; i <= VM_CS_MAX; i++)
    vm->R[i] = args[11 + (i - VM_CS_MIN)];

  vm->R[29] = args[8]; /* X29 = caller FP */
  vm->R[30] = args[9]; /* X30 = caller LR */
  vm->image_base = args[20]; /* image base（20/21 避开 x19/x20 快照）*/
  vm->func_addr = func_base;  /* ★ v3.2: 字节码偏移的相对基址 */

  /* ★ v-float: 从快照恢复浮点/SIMD 参数 q0-q7（args[24..39]，16×u64）。
     V[2n]=qn 低64, V[2n+1]=qn 高64；即 V[0..15] 依次对应 q0..q7。
     修复 STATUS 缺陷 B「浮点参数完全丢失」。无浮点参数的函数这些值不会被读到。 */
  for (int i = 0; i < 16; i++)
    vm->V[i] = args[24 + i];
  /* ★ v-sp: 调用方真实 SP（args[22]）。不改 R[31] 的 VM 栈语义。 */
  vm->caller_sp = args[22];

  /* SP 指向内存栈顶 */
  vm->R[31] = (u64)&vm->vm_stk[VM_MEM_STACK];

  /* 字节码 */
  vm->bc = bytecode;
  vm->bc_len = len;

  /* 状态初始化 */
  vm->FL = 0;
  vm->pc = 0;
  vm->sp = 0;
  vm->eval_sp = -1; /* 栈机器操作栈初始为空 */

  /* BR 间接跳转映射表：默认无 */
  vm->func_addr = 0;
  vm->func_size = 0;
  vm->addr_map = 0;
  vm->map_count = 0;

  /* OpcodeCryptor: 默认无加密 (key=0 时解密为恒等) */
  vm->oc_key = 0;

  /* PC 反向遍历: 默认正向 */
  vm->reverse = 0;

  /* 页权限缓存清零 (page=0 表示空槽) */
  for (int i = 0; i < 16; i++) { vm->pgc[i].page = 0; vm->pgc[i].prot = 0; }
}

#endif /* VM_TYPES_H */

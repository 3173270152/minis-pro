/*
 * vm_interp.c — 模块化 VM 解释器 (Linux/ARM64 PIC blob)
 *
 * 架构:
 *   vm_types.h       → 类型 + vm_ctx_t 结构体
 *   vm_opcodes.h     → 操作码定义
 *   vm_decode.h      → 字节码读取工具
 *   vm_handlers/*.h  → 分模块指令 handler
 *
 * 编译 (交叉编译为 blob):
 *   aarch64-linux-gnu-gcc -c -Os -mcmodel=tiny -fno-stack-protector \
 *     -fno-builtin -nostdlib -march=armv8-a vm_interp.c -o vm_interp.o
 */

/* ★ v-hardening: 默认打开抗逆向加固(以前要手动 -D,实际从没开)。
 *   VM_INDIRECT_DISPATCH: handler 走栈上函数指针表间接调用 → 断 IDA 交叉引用
 *   VM_FUNC_SPLIT:        handler 散到不同 __TEXT 子节 → IDA 识别成一堆独立函数
 *   要关只需编译时 -DVM_NO_HARDENING。*/
#ifndef VM_NO_HARDENING
  #ifndef VM_INDIRECT_DISPATCH
    #define VM_INDIRECT_DISPATCH 1
  #endif
  #ifndef VM_FUNC_SPLIT
    #define VM_FUNC_SPLIT 1
  #endif
#endif

/* ---- 基础设施 ---- */

#include <stdio.h>
#include <stdlib.h>

/* VMDBG: 调试日志 → $HOME/Documents/vmp.log
 * noinline 保证函数调用不被 -Os 优化掉（空宏会导致功能失效） */
#include <stdarg.h>
__attribute__((noinline)) static void _vmdbg_real(const char *fmt, ...) {
  const char *h = getenv("HOME");
  if (!h) return;
  char p[512];
  snprintf(p, sizeof(p), "%s/Documents/vmp.log", h);
  FILE *f = fopen(p, "a");
  if (!f) return;
  va_list ap; va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}
/* ★ 生产版关闭 VM 调试日志：每帧写文件会产生数百 MB 日志并严重拖慢性能 */
#define VMDBG(...) do { } while (0)

/* ★ VM 执行容错：某个函数的字节码跑崩了，就永久降级为直接调用原函数 */
#include <setjmp.h>
#include <signal.h>
sigjmp_buf g_vm_jb;
volatile int g_vm_armed = 0;
volatile int g_vm_failed = 0;
/* 统一 handler 由 VMPHooks.xm 的 ctor 安装（同时处理 hook 阶段和 VM 阶段） */

#include "vm_decode.h"
#include "vm_opcodes.h"
#include <stdio.h>
#include <stdlib.h>
#include "vm_types.h"

/* ---- 指令 Handler 模块 ---- */
#include "vm_handlers/h_alu.h" /* ADD/SUB/MUL/XOR/AND/OR/SHL/SHR/ASR/NOT/ROR + _IMM */
#include "vm_handlers/h_branch.h" /* JMP/JE/JNE/JL/JGE/JGT/JLE/JB/JAE */
#include "vm_handlers/h_cmp.h"    /* CMP, CMP_IMM */
#include "vm_handlers/h_mem.h"    /* LOAD/STORE 8/32/64 */
#include "vm_handlers/h_mov.h"    /* MOV_IMM, MOV_IMM32, MOV_REG */
#include "vm_handlers/h_stack.h"  /* PUSH, POP */
#include "vm_handlers/h_stack_ops.h" /* 栈机器操作 handler (VLOAD/VSTORE/VADD...) */
#include "vm_handlers/h_system.h"
#include "vm_handlers/h_fp.h" /* NOP, CALL_NAT, BR_REG, VLD16, VST16 */
#include "vm_handlers/h_vec.h" /* v-neon: NEON/AdvSIMD 向量指令 */
#include "vm_crc.h"            /* v-integ: 字节码完整性 CRC32 自校验 */


/* ---- 间接 Dispatch 跳转表 (条件编译) ---- */
#ifdef VM_INDIRECT_DISPATCH
#include "vm_dispatch.h"
#endif

/* ---- Token 化入口 (条件编译) ---- */
/* TOKEN_ONLY: Token 入口始终编译 */
#include "vm_token.h"

/* VMDBG moved up */

/* ---- 内存分配: 作为正常 tweak 链接时可以链 libSystem ---- */
extern void *malloc(unsigned long size);
extern void free(void *ptr);
#define vm_alloc(n) malloc((unsigned long)(n))
#define vm_free(p)  do { if (p) free((void*)(p)); } while (0)



/* 无外部依赖: 全部用栈上缓冲 (__text2 会被单独抠出来塞进 padding) */
#define GCOBF_BC_STACK 4096

/*
 * vm_entry — VM 解释器入口
 *
 * 参数:
 *   args    : 指向保存的 X0-X7, callerFP, callerLR (共10个u64)
 *   enc_bc  : XOR 加密的字节码
 *   bc_len  : 字节码长度
 *   xor_key : XOR 解密密钥
 *
 * 返回: R[0] (模拟 X0 返回值)
 */
__attribute__((section("__TEXT,__text2"))) u64 vm_entry(u64 *args, u8 *enc_bc,
                                                     u32 bc_len, u8 xor_key);

/* ================================================================
 * Token 化入口 (条件编译)
 *
 * Token trampoline (3 条指令):
 *   MOV  W16, #token_lo16
 *   MOVK W16, #token_hi16, LSL#16
 *   B    vm_entry_token
 *
 * X16 (IP0) 传递 token，X0-X7 保持调用方原始参数不变。
 * vm_entry_token_asm 负责保存寄存器并调用 vm_entry_token_inner。
 * ================================================================ */
/* TOKEN_ONLY: Token 入口始终编译 */

/* Packer 在 payload 中 patch 此变量为 token 描述符表的 VA */
__attribute__((section("__DATA,__data2"), used)) volatile u64 _token_table_va = 0;

/* 内部 C 函数: 解码 token 并调用 vm_entry */
__attribute__((noinline, section("__TEXT,__text2"))) u64
vm_entry_token_inner(u64 *args, u32 token) {
  u8 xor_key = (u8)TOKEN_XOR_KEY(token);
  u32 func_id = TOKEN_FUNC_ID(token);

  /* PIE 兼容: _token_table_va 存储的是相对于自身地址的偏移
   * 用 ADR 获取 _token_table_va 的运行时地址 (PC-relative, ±1MB)
   * 然后加上偏移得到 token 描述符表的实际地址 */
  /* Mach-O 不支持 adr 到任意符号的 fixup, 直接用 C 取地址,
     编译器会生成 adrp/add (@PAGE/@PAGEOFF) */
  u64 self_va = (u64)(unsigned long)&_token_table_va;
  u64 tbl_off = *(volatile u64 *)&_token_table_va;
  if (__builtin_expect(tbl_off == 0, 0))
    return 0; /* 表未初始化, 安全退出 */

  token_desc_t *table = (token_desc_t *)(self_va + tbl_off);
  /* bc_off 也是相对于 _token_table_va 的偏移 */
  u8 *enc_bc = (u8 *)(self_va + table[func_id].bc_off);
  u32 bc_len = table[func_id].bc_len;

  if (__builtin_expect(enc_bc == (u8 *)self_va || bc_len == 0, 0))
    return 0; /* 无效条目, 安全退出 */

  return vm_entry(args, enc_bc, bc_len, xor_key);
}

/* Naked 汇编入口: 保存调用方寄存器, 调用 C 内部函数 */
__attribute__((naked, section("__TEXT,__text2"), used)) void vm_entry_token(void) {
  __asm__ volatile(
      /* ★ v-float/v-threadsafe 统一布局（0x180 帧）：
       *   [0..7]=X0-X7 [8]=X29 [9]=X30 [10]=image_base [11..20]=X19-X28
       *   [22]=caller SP  [23]=FP 返回出参  [24..39]=q0-q7
       *   帧必须覆盖到 args[39]=0x138，否则 vm_ctx_init 读 q 槽会越界。
       *   另：原版未在 bl 前后保存/恢复自身 X30 —— 会导致 ret 跳回错误地址，
       *   说明 token 入口此前未实际启用。这里按正确写法补上（需上机验证）。
       *   token 从 X16 传入，故用 X17 抓 caller SP。 */
      "mov  x17, sp\n"
      "sub  sp, sp, #0x180\n"
      "stp  x0,  x1, [sp, #0x00]\n"
      "stp  x2,  x3, [sp, #0x10]\n"
      "stp  x4,  x5, [sp, #0x20]\n"
      "stp  x6,  x7, [sp, #0x30]\n"
      "stp  x29, x30, [sp, #0x40]\n"
      "str  x10, [sp, #0x50]\n"        /* args[10] = image base */
      "stp  x19, x20, [sp, #0x58]\n"
      "stp  x21, x22, [sp, #0x68]\n"
      "stp  x23, x24, [sp, #0x78]\n"
      "stp  x25, x26, [sp, #0x88]\n"
      "stp  x27, x28, [sp, #0x98]\n"
      "str  x17, [sp, #0xB0]\n"        /* args[22] = caller SP */
      "stp  q0,  q1,  [sp, #0xC0]\n"   /* args[24..27] = q0,q1 */
      "stp  q2,  q3,  [sp, #0xE0]\n"   /* args[28..31] = q2,q3 */
      "stp  q4,  q5,  [sp, #0x100]\n"  /* args[32..35] = q4,q5 */
      "stp  q6,  q7,  [sp, #0x120]\n"  /* args[36..39] = q6,q7 */
      "str  x30, [sp, #0x170]\n"       /* 保存自身 LR（bl 会覆盖）*/
      "mov  x0, sp\n"                  /* X0 = args 指针 */
      "mov  w1, w16\n"                 /* X1 = token (从 X16/IP0 传入) */
      "bl   _vm_entry_token_inner\n"    /* 调用 C 内部函数 */
      "ldr  d0, [sp, #0xB8]\n"         /* args[23] → d0：浮点返回值 */
      "ldr  x30, [sp, #0x170]\n"       /* 恢复自身 LR */
      "add  sp, sp, #0x180\n"
      "ret\n"
  );
}

/* end TOKEN_ONLY */

/* ★ VMP 自保护: 反调试检查点, 由 AntiDebug/anti_debug_pro.c 提供。
 *   weak 声明 -> 没链接反调试模块时自动退化成空, 不影响 VM 单独构建。*/
extern unsigned adbg_checkpoint(void) __attribute__((weak));

/* ---- vm_entry 实现 ---- */
__attribute__((section("__TEXT,__text2"))) u64 vm_entry(u64 *args, u8 *enc_bc,
                                                     u32 bc_len, u8 xor_key) {
  u64 ret = 0;
  u64 r0 = 0;
  VMDBG("[vm] ENTER bc_len=%u xor=%u", bc_len, xor_key);
  args[4] = 0x454E5452ULL;
  /* ★ VMP 自保护: 所有被保护函数都走这条路径, 每 16 次调用检查一次反调试。
   *   放在这里而不是 dispatch 循环: 粒度是"函数调用", 开销可预期。*/
  if (adbg_checkpoint) (void)adbg_checkpoint();

  /* ---- 1. 字节码缓冲 (堆分配) ---- */
  if (bc_len > VM_BYTECODE_MAX) { VMDBG("[vm] bc_len too big"); args[5] = 0x1111; return 0; }
  u8 *bc_buf = (u8 *)vm_alloc(VM_BYTECODE_MAX);
  if (!bc_buf) { args[5] = 0x2222; return 0; }
  args[5] = 0x2001;
  VMDBG("[vm] bc_buf ok");

  /* ---- 1b. XOR 解密 (8 字节加宽, ~8x 加速) ---- */
  u64 xk8 = (u64)xor_key;
  xk8 |= xk8 << 8;
  xk8 |= xk8 << 16;
  xk8 |= xk8 << 32;
  {
    u32 n8 = bc_len >> 3;
    u64 *d8 = (u64 *)bc_buf;
    const u64 *s8 = (const u64 *)enc_bc;
    for (u32 i = 0; i < n8; i++)
      d8[i] = s8[i] ^ xk8;
    for (u32 i = n8 << 3; i < bc_len; i++)
      bc_buf[i] = enc_bc[i] ^ xor_key;
  }

  /* ---- 2b. 初始化 VM 上下文 (堆分配, 避免 26KB 栈帧越过 guard page) ---- */
  vm_ctx_t *vm = (vm_ctx_t *)vm_alloc(sizeof(vm_ctx_t));
  if (!vm) { args[5] = 0x3333; vm_free(bc_buf); return 0; }
  args[5] = 0x3001;
  VMDBG("[vm] ctx ok");
  vm_ctx_init(vm, args, bc_buf, bc_len, args[21]);  /* args[21] = 被保护函数地址（10/11 已被 x19/x20 快照占用）*/
  args[5] = 0x4001;
  VMDBG("[vm] init done, pc=%u len=%u", vm->pc, vm->bc_len);

  /* ---- 2c. 解析字节码尾部 trailer ---- */
  /* 尾部格式 (从末尾向前剥离):
   *   [...bytecode...][BR map entries][reverse(1B)][oc_key(4B)]
   *                    [map_count:u32][func_addr:u64][func_size:u32]
   *
   * 剥离顺序: func_size(4B) → func_addr(8B) → map_count(4B)
   *           → oc_key(4B) → reverse(1B) → BR map entries
   * 固定 trailer 大小: 4+8+4+4+1 = 21B
   */
  /* ★ v-integ: trailer 扩到 25B, 末尾新增 bc_crc(4B) 完整性校验 */
  if (bc_len >= 25) { /* 最小 trailer: 25B */
    u32 trail_bc_crc    = rd32(&bc_buf[bc_len - 4]);
    u32 trail_func_size = rd32(&bc_buf[bc_len - 8]);
    u64 trail_func_addr = rd64(&bc_buf[bc_len - 16]);
    u32 trail_map_count = rd32(&bc_buf[bc_len - 20]);
    u32 trail_oc_key = rd32(&bc_buf[bc_len - 24]);
    u8 trail_reverse = bc_buf[bc_len - 25];
    u32 map_data_size =
        trail_map_count * 8 +
        25; /* +25 for reverse+oc_key+map_count+func_addr+func_size+bc_crc */

    /* 设置 OpcodeCryptor 密钥 + reverse 标志 */
    vm->oc_key = trail_oc_key;
    vm->reverse = trail_reverse;

    if (trail_func_addr != 0 && trail_map_count > 0 &&
        map_data_size <= bc_len) {
      vm->func_addr = trail_func_addr;
      vm->func_size = trail_func_size;
      vm->map_count = trail_map_count;
      vm->addr_map = (addr_map_entry_t *)&bc_buf[bc_len - map_data_size];
      vm->bc_len = bc_len - map_data_size; /* 实际字节码不含 trailer */

      /* 插入排序 addr_map (按 arm64_off 升序, 为二分查找准备) */
      /* 注: 使用字段级拷贝避免编译器生成隐式 memcpy (-nostdlib) */
      for (u32 j = 1; j < vm->map_count; j++) {
        u32 t_arm = vm->addr_map[j].arm64_off;
        u32 t_vm = vm->addr_map[j].vm_off;
        int k = (int)j - 1;
        while (k >= 0 && vm->addr_map[k].arm64_off > t_arm) {
          vm->addr_map[k + 1].arm64_off = vm->addr_map[k].arm64_off;
          vm->addr_map[k + 1].vm_off = vm->addr_map[k].vm_off;
          k--;
        }
        vm->addr_map[k + 1].arm64_off = t_arm;
        vm->addr_map[k + 1].vm_off = t_vm;
      }
    } else {
      /* 无 BR map: 只剥离 25B 固定 trailer */
      vm->bc_len = bc_len - 25;
    }

    /* ★ v-integ: 对 opcode 区做 CRC32, 与 trailer 中 bc_crc 比对。
     *   crc==0 = 不校验(兼容/关闭)。不匹配 → 不崩溃, 破坏 oc_key 使后续解密全错,
     *   静默算错结果(红队建议 #14: tamper 应算错而非明确崩溃信号)。 */
    if (trail_bc_crc != 0) {
      u32 got = crc32_calc(bc_buf, vm->bc_len);
      if (got != trail_bc_crc)
        vm->oc_key ^= (got ^ 0xA5A5A5A5u);
    }
  }

/* ---- OpcodeCryptor 解密宏 (两种模式共用) ---- */
/* ★ v-bcenc: 原来 (u8)(key ^ pc*C) 只用到 key 低 8 位 → oc_key 实际仅 8 位强度。
 * 改为按位置取 key 的第 (pc&3) 个字节，使 oc_key 成为真正的 32 位每函数密钥。
 * 加密侧(vmp.py translate)与此严格对称。key=0 时退化为原公开变换，兼容旧字节码。 */
#define OC_DECRYPT(pc, key) \
  ((u8)((((key) >> (((pc) & 3u) << 3)) & 0xFFu) ^ ((pc) * 0x9E3779B9u)))

#ifdef VM_INDIRECT_DISPATCH
  /* ================================================================
   * 间接 Dispatch 模式: 相对偏移跳转表 + 函数指针间接调用
   *
   * 替代 computed goto，使 IDA Pro 等静态分析工具
   * 无法追踪所有 handler 目标地址。
   * ================================================================ */

  /* ---- 运行时初始化跳转表 (栈上分配, RX blob 不可写 BSS) ---- */
  vm_handler_fn vm_jump_table[256];
  vm_init_jump_table(vm_jump_table);

  /* ---- PC 初始化: reverse 模式从 bc_len 开始 ---- */
  if (vm->reverse) {
    vm->pc = vm->bc_len;
  }

  /* ---- 间接 Dispatch 主循环 ---- */
  for (;;) {
    /* -- 反向/正向 PC 定位 -- */
    if (vm->reverse) {
      if (__builtin_expect((i64)vm->pc <= 0, 0))
        break;
      vm->pc--;
      if (__builtin_expect(vm->pc >= vm->bc_len, 0))
        break;
      u8 _sz = vm->bc[vm->pc];
      if (__builtin_expect(_sz > vm->pc, 0))
        break;
      vm->pc -= _sz;
    } else {
      if (__builtin_expect(vm->pc >= vm->bc_len, 0))
        break;
    }

    /* -- OpcodeCryptor 解密 -- */
    u8 _raw_op = vm->bc[vm->pc];
    u8 _dec_op = _raw_op ^ OC_DECRYPT(vm->pc, vm->oc_key);

    /* -- 指令大小校验 -- */
    u8 _isz = vm_insn_size(_dec_op);
    if (__builtin_expect(_isz == 0 || vm->pc + _isz > vm->bc_len, 0))
      break;

    /* -- 特殊处理: HALT / RET (不经过跳转表) -- */
    if (_dec_op == OP_HALT) {
      ret = vm->R[0];
      goto cleanup;
    }
    if (_dec_op == OP_RET) {
      u8 _r = vm->bc[vm->pc + 1];
      ret = vm->R[_r & 31];
      goto cleanup;
    }

    /* -- 间接 Dispatch: 直接从跳转表取函数指针调用 -- */
#ifdef VM_DEBUG_TRACE
    /* -- Debug trace: 输出 pc+op 到 stderr -- */
    {
      u8 _tbuf[16];
/* 内联计算十六进制字符 (避免 static 数据引用) */
#define _HX(n) ((u8)((n) < 10 ? '0' + (n) : 'A' + (n) - 10))
      _tbuf[0] = _HX((vm->pc >> 12) & 0xF);
      _tbuf[1] = _HX((vm->pc >> 8) & 0xF);
      _tbuf[2] = _HX((vm->pc >> 4) & 0xF);
      _tbuf[3] = _HX(vm->pc & 0xF);
      _tbuf[4] = ':';
      _tbuf[5] = _HX((_dec_op >> 4) & 0xF);
      _tbuf[6] = _HX(_dec_op & 0xF);
      _tbuf[7] = '\n';
#undef _HX
      register long _x8 __asm__("x8") = 64; /* __NR_write */
      register long _x0 __asm__("x0") = 2;  /* stderr */
      register long _x1 __asm__("x1") = (long)_tbuf;
      register long _x2 __asm__("x2") = 8;
      __asm__ volatile("svc #0"
                       : "+r"(_x0)
                       : "r"(_x8), "r"(_x1), "r"(_x2)
                       : "memory");
    }
#endif
    vm_handler_fn _handler = vm_jump_table[_dec_op];
    u32 _step = _handler(vm);

    /* -- 检查 HALT 哨兵 (wrap_unknown 等返回) -- */
    if (__builtin_expect(_step == VM_STEP_HALT, 0)) {
      ret = vm->R[0];
      goto cleanup;
    }

    /* -- 推进 PC -- */
    /* _step == 0: 分支 handler 已直接设置 pc, 不推进 */
    /* _step > 0 且非 reverse: 正常推进 */
    if (_step > 0 && !vm->reverse) {
      vm->pc += _step;
    }
  }

#else /* !VM_INDIRECT_DISPATCH */

  /* ================================================================
   * 原始 Computed Goto 模式 (保持不变)
   * ================================================================ */

  /* ---- 3. Computed goto 分发表 (替代 switch-case, ~20-30% 加速) ---- */
  /* GCC 扩展: &&label 获取标签地址, goto *ptr 跳转 */
  /* 注: 使用循环填充默认值避免 [0...255] 范围初始化生成隐式 memcpy */
  const void *dtab[256];
  for (int _i = 0; _i < 256; _i++)
    dtab[_i] = &&L_UNKNOWN;
  /* 系统 */
  dtab[OP_ADD_BASE] = &&L_ADD_BASE;
  dtab[OP_NOP] = &&L_NOP;
  dtab[OP_HALT] = &&L_HALT;
  dtab[OP_RET] = &&L_RET;
  /* 数据移动 */
  dtab[OP_MOV_IMM] = &&L_MOV_IMM;
  dtab[OP_MOV_IMM32] = &&L_MOV_IMM32;
  dtab[OP_FADD] = &&L_FADD;
  dtab[OP_FSUB] = &&L_FSUB;
  dtab[OP_FMUL] = &&L_FMUL;
  dtab[OP_FDIV] = &&L_FDIV;
  dtab[OP_FMOV_REG] = &&L_FMOV_REG;
  dtab[OP_FNEG] = &&L_FNEG;
  dtab[OP_FABS] = &&L_FABS;
  dtab[OP_FCVT] = &&L_FCVT;
  dtab[OP_SCVTF] = &&L_SCVTF;
  dtab[OP_UCVTF] = &&L_UCVTF;
  dtab[OP_FCVTZS] = &&L_FCVTZS;
  dtab[OP_FCVTZU] = &&L_FCVTZU;
  dtab[OP_FCMP] = &&L_FCMP;
  dtab[OP_LOAD_FP] = &&L_LOAD_FP;
  dtab[OP_STORE_FP] = &&L_STORE_FP;
  dtab[OP_FMOV_IMM] = &&L_FMOV_IMM;
  /* v-cov80: 浮点标量 + 浮点字面量加载 */
  dtab[OP_FMAX] = &&L_FMAX;
  dtab[OP_FMIN] = &&L_FMIN;
  dtab[OP_FSQRT] = &&L_FSQRT;
  dtab[OP_FRINT] = &&L_FRINT;
  dtab[OP_LOAD_LIT_FP] = &&L_LOAD_LIT_FP;
  /* v-neon: NEON/AdvSIMD */
  dtab[OP_VMOVI] = &&L_VMOVI;
  dtab[OP_VLDR]  = &&L_VLDR;
  dtab[OP_VSTR]  = &&L_VSTR;
  dtab[OP_V3S]   = &&L_V3S;
  dtab[OP_V2S]   = &&L_V2S;
  dtab[OP_VDUPE] = &&L_VDUPE;
  dtab[OP_VDUPG] = &&L_VDUPG;
  dtab[OP_VINSE] = &&L_VINSE;
  dtab[OP_VINSG] = &&L_VINSG;
  dtab[OP_VUMOV] = &&L_VUMOV;
  dtab[OP_VEXT]  = &&L_VEXT;
  dtab[OP_VPERM] = &&L_VPERM;
  dtab[OP_VFMA]  = &&L_VFMA;
  dtab[OP_FMADD] = &&L_FMADD;
  dtab[OP_FCMP_Z] = &&L_FCMP_Z;
  dtab[OP_FCSEL] = &&L_FCSEL;
  dtab[OP_UBFM] = &&L_UBFM;
  dtab[OP_MOVK] = &&L_MOVK;
  dtab[OP_MOV_REG] = &&L_MOV_REG;
  /* 内存 */
  dtab[OP_LOAD_LIT8] = &&L_LOAD_LIT8;
  dtab[OP_LOAD_LIT16] = &&L_LOAD_LIT16;
  dtab[OP_LOAD_LIT32] = &&L_LOAD_LIT32;
  dtab[OP_LOAD_LIT64] = &&L_LOAD_LIT64;
  dtab[OP_LOAD8] = &&L_LOAD8;
  dtab[OP_LOAD32] = &&L_LOAD32;
  dtab[OP_LOAD64] = &&L_LOAD64;
  dtab[OP_STORE8] = &&L_STORE8;
  dtab[OP_STORE32] = &&L_STORE32;
  dtab[OP_STORE64] = &&L_STORE64;
  dtab[OP_LOAD16] = &&L_LOAD16;
  dtab[OP_STORE16] = &&L_STORE16;
  /* ALU 三寄存器 */
  dtab[OP_ADD] = &&L_ADD;
  dtab[OP_SUB] = &&L_SUB;
  dtab[OP_MUL] = &&L_MUL;
  dtab[OP_XOR] = &&L_XOR;
  dtab[OP_AND] = &&L_AND;
  dtab[OP_OR] = &&L_OR;
  dtab[OP_SHL] = &&L_SHL;
  dtab[OP_SHR] = &&L_SHR;
  dtab[OP_ASR] = &&L_ASR;
  dtab[OP_NOT] = &&L_NOT;
  dtab[OP_ROR] = &&L_ROR;
  dtab[OP_UMULH] = &&L_UMULH;
  /* ALU 立即数 */
  dtab[OP_ADD_IMM] = &&L_ADD_IMM;
  dtab[OP_SUB_IMM] = &&L_SUB_IMM;
  dtab[OP_XOR_IMM] = &&L_XOR_IMM;
  dtab[OP_AND_IMM] = &&L_AND_IMM;
  dtab[OP_OR_IMM] = &&L_OR_IMM;
  dtab[OP_MUL_IMM] = &&L_MUL_IMM;
  dtab[OP_SHL_IMM] = &&L_SHL_IMM;
  dtab[OP_SHR_IMM] = &&L_SHR_IMM;
  dtab[OP_ASR_IMM] = &&L_ASR_IMM;
  /* 比较 */
  dtab[OP_CMP] = &&L_CMP;
  dtab[OP_CMP_IMM] = &&L_CMP_IMM;
  /* 分支 */
  dtab[OP_JMP] = &&L_JMP;
  dtab[OP_JE] = &&L_JE;
  dtab[OP_JNE] = &&L_JNE;
  dtab[OP_JL] = &&L_JL;
  dtab[OP_JGE] = &&L_JGE;
  dtab[OP_JGT] = &&L_JGT;
  dtab[OP_JLE] = &&L_JLE;
  dtab[OP_JB] = &&L_JB;
  dtab[OP_JAE] = &&L_JAE;
  dtab[OP_JBE] = &&L_JBE;
  dtab[OP_JA] = &&L_JA;
  /* 栈操作 */
  dtab[OP_PUSH] = &&L_PUSH;
  dtab[OP_POP] = &&L_POP;
  /* 原生调用 */
  dtab[OP_CALL_NAT] = &&L_CALL_NAT;
  dtab[OP_CALL_LIT] = &&L_CALL_LIT;
  dtab[OP_CALL_REG] = &&L_CALL_REG;
  dtab[OP_LOAD_IDX8] = &&L_LOAD_IDX8;
  dtab[OP_LOAD_IDX16] = &&L_LOAD_IDX16;
  dtab[OP_LOAD_IDX32] = &&L_LOAD_IDX32;
  dtab[OP_LOAD_IDX64] = &&L_LOAD_IDX64;
  dtab[OP_STORE_IDX8] = &&L_STORE_IDX8;
  dtab[OP_STORE_IDX16] = &&L_STORE_IDX16;
  dtab[OP_STORE_IDX32] = &&L_STORE_IDX32;
  dtab[OP_STORE_IDX64] = &&L_STORE_IDX64;
  dtab[OP_BR_REG] = &&L_BR_REG;
  /* SIMD */
  dtab[OP_VLD16] = &&L_VLD16;
  dtab[OP_VST16] = &&L_VST16;
  /* TBZ/TBNZ */
  dtab[OP_TST] = &&L_TST;
  dtab[OP_FMOV_GEN] = &&L_FMOV_GEN;
  dtab[OP_EXTR] = &&L_EXTR;
  dtab[OP_TBZ] = &&L_TBZ;
  dtab[OP_TBNZ] = &&L_TBNZ;
  /* CCMP/CCMN */
  dtab[OP_CCMP_REG] = &&L_CCMP_REG;
  dtab[OP_CCMP_IMM] = &&L_CCMP_IMM;
  dtab[OP_CCMN_REG] = &&L_CCMN_REG;
  dtab[OP_CCMN_IMM] = &&L_CCMN_IMM;
  /* SVC */
  dtab[OP_SVC] = &&L_SVC;
  /* UDIV/SDIV */
  dtab[OP_UDIV] = &&L_UDIV;
  dtab[OP_SDIV] = &&L_SDIV;
  /* MRS */
  dtab[OP_MRS] = &&L_MRS;

/* 反向模式: pc 指向指令末尾的 size 标记之后
 * 步骤: pc--; size = bc[pc]; pc -= size; 现在 pc 指向指令起始 */
#define DISPATCH()                                                             \
  do {                                                                         \
    if (vm->reverse) {                                                         \
      if (__builtin_expect((i64)vm->pc <= 0, 0)) { args[6]=0xD1; goto cleanup; } \
      vm->pc--;                                                                \
      if (__builtin_expect(vm->pc >= vm->bc_len, 0)) { args[6]=0xD2; goto cleanup; } \
      u8 _sz = vm->bc[vm->pc];                                                 \
      if (__builtin_expect(_sz > vm->pc, 0)) { args[6]=0xD3; goto cleanup; }   \
      vm->pc -= _sz;                                                           \
    } else {                                                                   \
      if (__builtin_expect(vm->pc >= vm->bc_len, 0)) {                         \
        args[6] = 0xE001; args[7] = (u64)vm->pc; goto cleanup;                 \
      }                                                                        \
    }                                                                          \
    u8 _raw_op = vm->bc[vm->pc];                                               \
    u8 _dec_op = _raw_op ^ OC_DECRYPT(vm->pc, vm->oc_key);                     \
    u8 _isz = vm_insn_size(_dec_op);                                           \
    if (__builtin_expect(_isz == 0 || vm->pc + _isz > vm->bc_len, 0)) {        \
      args[6] = 0xE002; args[7] = ((u64)vm->pc << 8) | (u64)_dec_op;           \
      goto cleanup;                                                            \
    }                                                                          \
    if (vm->pc < 40) VMDBG("[vm] op=0x%02x pc=%u", _dec_op, vm->pc);           \
    goto *dtab[_dec_op];                                                       \
  } while (0)

/* NEXT: handler 必须总是执行; 正向 pc += n, 反向忽略 advance */
#define NEXT(n)                                                                \
  do {                                                                         \
    u32 _adv = (n);                                                            \
    __asm__ volatile("" ::: "memory");                                         \
    if (!vm->reverse)                                                          \
      vm->pc += _adv;                                                          \
    DISPATCH();                                                                \
  } while (0)
#define NEXT0() DISPATCH() /* handler 已设置 pc */

  /* ---- PC 初始化: reverse 模式从 bc_len 开始 ---- */
  if (vm->reverse) {
    vm->pc = vm->bc_len; /* DISPATCH 会先递减定位到最后一条指令 */
  }

  /* ---- 开始执行 ---- */
  DISPATCH();

/* ---- 系统 ---- */
L_ADD_BASE:
  NEXT(h_add_base(vm));

L_NOP:
  NEXT(h_nop(vm));
L_HALT:
  VMDBG("[vm] HALT pc=%u R0=0x%llx", vm->pc, vm->R[0]);
  ret = vm->R[0];
  /* ★ 返回值写入 args[0]，hook 从这里读（不再依赖 ret 变量） */
  args[0] = (u64)vm->R[0];
  args[1] = (u64)vm->pc;
  args[2] = (u64)vm->FL;
  goto cleanup;
L_RET: {
  /* ARM64 的 `ret x30` 是"跳回 x30"，但 VM 里它表示"函数返回"
   * → 返回值取 R[0]（x0），不是 R[30]（返回地址） */
  ret = vm->R[0];
  args[0] = (u64)vm->R[0];
  args[1] = (u64)vm->pc;
  args[2] = (u64)0x52455400ULL;
  goto cleanup;
}

/* ---- 数据移动 ---- */
L_MOV_IMM:
  NEXT(h_mov_imm(vm));
L_MOV_IMM32:
  NEXT(h_mov_imm32(vm));
L_FADD:
  NEXT(h_fadd(vm));
L_FSUB:
  NEXT(h_fsub(vm));
L_FMUL:
  NEXT(h_fmul(vm));
L_FDIV:
  NEXT(h_fdiv(vm));
L_FMOV_REG:
  NEXT(h_fmov_reg(vm));
L_FNEG:
  NEXT(h_fneg(vm));
L_FABS:
  NEXT(h_fabs(vm));
L_FCVT:
  NEXT(h_fcvt(vm));
L_SCVTF:
  NEXT(h_scvtf(vm));
L_UCVTF:
  NEXT(h_ucvtf(vm));
L_FCVTZS:
  NEXT(h_fcvtzs(vm));
L_FCVTZU:
  NEXT(h_fcvtzu(vm));
L_FCMP:
  NEXT(h_fcmp(vm));
L_LOAD_FP:
  NEXT(h_load_fp(vm));
L_STORE_FP:
  NEXT(h_store_fp(vm));
L_FMOV_IMM:
  NEXT(h_fmov_imm(vm));
L_FMAX:
  NEXT(h_fmax(vm));
L_FMIN:
  NEXT(h_fmin(vm));
L_FSQRT:
  NEXT(h_fsqrt(vm));
L_FRINT:
  NEXT(h_frint(vm));
L_LOAD_LIT_FP:
  NEXT(h_load_lit_fp(vm));
/* v-neon: NEON/AdvSIMD */
L_VMOVI:
  NEXT(h_vmovi(vm));
L_VLDR:
  NEXT(h_vldr(vm));
L_VSTR:
  NEXT(h_vstr(vm));
L_V3S:
  NEXT(h_v3s(vm));
L_V2S:
  NEXT(h_v2s(vm));
L_VDUPE:
  NEXT(h_vdupe(vm));
L_VDUPG:
  NEXT(h_vdupg(vm));
L_VINSE:
  NEXT(h_vinse(vm));
L_VINSG:
  NEXT(h_vinsg(vm));
L_VUMOV:
  NEXT(h_vumov(vm));
L_VEXT:
  NEXT(h_vext(vm));
L_VPERM:
  NEXT(h_vperm(vm));
L_VFMA:
  NEXT(h_vfma(vm));
L_FMADD:
  NEXT(h_fmadd(vm));
L_FCMP_Z:
  NEXT(h_fcmp_zero(vm));
L_FCSEL:
  NEXT(h_fcsel(vm));
L_UBFM:
  NEXT(h_ubfm(vm));
L_MOVK:
  NEXT(h_movk(vm));
L_MOV_REG:
  NEXT(h_mov_reg(vm));

/* ---- 内存访问 ---- */
L_LOAD_LIT8:
  NEXT(h_load_lit8(vm));
L_LOAD_LIT16:
  NEXT(h_load_lit16(vm));
L_LOAD_LIT32:
  NEXT(h_load_lit32(vm));
L_LOAD_LIT64:
  NEXT(h_load_lit64(vm));
L_LOAD8:
  NEXT(h_load8(vm));
L_LOAD32:
  NEXT(h_load32(vm));
L_LOAD64:
  NEXT(h_load64(vm));
L_STORE8:
  NEXT(h_store8(vm));
L_STORE32:
  NEXT(h_store32(vm));
L_STORE64:
  NEXT(h_store64(vm));
L_LOAD16:
  NEXT(h_load16(vm));
L_STORE16:
  NEXT(h_store16(vm));

/* ---- ALU 三寄存器 ---- */
L_ADD:
  NEXT(h_add(vm));
L_SUB:
  NEXT(h_sub(vm));
L_MUL:
  NEXT(h_mul(vm));
L_XOR:
  NEXT(h_xor(vm));
L_AND:
  NEXT(h_and(vm));
L_OR:
  NEXT(h_or(vm));
L_SHL:
  NEXT(h_shl(vm));
L_SHR:
  NEXT(h_shr(vm));
L_ASR:
  NEXT(h_asr(vm));
L_NOT:
  NEXT(h_not(vm));
L_ROR:
  NEXT(h_ror(vm));
L_UMULH:
  NEXT(h_umulh(vm));

/* ---- ALU 立即数 ---- */
L_ADD_IMM:
  NEXT(h_add_imm(vm));
L_SUB_IMM:
  NEXT(h_sub_imm(vm));
L_XOR_IMM:
  NEXT(h_xor_imm(vm));
L_AND_IMM:
  NEXT(h_and_imm(vm));
L_OR_IMM:
  NEXT(h_or_imm(vm));
L_MUL_IMM:
  NEXT(h_mul_imm(vm));
L_SHL_IMM:
  NEXT(h_shl_imm(vm));
L_SHR_IMM:
  NEXT(h_shr_imm(vm));
L_ASR_IMM:
  NEXT(h_asr_imm(vm));

/* ---- 比较 ---- */
L_CMP:
  NEXT(h_cmp(vm));
L_CMP_IMM:
  NEXT(h_cmp_imm(vm));

/* ---- 分支 (handler 返回 0, 已设置 pc) ---- */
L_JMP:
  h_jmp(vm);
  NEXT0();
L_JE:
  h_je(vm);
  NEXT0();
L_JNE:
  h_jne(vm);
  NEXT0();
L_JL:
  h_jl(vm);
  NEXT0();
L_JGE:
  h_jge(vm);
  NEXT0();
L_JGT:
  h_jgt(vm);
  NEXT0();
L_JLE:
  h_jle(vm);
  NEXT0();
L_JB:
  h_jb(vm);
  NEXT0();
L_JAE:
  h_jae(vm);
  NEXT0();
L_JBE:
  h_jbe(vm);
  NEXT0();
L_JA:
  h_ja(vm);
  NEXT0();

/* ---- 栈操作 ---- */
L_PUSH:
  NEXT(h_push(vm));
L_POP:
  NEXT(h_pop(vm));

/* ---- 原生调用 ---- */
L_CALL_LIT: {
  u32 _s = h_call_lit(vm);
  if (_s == 0xFFFFFFFFu) { ret = vm->R[0]; goto cleanup; }
  NEXT(_s);
}
L_CALL_NAT:
  NEXT(h_call_nat(vm));
L_CALL_REG:
  NEXT(h_call_reg(vm));
L_LOAD_IDX8:
  NEXT(h_load_idx8(vm));
L_LOAD_IDX16:
  NEXT(h_load_idx16(vm));
L_LOAD_IDX32:
  NEXT(h_load_idx32(vm));
L_LOAD_IDX64:
  NEXT(h_load_idx64(vm));
L_STORE_IDX8:
  NEXT(h_store_idx8(vm));
L_STORE_IDX16:
  NEXT(h_store_idx16(vm));
L_STORE_IDX32:
  NEXT(h_store_idx32(vm));
L_STORE_IDX64:
  NEXT(h_store_idx64(vm));
L_BR_REG: {
  u32 a = h_br_reg(vm);
  if (a)
    NEXT(a);
  else
    NEXT0();
}

/* ---- SIMD ---- */
L_VLD16:
  NEXT(h_vld16(vm));
L_VST16:
  NEXT(h_vst16(vm));

/* ---- TBZ/TBNZ (分支, handler 返回 0, 已设置 pc) ---- */
L_TBZ:
  h_tbz(vm);
  NEXT0();
L_TBNZ:
  h_tbnz(vm);
  NEXT0();

L_TST:
  h_tst(vm);
  NEXT0();
L_FMOV_GEN:
  h_fmov_gen(vm);
  NEXT0();
L_EXTR:
  h_extr(vm);
  NEXT0();

/* ---- CCMP/CCMN ---- */
L_CCMP_REG:
  NEXT(h_ccmp_reg(vm));
L_CCMP_IMM:
  NEXT(h_ccmp_imm(vm));
L_CCMN_REG:
  NEXT(h_ccmn_reg(vm));
L_CCMN_IMM:
  NEXT(h_ccmn_imm(vm));

/* ---- SVC ---- */
L_SVC:
  NEXT(h_svc(vm));

/* ---- UDIV/SDIV ---- */
L_UDIV:
  NEXT(h_udiv(vm));
L_SDIV:
  NEXT(h_sdiv(vm));

/* ---- MRS ---- */
L_MRS:
  NEXT(h_mrs(vm));

/* ---- 未知指令 ---- */
L_UNKNOWN:
  ret = vm->R[0];
  /* ★ 未知 opcode：args[0] 也放返回值 */
  args[0] = (u64)vm->R[0];
  args[1] = (u64)vm->pc;
  args[2] = (u64)0xDEADBEEF;
  args[3] = (u64)(vm->pc < vm->bc_len
                 ? (u32)(vm->bc[vm->pc] ^ (u8)(vm->oc_key ^ ((vm->pc * 0x9E3779B9u) & 0xFF)))
                 : 0xAAu);
  goto cleanup;

#undef DISPATCH
#undef NEXT
#undef NEXT0

#endif /* VM_INDIRECT_DISPATCH */

  /* ---- 统一退出 ---- */
cleanup:
  /* ★ 把 X19-X28 的执行结果回写给调用方:
   *   原函数在返回后可能依赖这些 callee-saved 寄存器的值（例如缓存的对象指针），
   *   不回写会让调用方拿到过期的旧值 -> 后续访问野指针。
   *   注意: hook 侧的 naked 汇编此时仍持有调用方原值，
   *   由 VMPHooks.xm 的 hook 出口负责把这些值装回 X19-X28。 */
  if (vm) {
    for (int i = VM_CS_MIN; i <= VM_CS_MAX; i++)
      args[11 + (i - VM_CS_MIN)] = vm->R[i];
    args[8] = vm->R[29];      /* 回写 FP */
    args[9] = vm->R[30];      /* 回写 LR */
    args[0] = vm->R[0];       /* 返回值同时落在 args[0]，兼容旧读法 */
    /* ★ v-float: 浮点/double 返回值在 d0 = V[0]。写回 args[23]，
       由 hook 尾声 `ldr d0,[sp,#0xB8]` 装回物理 d0。整数返回的函数这个值被忽略。 */
    args[23] = vm->V[0];
  }
  vm_free(vm);
  vm_free(bc_buf);
  return ret;
}

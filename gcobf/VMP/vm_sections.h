/*
 * vm_sections.h — Handler Section 分配宏
 *
 * 当 VM_FUNC_SPLIT 宏定义时，将 handler 包装函数分散到
 * 不同的 ELF section 中，使 IDA Pro 将每个片段识别为独立函数。
 *
 * Section 分组:
 *   .text.vm_alu    — ALU 运算 (add/sub/mul/xor/and/or/shl/shr/asr/not/ror + _imm)
 *   .text.vm_mem    — 内存访问 (load/store 8/32/64, mov_imm/imm32/reg)
 *   .text.vm_branch — 分支 (jmp/je/jne/jl/jge/jgt/jle/jb/jae/jbe/ja)
 *   .text.vm_system — 系统 (nop/halt/ret/call_nat/call_reg/br_reg/push/pop/vld16/vst16)
 *
 * 未启用时宏展开为空，不影响编译。
 */
#ifndef VM_SECTIONS_H
#define VM_SECTIONS_H

#ifdef VM_FUNC_SPLIT
  /* ★ Mach-O(iOS) 与 ELF 段名格式不同:
   *   Mach-O 必须 "段,节" 且节名 ≤16 字符 → __TEXT,__vmXXX
   *   ELF   用 .text.vmXXX
   *   之前只有 ELF 名 → 在 iOS 上 clang 直接报错, 这才是段分割一直默认关的真因。*/
  #if defined(__APPLE__) || defined(__MACH__)
    #define VM_SECTION_ALU     __attribute__((section("__TEXT,__vmalu")))
    #define VM_SECTION_MEM     __attribute__((section("__TEXT,__vmmem")))
    #define VM_SECTION_BRANCH  __attribute__((section("__TEXT,__vmbr")))
    #define VM_SECTION_SYSTEM  __attribute__((section("__TEXT,__vmsys")))
  #else
    #define VM_SECTION_ALU     __attribute__((section(".text.vm_alu")))
    #define VM_SECTION_MEM     __attribute__((section(".text.vm_mem")))
    #define VM_SECTION_BRANCH  __attribute__((section(".text.vm_branch")))
    #define VM_SECTION_SYSTEM  __attribute__((section(".text.vm_system")))
  #endif
#else
  #define VM_SECTION_ALU
  #define VM_SECTION_MEM
  #define VM_SECTION_BRANCH
  #define VM_SECTION_SYSTEM
#endif

#endif /* VM_SECTIONS_H */

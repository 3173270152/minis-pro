// FragTable.h - 运行时不可折叠常量表 (LLVM 16)  v1.0
//
// 解决的问题（v2 的 cenc 其实完全无效）：
//   ConstEnc.cpp 里 `(v^K1)^K2` 的 K1/K2 都是 ConstantInt，
//   IRBuilder 的 ConstantFolder 在 CreateXor 当场就折叠成 K，
//   第二个 CreateXor 又折叠回 v —— setOperand 塞回去的还是原常量。
//   即使侥幸留下 xor 指令，InstCombine 和 SelectionDAG 还会再折一次。
//
// 本表的做法：把"密钥"放进一个 internal constant 数据表，
// 只通过 volatile load 读取。volatile 是优化器唯一的硬约束：
//   常量折叠看不见 / InstCombine 不碰 / DAG combine 不碰 / GlobalOpt 不碰。
//
// 表的语义：
//   每个"字节"占两个槽 a,b，满足 tbl[a] ^ tbl[b] == 目标字节（编译期）。
//   IR 里表现为 `xor (load volatile i8 tbl+a), (load volatile i8 tbl+b)`。
//   静态 dump 出来只是一张随机字节表，要知道某个常量得先定位所有
//   引用点的槽对、再逐字节 xor 拼回来。
//
// 每个模块一张 64KB 表（约 4096 个字节槽 = 2048 个 64 位常量）。
#ifndef FRAGTABLE_H
#define FRAGTABLE_H

#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include <cstdint>

namespace gco {

// 分配 n 个字节（n<=8），每个字节要 2 个槽。
// idxOut 长度必须 >= 2*n：idxOut[i*2], idxOut[i*2+1] 是第 i 字节的两个槽号。
// 返回 false = 表满。
bool fragTableAlloc(llvm::Module *M, const uint8_t *bytes, unsigned n,
                    unsigned *idxOut);

// 把表内容写回 GlobalVariable 的 initializer。
// 必须在该模块的所有 fragTableAlloc 之后调用一次（ObfPass 末尾）。
void fragTableSync(llvm::Module *M);

// 已用槽数（统计用）
unsigned fragTableUsed(llvm::Module *M);

// 单字节：load volatile i8, ptr (tbl + idx)
llvm::Value *fragTableLoadByte(llvm::Module *M, llvm::IRBuilder<> &B,
                               unsigned idx);

// n 字节拼装成 ty（n = ty 位宽 / 8，n<=8）
llvm::Value *fragTableLoadBytes(llvm::Module *M, llvm::IRBuilder<> &B,
                                const unsigned *idx, unsigned n,
                                llvm::Type *ty);

} // namespace gco
#endif

// ConstEnc.cpp - 常量加密 (LLVM 16)  v3.0
//
// v2 的三个问题（v2 实际上一个常量都没保护住）：
//   1. 对 SwitchInst 的 case 值调用 setOperand → SwitchInst 要求 case 必须是
//      ConstantInt, 传进去一个 Instruction 会在 verifier/ISel 阶段直接崩
//   2. 对 AllocaInst 的 size、比对元数据 intrinsic 也照改, 增加崩溃面
//   3. ★ 致命: `(v^K1)^K2` 的 K1/K2 都是 ConstantInt,
//      IRBuilder 的 ConstantFolder 在 CreateXor 当场折叠成 K,
//      第二个 CreateXor 又折叠回 v —— setOperand 塞回去的还是原常量。
//      即使侥幸留下 xor 指令, InstCombine / SelectionDAG 还会再折一次。
//      → v2 的 "cenc=8" 统计是假的, 二进制里一个字节都没变。
//
// v3 改造:
//   1. 跳过的指令类型统一放进 skipInst()（与 ConstFrag 保持一致）
//   2. 只加密位数 >= cencMinBits 的常量 (默认 9 bit, 即 >= 512)
//   3. 密钥 A 不在 IR 里以常量出现, 而是从 FragTable 的 volatile load 拼出来
//      IR:  xor (ConstantInt(v ^ A),  fragTableLoadBytes(A))
//      运行时 = (v ^ A) ^ A = v ✓   静态 = 一堆随机字节槽 + 一个 (v^A) 常量
#include "ObfUtils.h"
#include "FragTable.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include <vector>

using namespace llvm;
namespace gco {

namespace {

static bool skipInst(Instruction *I) {
    if (!I->getParent()) return true;
    if (I->isTerminator()) return true;              // switch case 必须是常量
    if (isa<PHINode>(I)) return true;
    if (isa<AllocaInst>(I)) return true;
    if (isa<GetElementPtrInst>(I)) return true;      // struct 索引必须常量
    if (isa<LandingPadInst>(I)) return true;
    if (isa<InvokeInst>(I)) return true;
    if (isa<CallBrInst>(I)) return true;
    if (isa<ShuffleVectorInst>(I)) return true;
    if (isa<AtomicRMWInst>(I)) return true;
    if (isa<AtomicCmpXchgInst>(I)) return true;
    if (isa<IntrinsicInst>(I)) return true;
    if (I->getType()->isVectorTy()) return true;
    return false;
}

} // namespace

static bool encConst(Function *F) {
    Module *M = F->getParent();
    const Config &cfg = config();
    unsigned minBits = (unsigned)cfg.cencMinBits;
    if (minBits < 1) minBits = 1;
    if (minBits > 63) minBits = 63;
    uint64_t minVal = (1ULL << minBits);

    std::vector<Instruction *> work;
    for (BasicBlock &BB : *F)
        for (Instruction &I : BB) work.push_back(&I);

    int cnt = 0;
    for (Instruction *I : work) {
        if (skipInst(I)) continue;

        unsigned n = I->getNumOperands();
        for (unsigned oi = 0; oi < n; oi++) {
            auto *ci = dyn_cast<ConstantInt>(I->getOperand(oi));
            if (!ci) continue;

            Type *ty = ci->getType();
            if (!ty->isIntegerTy()) continue;
            unsigned bits = ty->getIntegerBitWidth();
            if (bits < 8 || bits > 64) continue;

            uint64_t v = ci->getValue().getZExtValue();
            if (v == 0 || v == 1) continue;
            if (v < minVal) continue;                  // 小常量不值得

            uint64_t mask = (bits >= 64) ? ~0ULL : ((1ULL << bits) - 1ULL);
            uint64_t A = (((uint64_t)rand32() << 32) | rand32()) & mask;
            if (A == 0) A = 0x3C5A17B9ULL & mask;

            unsigned nbytes = bits / 8;
            uint8_t ab[8];
            for (unsigned i = 0; i < nbytes; i++)
                ab[i] = (uint8_t)((A >> (i * 8)) & 0xFF);

            unsigned idx[16];
            if (!fragTableAlloc(M, ab, nbytes, idx)) return cnt > 0;

            IRBuilder<> B(I);
            Value *key = fragTableLoadBytes(M, B, idx, nbytes, ty);
            if (!key) continue;
            Value *enc = ConstantInt::get(ty, (v ^ A) & mask);
            Value *res = B.CreateXor(enc, key);        // enc 是常量, key 是 load → 不折叠
            I->setOperand(oi, res);
            cnt++;
        }
    }
    return cnt > 0;
}

bool runConstEnc(Function *F, bool on) {
    if (!funcToObfuscate(F, "cenc", on)) return false;
    if (F->isDeclaration()) return false;
    if (config().cencMinBits <= 0) return false;
    return encConst(F);
}

} // namespace gco

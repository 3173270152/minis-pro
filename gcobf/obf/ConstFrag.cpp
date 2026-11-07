// ConstFrag.cpp - 常量碎片化 (LLVM 16)  v1.0
//
// 目标：让 dylib 里的关键 32/64 位常量（卡密密钥、偏移、长度、魔数）
//       在二进制里**找不到完整值**。
//
// 与 cenc 的区别：
//   cenc 的 (v^K1)^K2 全部是 ConstantInt，IRBuilder 当场折叠回 v，
//   等于什么都没做（见 FragTable.h 头部说明）。
//   本 pass 走 volatile 表，编译器无法还原，是真正的加密。
//
// 与"后处理二进制改指令"的区别（记忆里 BUG-9 判定物理不可行的那条）：
//   那条走的是"等长替换 + 不改段表"约束，所以不可行。
//   本 pass 在 IR 层做，代码长度随便变，不存在这个问题。
//
// 必须跳过的指令（每条都是踩过的坑）：
//   PHI        → operand 必须来自支配前驱块，插在块首会直接 verifier 崩
//   terminator → switch 的 case 值要求 ConstantInt
//   Alloca     → size 影响栈布局
//   GEP        → struct 类型的索引必须是常量
//   Intrinsic  → memcpy/memset 的 size 参与 intrinsic 语义判断
//   Invoke/CallBr/LandingPad/ShuffleVector/Atomic → 语义或 verifier 限制
#include "ObfUtils.h"
#include "FragTable.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Support/raw_ostream.h"
#include <vector>

using namespace llvm;
namespace gco {

namespace {

static bool skipInst(Instruction *I) {
    if (!I->getParent()) return true;
    if (I->isTerminator()) return true;
    if (isa<PHINode>(I)) return true;
    if (isa<AllocaInst>(I)) return true;
    if (isa<GetElementPtrInst>(I)) return true;
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

static int fragFunc(Function *F, unsigned minBits, int maxCnt) {
    Module *M = F->getParent();
    std::vector<Instruction *> work;
    for (BasicBlock &BB : *F)
        for (Instruction &I : BB) work.push_back(&I);

    int cnt = 0;
    for (Instruction *I : work) {
        if (cnt >= maxCnt) break;
        if (skipInst(I)) continue;

        unsigned nOps = I->getNumOperands();
        for (unsigned oi = 0; oi < nOps; oi++) {
            auto *ci = dyn_cast<ConstantInt>(I->getOperand(oi));
            if (!ci) continue;
            Type *ty = ci->getType();
            if (!ty->isIntegerTy()) continue;

            unsigned bits = ty->getIntegerBitWidth();
            if (bits < 8 || bits > 64) continue;
            if (bits < minBits) continue;

            uint64_t v = ci->getValue().getZExtValue();
            if (v == 0 || v == 1) continue;                      // 无意义
            if (bits < 64 && v == ((1ULL << bits) - 1ULL)) continue;  // -1 太常见

            unsigned nbytes = bits / 8;
            uint8_t bytes[8];
            for (unsigned i = 0; i < nbytes; i++)
                bytes[i] = (uint8_t)((v >> (i * 8)) & 0xFF);

            unsigned idx[16];
            if (!fragTableAlloc(M, bytes, nbytes, idx)) return cnt;

            IRBuilder<> B(I);
            Value *acc = fragTableLoadBytes(M, B, idx, nbytes, ty);
            if (!acc) continue;
            I->setOperand(oi, acc);
            cnt++;
            if (cnt >= maxCnt) break;
        }
    }
    return cnt;
}

} // namespace

int runConstFrag(Module *M, bool on) {
    if (!on || !M) return 0;
    const Config &cfg = config();
    unsigned minBits = (unsigned)cfg.fragMinBits;
    int maxPerFunc = cfg.fragMaxPerFunc;
    if (minBits < 8) minBits = 8;
    if (minBits > 64) minBits = 64;
    if (maxPerFunc <= 0) maxPerFunc = 32;
    if (maxPerFunc > 256) maxPerFunc = 256;

    std::vector<Function *> funcs;
    for (Function &F : *M) funcs.push_back(&F);

    int total = 0, nfunc = 0;
    for (Function *F : funcs) {
        if (!F->getParent()) continue;
        if (F->isDeclaration() || F->isIntrinsic()) continue;
        if (!funcToObfuscate(F, "frag", true)) continue;
        int n = fragFunc(F, minBits, maxPerFunc);
        if (n > 0) { total += n; nfunc++; }
    }

    // ★ 必须在所有 alloc 之后同步一次，否则运行时读到的槽值还是初始随机数
    fragTableSync(M);

    if (total)
        errs() << "[GCObf] frag: " << total << " 个常量 / " << nfunc
               << " 个函数, 表用量 " << fragTableUsed(M) << " 字节\n";
    return total;
}

} // namespace gco

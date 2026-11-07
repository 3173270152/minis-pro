// Substitution.cpp - 指令替换 MBA (LLVM 16)  v2.0
//   只用【位运算 + 加减常数】恒等式 (无移位/除法 → 无 UB/溢出问题)
//
// v2 变更:
//   * 轮数由 GCOBF sub:N 控制 (默认 1, 上限 4)。v1 固定 2 轮 → 每条算术指令
//     膨胀成 9 条, 热循环 FPS 掉得厉害
//   * 跳过 i1 (布尔) 类型, 避免 select/icmp 组合被无意义放大
//   * 保留原有恒等式 (均已验证 modulo 2^n 成立)
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include <vector>

using namespace llvm;
namespace gco {

static Value *Rk(IRBuilder<> &B, Type *ty) {
    return ConstantInt::get(ty, (uint64_t)rand32() | 1);
}

// a + b  =>  (a | b) + (a & b)  /  (a^b) + 2*(a&b)  /  (a-k) + (b+k)
static void addSub(IRBuilder<> &B, BinaryOperator *bo) {
    Value *a = bo->getOperand(0), *b = bo->getOperand(1), *r = nullptr;
    switch (rand32() % 3) {
    case 0: r = B.CreateAdd(B.CreateOr(a, b), B.CreateAnd(a, b)); break;
    case 1: r = B.CreateAdd(B.CreateXor(a, b),
                            B.CreateAdd(B.CreateAnd(a, b), B.CreateAnd(a, b))); break;
    case 2: { Value *k = Rk(B, bo->getType());
              r = B.CreateAdd(B.CreateSub(a, k), B.CreateAdd(b, k)); } break;
    }
    if (r) { bo->replaceAllUsesWith(r); bo->eraseFromParent(); }
}

// a - b  =>  a + ~b + 1  /  (a|~b) + (a&~b) + 1  /  (a+k) - (b+k)
static void subSub(IRBuilder<> &B, BinaryOperator *bo) {
    Value *a = bo->getOperand(0), *b = bo->getOperand(1), *r = nullptr;
    Type *ty = bo->getType();
    switch (rand32() % 3) {
    case 0: r = B.CreateAdd(a, B.CreateAdd(B.CreateNot(b), ConstantInt::get(ty, 1))); break;
    case 1: r = B.CreateAdd(B.CreateOr(a, B.CreateNot(b)),
                            B.CreateAdd(B.CreateAnd(a, B.CreateNot(b)), ConstantInt::get(ty, 1))); break;
    case 2: { Value *k = Rk(B, ty);
              r = B.CreateSub(B.CreateAdd(a, k), B.CreateAdd(b, k)); } break;
    }
    if (r) { bo->replaceAllUsesWith(r); bo->eraseFromParent(); }
}

// a & b  =>  (a ^ ~b) & a  /  ~(~a | ~b)  /  (a&b) & (k|~k)
static void andSub(IRBuilder<> &B, BinaryOperator *bo) {
    Value *a = bo->getOperand(0), *b = bo->getOperand(1), *r = nullptr;
    Type *ty = bo->getType();
    switch (rand32() % 3) {
    case 0: r = B.CreateAnd(B.CreateXor(a, B.CreateNot(b)), a); break;
    case 1: r = B.CreateNot(B.CreateOr(B.CreateNot(a), B.CreateNot(b))); break;
    case 2: { Value *k = Rk(B, ty);
              r = B.CreateAnd(B.CreateAnd(a, b), B.CreateOr(k, B.CreateNot(k))); } break;
    }
    if (r) { bo->replaceAllUsesWith(r); bo->eraseFromParent(); }
}

// a | b  =>  (a & b) | (a ^ b)  /  ~(~a & ~b)  /  (a|b) | (k&~k)
static void orSub(IRBuilder<> &B, BinaryOperator *bo) {
    Value *a = bo->getOperand(0), *b = bo->getOperand(1), *r = nullptr;
    Type *ty = bo->getType();
    switch (rand32() % 3) {
    case 0: r = B.CreateOr(B.CreateAnd(a, b), B.CreateXor(a, b)); break;
    case 1: r = B.CreateNot(B.CreateAnd(B.CreateNot(a), B.CreateNot(b))); break;
    case 2: { Value *k = Rk(B, ty);
              r = B.CreateOr(B.CreateOr(a, b), B.CreateAnd(k, B.CreateNot(k))); } break;
    }
    if (r) { bo->replaceAllUsesWith(r); bo->eraseFromParent(); }
}

// a ^ b  =>  (a | b) - (a & b)  /  (~a & b) | (a & ~b)  /  (a^k) ^ (b^k)
static void xorSub(IRBuilder<> &B, BinaryOperator *bo) {
    Value *a = bo->getOperand(0), *b = bo->getOperand(1), *r = nullptr;
    Type *ty = bo->getType();
    switch (rand32() % 3) {
    case 0: r = B.CreateSub(B.CreateOr(a, b), B.CreateAnd(a, b)); break;
    case 1: r = B.CreateOr(B.CreateAnd(B.CreateNot(a), b), B.CreateAnd(a, B.CreateNot(b))); break;
    case 2: { Value *k = Rk(B, ty);
              r = B.CreateXor(B.CreateXor(a, k), B.CreateXor(b, k)); } break;
    }
    if (r) { bo->replaceAllUsesWith(r); bo->eraseFromParent(); }
}

static void substitute(Function *F, int rounds) {
    for (int round = 0; round < rounds; round++) {
        std::vector<BinaryOperator *> work;
        for (auto &BB : *F)
            for (auto &I : BB)
                if (auto *bo = dyn_cast<BinaryOperator>(&I)) work.push_back(bo);

        for (auto *bo : work) {
            if (!bo->getParent()) continue;
            Type *ty = bo->getType();
            if (!ty->isIntegerTy()) continue;
            if (ty->getIntegerBitWidth() < 8) continue;   // i1 不碰
            IRBuilder<> B(bo);
            switch (bo->getOpcode()) {
            case Instruction::Add: addSub(B, bo); break;
            case Instruction::Sub: subSub(B, bo); break;
            case Instruction::And: andSub(B, bo); break;
            case Instruction::Or:  orSub(B, bo);  break;
            case Instruction::Xor: xorSub(B, bo); break;
            default: break;
            }
        }
    }
}

bool runSub(Function *F, bool on) {
    if (!funcToObfuscate(F, "sub", on)) return false;
    if (F->isDeclaration()) return false;
    const Config &cfg = config();
    if (cfg.subRounds <= 0) return false;
    substitute(F, cfg.subRounds);
    return true;
}
} // namespace gco

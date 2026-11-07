// BogusControlFlow.cpp - 虚假控制流 (LLVM 16)  v2.0
//
// v1 致命问题:
//   opaqueTrue() 里所有操作数都是 getInt32(常量) → 谓词在编译期就被算成 true,
//   CodeGenPrepare/ISel 之后分支被折叠, 垃圾块整段消失。等于什么都没做。
//
// v2 改造:
//   1. 谓词依赖"运行时 opaque 值" (ctor 用函数地址填充的 volatile 全局),
//      编译器无法证明真值 → 分支真实保留到二进制里
//   2. 每函数只读一次该值 (函数入口), 分摊成本, 热路径不额外访问内存
//   3. 垃圾块内做 volatile 写, 避免被当作死代码删除
//   4. 轮数受控 (默认 2), 且每轮只处理函数入口时快照的真实块, 不会指数膨胀
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include <vector>
#include <map>
#include <set>

using namespace llvm;
namespace gco {

// 恒真谓词, 依赖运行时值 a (对任意 a 都成立)
static Value *opaqueTrue(IRBuilder<> &B, Value *a) {
    int form = rand32() % 3;
    if (form == 0) {
        // a * (a + 1) 恒为偶数
        Value *p = B.CreateMul(a, B.CreateAdd(a, B.getInt32(1)));
        return B.CreateICmpEQ(B.CreateAnd(p, B.getInt32(1)), B.getInt32(0));
    } else if (form == 1) {
        // (a | 1) & 1 == 1
        Value *o = B.CreateOr(a, B.getInt32(1));
        return B.CreateICmpEQ(B.CreateAnd(o, B.getInt32(1)), B.getInt32(1));
    }
    // a ^ (a + 1) 最低位恒为 1
    Value *x = B.CreateXor(a, B.CreateAdd(a, B.getInt32(1)));
    return B.CreateICmpEQ(B.CreateAnd(x, B.getInt32(1)), B.getInt32(1));
}

// 垃圾全局: 垃圾块里对它做 volatile 写, 防止 DCE
static GlobalVariable *junkGlobal(Module *M) {
    static std::map<Module *, GlobalVariable *> cache;
    auto it = cache.find(M);
    if (it != cache.end()) return it->second;
    GlobalVariable *gv = new GlobalVariable(
        *M, Type::getInt64Ty(M->getContext()), /*isConstant=*/false,
        GlobalValue::PrivateLinkage,
        ConstantInt::get(Type::getInt64Ty(M->getContext()), 0),
        helperName("j"), nullptr);
    gv->setAlignment(Align(8));
    cache[M] = gv;
    return gv;
}

static void makeJunk(IRBuilder<> &JB, Function *F, Value *rt, BasicBlock *target) {
    Value *j = JB.CreateZExt(rt, JB.getInt64Ty());
    int n = 3 + (rand32() % 5);
    for (int i = 0; i < n; i++) {
        int op = rand32() % 4;
        if (op == 0)      j = JB.CreateAdd(j, JB.getInt64(rand32()));
        else if (op == 1) j = JB.CreateXor(j, JB.getInt64(rand32()));
        else if (op == 2) j = JB.CreateMul(j, JB.getInt64(rand32() | 1));
        else              j = JB.CreateSub(j, JB.getInt64(rand32()));
    }
    StoreInst *st = JB.CreateStore(j, junkGlobal(F->getParent()));
    st->setVolatile(true);
    JB.CreateBr(target);
}

static void addBogusOnce(Function *F, const std::vector<BasicBlock *> &targets, Value *rt) {
    LLVMContext &C = F->getContext();
    for (auto *orig : targets) {
        if (!orig->getParent()) continue;
        Instruction *T = orig->getTerminator();
        if (!T || T->getNumSuccessors() == 0) continue;
        if (orig->size() < 2) continue;

        BasicBlock *real = orig->splitBasicBlock(T, orig->getName() + ".r");
        orig->getTerminator()->eraseFromParent();
        IRBuilder<> B(orig);
        Value *cond = opaqueTrue(B, rt);

        int nJunk = 1 + (rand32() % 3);
        BasicBlock *first = nullptr, *prev = nullptr;
        for (int i = 0; i < nJunk; i++) {
            BasicBlock *junk = BasicBlock::Create(C, "j", F, real);
            if (!first) first = junk;
            if (prev) { IRBuilder<> PB(prev); PB.CreateBr(junk); }
            prev = junk;
        }
        if (prev) { IRBuilder<> PB(prev); makeJunk(PB, F, rt, real); }
        B.CreateCondBr(cond, real, first);
    }
}

bool runBogus(Function *F, bool on) {
    if (!funcToObfuscate(F, "bcf", on)) return false;
    if (F->isDeclaration() || F->hasPersonalityFn()) return false;
    if (F->size() < 1 || F->size() > 800) return false;

    const Config &cfg = config();
    if (cfg.bcfRounds <= 0) return false;

    Module *M = F->getParent();

    // 每函数只读一次运行时 opaque 值, 放在入口 (支配所有块)
    BasicBlock *entry = &F->getEntryBlock();
    IRBuilder<> EB(&*entry->getFirstInsertionPt());
    Value *rt = loadOpaqueState(M, EB);
    rt = EB.CreateTrunc(rt, EB.getInt32Ty(), "rt");

    // 只对函数入口时的真实块做变换 (避免轮次之间指数膨胀)
    std::vector<BasicBlock *> targets;
    for (auto &BB : *F) targets.push_back(&BB);

    for (int r = 0; r < cfg.bcfRounds; r++)
        addBogusOnce(F, targets, rt);
    return true;
}
} // namespace gco

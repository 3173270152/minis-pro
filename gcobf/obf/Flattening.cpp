// Flattening.cpp - 控制流平坦化 (LLVM 16)  v2.0
//
// v1 问题 (见《混淆器诊断与改造方案》1.5):
//   * 状态变量永远在 [x19, 0x3c] 这种固定栈偏移 → 一眼认定状态机
//   * case 值 1..N 连续且与块顺序一致 → 跳转表结构可读
//   * 所有跳转表集中在一段 (由 codegen 决定, 但 case 值连续加剧了可读性)
//
// v2 改造:
//   1. 状态值 = idx ^ K, K 每函数随机 → cmp 立即数变成随机值, 不再是 1..N
//   2. 追加占位 case (指向 default), 使 case 数量与真实块数解耦
//   3. 平坦化后对状态 alloca 跑 PromoteMemToReg → 状态进寄存器, 不再有固定栈偏移
//   4. fla:strong 再加一层运行时 opaque 的恒等扰动 (sw ^ (rt ^ rt))
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Dominators.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/PromoteMemToReg.h"
#include <vector>
#include <map>
#include <set>

using namespace llvm;
namespace gco {

static bool flatten(Function *F) {
    LLVMContext &C = F->getContext();
    const Config &cfg = config();

    /* v3: personality 不再一刀切拒绝。
     * 之前 hasPersonalityFn() 直接 return false，把 -fobjc-arc 编译出来的
     * ObjC 方法（每个都带 personality）全挡掉了 —— 这才是 fla 覆盖只有 13% 的主因。
     * 真正的安全性由下面「终止指令不许是 invoke/resume/catchswitch...」保证：
     * 只要没有任何会跳进 landingpad 的 invoke/resume，平坦化后语义就是对的。
     * （若存在 landingpad，那些块会被跳过，入口/分发块仍可平坦化） */
    if (F->size() < 2) return false;
    if (F->size() > (size_t)cfg.flaMaxBlocks) return false;
    if (F->hasFnAttribute(Attribute::OptimizeNone)) return false;

    for (auto &BB : *F) {
        Instruction *T = BB.getTerminator();
        if (!T) return false;
        if (isa<InvokeInst>(T) || isa<CallBrInst>(T) || isa<ResumeInst>(T) ||
            isa<CatchSwitchInst>(T) || isa<CatchReturnInst>(T) ||
            isa<CleanupReturnInst>(T) || isa<IndirectBrInst>(T)) return false;
        // SwitchInst 不再拒绝: >2 后继的终止指令保持原样 (直接跳到 case 块),
        // case 块的尾部仍会被改写成 "写状态 -> 回分发块", 语义正确
    }

    // 每函数独立状态密钥
    uint32_t K = (rand32() ^ (uint32_t)F->getName().size() * 2654435761u) | 1;

    BasicBlock *entry = &F->getEntryBlock();

    // 把入口原内容拆到 head, entry 只留分发初始化
    BasicBlock *head = entry->splitBasicBlock(entry->getTerminator(), "h");
    entry->getTerminator()->eraseFromParent();

    std::vector<BasicBlock *> blocks;
    for (auto &BB : *F) if (&BB != entry) blocks.push_back(&BB);
    if (blocks.empty()) return false;

    std::map<BasicBlock *, uint32_t> idx;
    for (size_t i = 0; i < blocks.size(); i++)
        idx[blocks[i]] = ((uint32_t)i + 1) ^ K;

    IRBuilder<> EB(entry);
    AllocaInst *swVar = EB.CreateAlloca(Type::getInt32Ty(C), nullptr, "st");
    EB.CreateStore(EB.getInt32(idx[head]), swVar);
    BasicBlock *loopEntry = BasicBlock::Create(C, "d", F, head);
    EB.CreateBr(loopEntry);

    // 分发块
    IRBuilder<> LB(loopEntry);
    Value *ld = LB.CreateLoad(Type::getInt32Ty(C), swVar, "v");
    if (cfg.flaStrong) {
        Value *rt = loadOpaqueState(F->getParent(), LB);
        Value *rt32 = LB.CreateTrunc(rt, LB.getInt32Ty());
        Value *zero = LB.CreateXor(rt32, rt32, "z");   // 恒 0, 但 ISel 折不掉
        ld = LB.CreateXor(ld, zero, "v2");
    }
    BasicBlock *def = BasicBlock::Create(C, "e", F, head);
    IRBuilder<> DB(def);
    DB.CreateBr(loopEntry);

    SwitchInst *sw = LB.CreateSwitch(ld, def, blocks.size() + 8);
    std::set<uint32_t> used;
    for (auto *BB : blocks) {
        used.insert(idx[BB]);
        sw->addCase(ConstantInt::get(Type::getInt32Ty(C), idx[BB]), BB);
    }
    // 占位 case: 让 case 数量与真实块数脱钩
    uint32_t nFake = (uint32_t)(blocks.size() / 2) + 2;
    for (uint32_t i = 0, guard = 0; i < nFake && guard < nFake * 16; guard++) {
        uint32_t v = (rand32() % (blocks.size() * 4 + 64)) + 1;
        if (used.count(v)) continue;
        used.insert(v);
        sw->addCase(ConstantInt::get(Type::getInt32Ty(C), v), def);
        i++;
    }

    // 改写每个块的跳转: 写状态 -> br 分发块
    for (auto *BB : blocks) {
        Instruction *T = BB->getTerminator();
        if (!T) continue;
        unsigned ns = T->getNumSuccessors();
        if (ns == 0) continue;

        if (ns == 1) {
            BasicBlock *succ = T->getSuccessor(0);
            uint32_t si = idx.count(succ) ? idx[succ] : idx[head];
            T->eraseFromParent();
            IRBuilder<> B(BB);
            B.CreateStore(B.getInt32(si), swVar);
            B.CreateBr(loopEntry);
        } else if (ns == 2) {
            auto *br = dyn_cast<BranchInst>(T);
            if (!br) continue;
            BasicBlock *s0 = br->getSuccessor(0), *s1 = br->getSuccessor(1);
            Value *cond = br->getCondition();
            uint32_t i0 = idx.count(s0) ? idx[s0] : idx[head];
            uint32_t i1 = idx.count(s1) ? idx[s1] : idx[head];
            T->eraseFromParent();
            IRBuilder<> B(BB);
            // 用 select 保留条件语义, 但值域已经过 K 打散
            Value *sel = B.CreateSelect(cond, B.getInt32(i0), B.getInt32(i1));
            B.CreateStore(sel, swVar);
            B.CreateBr(loopEntry);
        }
    }

    // alloca 归位到入口
    {
        BasicBlock *eb = &F->getEntryBlock();
        std::vector<AllocaInst *> al;
        for (auto &BB : *F)
            for (auto &I : BB)
                if (auto *A = dyn_cast<AllocaInst>(&I)) al.push_back(A);
        for (auto *A : al)
            if (A->getParent() != eb)
                A->moveBefore(*eb, eb->getFirstInsertionPt());
    }

    fixStack(F);

    // 状态变量进寄存器 (消除 "ldr w8,[x19,#0x3c]" 指纹)
    {
        DominatorTree DT(*F);
        std::vector<AllocaInst *> allocas;
        if (swVar->getParent()) allocas.push_back(swVar);
        if (!allocas.empty()) PromoteMemToReg(allocas, DT);
    }
    return true;
}

int g_flaDbg[6] = {0,0,0,0,0,0};   /* [0]进入 [1]filt拒绝 [2]size<2 [3]optnone [4]终止指令 [5]成功 */

bool runFlatten(Function *F, bool on) {
    g_flaDbg[0]++;
    if (!funcToObfuscate(F, "fla", on)) { g_flaDbg[1]++; return false; }
    const Config &cfg = config();
    if (F->size() < 2) { g_flaDbg[2]++; return false; }
    if (F->size() > (size_t)cfg.flaMaxBlocks) { g_flaDbg[2]++; return false; }
    if (F->hasFnAttribute(Attribute::OptimizeNone)) { g_flaDbg[3]++; return false; }
    for (auto &BB : *F) {
        Instruction *T = BB.getTerminator();
        if (!T) { g_flaDbg[4]++; return false; }
        if (isa<InvokeInst>(T) || isa<CallBrInst>(T) || isa<ResumeInst>(T) ||
            isa<CatchSwitchInst>(T) || isa<CatchReturnInst>(T) ||
            isa<CleanupReturnInst>(T) || isa<IndirectBrInst>(T)) { g_flaDbg[4]++; return false; }
    }
    bool r = flatten(F);
    if (r) g_flaDbg[5]++;
    return r;
}
} // namespace gco

// Split.cpp - 基本块拆分 (LLVM 16)  v2.0
//
// v2 变更:
//   * 增加块数/指令数上限, 避免巨型函数把编译时间拉爆
//   * 跳过只有 2 条指令的块 (拆完等于没拆, 只是增加 CFG 噪音)
//   * 拆分点仍然随机, 但保证不切在 PHI 之后的第一条 (splitBasicBlock 会处理)
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Instructions.h"
#include <vector>
#include <algorithm>

using namespace llvm;
namespace gco {

static bool containsPHI(BasicBlock *B) {
    for (auto &I : *B) if (isa<PHINode>(&I)) return true;
    return false;
}

static void splitBB(Function *F, int splitN) {
    std::vector<BasicBlock *> orig;
    for (auto &BB : *F) orig.push_back(&BB);

    for (auto *curr : orig) {
        if (!curr->getParent()) continue;
        if (curr->size() < 3 || containsPHI(curr)) continue;

        int n = splitN;
        if ((size_t)n >= curr->size()) n = (int)curr->size() - 1;
        if (n < 1) continue;

        std::vector<int> pts;
        for (unsigned i = 1; i < curr->size(); ++i) pts.push_back((int)i);
        if (pts.size() > 1) {
            for (int i = (int)pts.size() - 1; i > 0; --i)
                std::swap(pts[i], pts[rand32() % (i + 1)]);
            std::sort(pts.begin(), pts.begin() + n);
        }

        BasicBlock::iterator it = curr->begin();
        BasicBlock *toSplit = curr;
        int last = 0;
        for (int i = 0; i < n; ++i) {
            for (int j = 0; j < pts[i] - last; ++j) ++it;
            last = pts[i];
            if (toSplit->size() < 2) continue;
            toSplit = toSplit->splitBasicBlock(it, toSplit->getName() + ".s");
            it = toSplit->begin();
        }
    }
}

bool runSplit(Function *F, bool on) {
    if (!funcToObfuscate(F, "split", on)) return false;
    if (F->isDeclaration() || F->hasPersonalityFn()) return false;
    if (F->size() > 800) return false;
    splitBB(F, 3);
    return true;
}
} // namespace gco

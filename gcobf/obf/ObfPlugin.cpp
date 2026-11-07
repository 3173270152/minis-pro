// ObfPlugin.cpp - LLVM 16 混淆 Pass 插件 (ollvm 功能移植)  v2.3
//
// v2 变更:
//   * 配置只解析一次 (v1 每个 pass 每个函数都 getenv + strstr)
//   * sobf 先跑, 生成的 helper 自动进 skip 集合 (v1 会把解码函数也平坦化/替换)
//   * 新增 msym (导出符号哈希化)
//   * 函数列表先快照再遍历, 避免遍历中插入新函数
//   * 末尾打印一行统计, 不再刷屏
// v2.1:
//   * 新增 frag (常量碎片化)。frag 是模块级 (共用一张 volatile 常量表),
//     必须放在函数循环之后、wipe 之前; wipe 之后不再碰任何指令。
// v2.2:
//   * cenc 与 frag 共用同一张表, 统一在函数循环后 fragTableSync 一次
// v2.3:
//   * ★ 移除 adp (bitcode 链接) —— 实测会在真实工程上让 clang 本体 exit 139 崩溃
//     (反调试模块带 stdio+pthread 后 parseBitcodeFile/linkModules 阶段崩)。
//     深度反调试改为「源码集成」: 把 AntiDebug/anti_debug_pro.c 直接加进工程源码列表,
//     再用 GCOBF_SKIP=adbg_ 让 fla/bcf 不碰它。详见 README 第 X 节。
#include "ObfUtils.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"
#include <vector>
#include <cstdlib>

using namespace llvm;

namespace gco {
bool runFlatten(Function *F, bool on);
extern int g_flaDbg[6];
bool runSplit(Function *F, bool on);
bool runSub(Function *F, bool on);
bool runBogus(Function *F, bool on);
bool runStringObf(Module *M, bool on);
bool runConstEnc(Function *F, bool on);
int  runConstFrag(Module *M, bool on);
void fragTableSync(Module *M);
bool runSymbolObf(Module *M, bool on);
bool runDeadCode(Module *M, int count);
bool runAntiTamper(Module *M, bool anti, bool integ);
int runBodyWipe(Module *M, const std::vector<std::string> &pats);
}

namespace {

// 收集 init_array 里的构造函数, 这些不能混淆 (会破坏初始化顺序)
static void collectCtors(Module &M) {
    GlobalVariable *ctors = M.getGlobalVariable("llvm.global_ctors");
    if (!ctors || !ctors->hasInitializer()) return;
    auto *ca = dyn_cast<ConstantArray>(ctors->getInitializer());
    if (!ca) return;
    for (unsigned i = 0; i < ca->getNumOperands(); i++) {
        auto *cs = dyn_cast<ConstantStruct>(ca->getOperand(i));
        if (!cs || cs->getNumOperands() < 2) continue;
        if (auto *fn = dyn_cast<Function>(cs->getOperand(1)->stripPointerCasts()))
            gco::g_skip.insert(fn->getName().str());
    }
}

struct ObfPass : PassInfoMixin<ObfPass> {
    PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
        const gco::Config &cfg = gco::config();
        collectCtors(M);

        int nFla = 0, nSub = 0, nBcf = 0, nSplit = 0, nCenc = 0, nFrag = 0;

        // 模块级: 先注入假函数, 再加密字符串 (假函数里的字符串也会被加密)
        if (cfg.deadCount > 0) gco::runDeadCode(&M, cfg.deadCount);
        if (cfg.sobf) gco::runStringObf(&M, true);
        if (cfg.anti || cfg.integ) gco::runAntiTamper(&M, cfg.anti, cfg.integ);

        std::vector<Function *> funcs;
        for (Function &F : M) funcs.push_back(&F);

        for (Function *F : funcs) {
            if (!F->getParent()) continue;              // 可能已被删除
            if (F->isDeclaration()) continue;
            // 顺序: bcf(原结构加虚假块) -> fla -> split -> sub -> cenc
            if (cfg.bcf   && gco::runBogus(F, true))   nBcf++;
            if (cfg.fla   && gco::runFlatten(F, true)) nFla++;
            if (cfg.split && gco::runSplit(F, true))   nSplit++;
            if (cfg.sub   && gco::runSub(F, true))     nSub++;
            if (cfg.cenc  && gco::runConstEnc(F, true)) nCenc++;
        }

        // ★ frag 必须晚于 cenc: cenc 生成的 (v^A) 常量本身也可以再被碎片化
        if (cfg.frag) nFrag = gco::runConstFrag(&M, true);
        // ★ cenc 与 frag 共用同一张表: cenc 只分配槽不同步, 必须在这里统一 sync
        if (cfg.cenc || cfg.frag) gco::fragTableSync(&M);

        bool msym = false;
        if (cfg.msym) msym = gco::runSymbolObf(&M, true);
        /* ★ 函数体抹除必须放在【所有 pass 之后】：
         *   否则后面对 ret 桩再跑 fla/bcf/sub，桩又被混淆成复杂代码，抹除失效。 */
        if (cfg.wipe && !cfg.wipePats.empty()) gco::runBodyWipe(&M, cfg.wipePats);

        (void)msym;

        errs() << "[GCObf-fa] 进入=" << gco::g_flaDbg[0]
               << " 过滤拒=" << gco::g_flaDbg[1]
               << " 太小吃=" << gco::g_flaDbg[2]
               << " optnone=" << gco::g_flaDbg[3]
               << " 异常指令=" << gco::g_flaDbg[4]
               << " 成功=" << gco::g_flaDbg[5] << "\n";
        errs() << "[GCObf] seed=0x" << Twine::utohexstr(cfg.seed)
               << " fla=" << nFla << " sub=" << nSub << " bcf=" << nBcf
               << " split=" << nSplit << " cenc=" << nCenc
               << " frag=" << nFrag
               << " msym=" << (cfg.msym ? 1 : 0) << "\n";
        bool anyFuncPass = cfg.fla || cfg.sub || cfg.bcf || cfg.split ||
                           cfg.cenc || cfg.frag;
        if (anyFuncPass && nFla + nSub + nBcf + nSplit + nCenc + nFrag == 0)
            errs() << "[GCObf] 提示: 0 个函数被混淆。常见原因: -O0 编译 (函数带 optnone)、"
                      "GCOBF_ONLY 过滤过严、或函数体太小被跳过。\n";

        return PreservedAnalyses::none();
    }
};
}

extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
    return { LLVM_PLUGIN_API_VERSION, "GCObf", "2.3", [](PassBuilder &PB) {
        PB.registerOptimizerLastEPCallback([](ModulePassManager &MPM, OptimizationLevel) {
            MPM.addPass(ObfPass());
        });
    }};
}

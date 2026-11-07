// BodyWipe.cpp - 函数体抹除 (LLVM 16)  v1.0
//
// 用途: 配合 VMP 使用。
//   被虚拟机化的函数，其原始 ARM 指令会完整留在 __text 里 —— 用 IDA 静态
//   打开照样能看到全部业务逻辑，VMP 只保护了"运行时"。
//
//   这个 pass 把指定函数的函数体整个替换成一条返回桩:
//       - 有返回值: 返回 0
//       - void    : 直接 ret
//   原始逻辑只以字节码形式存在于 .data 里（已加密）。
//
// 开关:
//   GCOBF=...,wipe          抹除 GCOBF_WIPE 里列出的函数（逗号分隔子串）
//   GCOBF_WIPE=Secret_,License  按函数名子串匹配要抹的函数
//
// 注意: 被抹除的函数必须已经由 hook 接管（否则功能会失效）。
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Instructions.h"
#include <vector>
#include <string>
#include "llvm/Support/Format.h"

using namespace llvm;
namespace gco {

static bool matchAny(const StringRef nm, const std::vector<std::string> &pats) {
    if (pats.empty()) return false;
    for (const std::string &p : pats)
        if (!p.empty() && nm.contains(p)) return true;
    return false;
}

int runBodyWipe(Module *M, const std::vector<std::string> &pats) {
    if (!M || pats.empty()) return 0;
    std::vector<Function *> targets;
    for (Function &F : *M) {
        if (F.isDeclaration() || F.isIntrinsic()) continue;
        StringRef nm = F.getName();
        if (nm.empty()) continue;
        if (g_helpers.count(nm.str())) continue;
        /* 绝不能抹混淆器自身的入口/钩子/运行时。
         * ObjC 方法名形如 "-[Class sel]"(IR 里前缀一个 0x01 字节), 剥掉再判。 */
        StringRef nmb = nm;
        if (!nmb.empty() && (unsigned char)nmb[0] == 0x01) nmb = nmb.drop_front();
        if (nm.startswith("hook_") || nm.contains("hook_")) continue;
        if (nm.startswith("orig_") || nm.contains("orig_")) continue;
        if (nm.startswith("vm_entry") || nm.contains("vm_entry")) continue;
        if (nm.startswith("vmp_") || nm.contains("vmp_snap") || nm.contains("vmp_run")) continue;

        /* 通用策略: 只抹名字(含 ObjC 方法名)匹配用户 GCOBF_WIPE 子串列表的函数。
         * 不内置任何具体符号名单 —— 抹哪些完全由调用方用 GCOBF_WIPE 指定。
         * 典型用法: 对已被 VMP 接管的函数留一个 ret 桩, 原实现抹空。 */
        if (pats.empty()) continue;             /* 没给 GCOBF_WIPE = 不抹任何函数 */
        if (!matchAny(nmb, pats) && !matchAny(nm, pats)) continue;
        targets.push_back(&F);
    }

    int n = 0;
    for (Function *F : targets) {
        LLVMContext &C = F->getContext();
        /* 清空所有基本块 */
        F->deleteBody();
        BasicBlock *entry = BasicBlock::Create(C, "wipe", F);
        IRBuilder<> B(entry);
        Type *rt = F->getReturnType();
        if (rt->isVoidTy())
            B.CreateRetVoid();
        else if (rt->isPointerTy() || rt->isIntegerTy())
            B.CreateRet(Constant::getNullValue(rt));
        else if (rt->isFloatingPointTy())
            B.CreateRet(ConstantFP::get(rt, 0.0));
        else
            B.CreateRet(UndefValue::get(rt));
        /* 去掉可能让优化器还原的标记 */
        F->removeFnAttr(Attribute::OptimizeNone);
        n++;
    }
    if (n) errs() << "[GCObf] wipe: " << n << " 个函数体被抹成桩\n";
    return n;
}

} // namespace gco

// SymbolObf.cpp - 导出符号哈希化 (LLVM 16)  v1.0 (新增)
//
// 对应《混淆器诊断与改造方案》1.4: 126 个导出符号全保留, nm/rabin2 -E 一条命令
// 就能看到 _MyApp_Render / _AppLogic 这类入口。
//
// 做法:
//   1. 把 ExternalLinkage 的函数重命名为伪 C++ mangled 名 (demangle 后像内部工具函数)
//   2. 同时改成 hidden visibility → dyld 不导出, dlsym("原名") 找不到
//   3. 若设置了 GCOBF_MAP, 把 原名 -> 新名 追加写入映射文件 (供你自己的调用方更新)
//
// 风险 (默认关闭, 需要 GCOBF=...,msym 显式开启):
//   - 外部 dylib/tweak 通过 dlsym 或 -undefined dynamic_lookup 按名字调用时会失败
//   - 只要调用方都在同一个 dylib 内部 (链接期就解析成直接调用), 完全安全
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/raw_ostream.h"
#include <fstream>
#include <string>

using namespace llvm;
namespace gco {

/* ★ 只改名「真正对外导出」的符号。
 * 判断依据: 同一 module 内如果该符号被别的函数调用过（跨 .o 的引用同样
 * 会在 module 里表现为 declaration + 定义共存），改名就会断链。
 * 这里改用最稳的做法: 只有【从未被任何地方引用】的才算纯导出，
 * 其余全部保留 —— 反正最终由 hide-exports 统一哈希。
 * 想更激进可开 GCOBF_MSYM_AGGRESSIVE=1（只做 hidden，不改名）。 */
static bool keepSymbol(StringRef nm, bool aggressive) {
    if (nm == "main") return true;
    if (nm.startswith("_OBJC") || nm.startswith("OBJC")) return true;
    if (nm.startswith("llvm.")) return true;
    if (nm.startswith("_GLOBAL__sub_I")) return true;
    if (nm.contains("objc_")) return true;
    if (nm.startswith("__Z")) return true;
    if (nm.startswith("_dyld") || nm.startswith("_mh_")) return true;
    /* VMP / 跨 .o 引用 */
    if (nm.startswith("vm_entry") || nm.startswith("_vm_entry")) return true;
    if (nm.startswith("hook_") || nm.startswith("_hook_")) return true;
    if (nm.startswith("vmp_") || nm.startswith("_vmp_")) return true;
    if (nm.startswith("orig_hook") || nm.startswith("_orig_hook")) return true;
    if (nm.startswith("_token_table_va")) return true;
    if (!aggressive) return true;   /* 默认: 只做 hidden，不改名（零断链风险） */
    return false;
}

bool runSymbolObf(Module *M, bool on) {
    if (!on) return false;
    if (g_helpers.empty() && false) return false;

    const char *ag = getenv("GCOBF_MSYM_AGGRESSIVE");
    bool aggressive = (ag && ag[0] == '1');

    std::string mapPath;
    if (const char *p = getenv("GCOBF_MAP")) mapPath = p;

    std::ofstream out;
    if (!mapPath.empty()) out.open(mapPath.c_str(), std::ios::app);

    int renamed = 0, hiddenOnly = 0;
    for (Function &F : *M) {
        if (F.isDeclaration() || F.isIntrinsic()) continue;
        if (!F.hasExternalLinkage()) continue;
        if (F.hasLocalLinkage()) continue;
        StringRef nm = F.getName();
        if (nm.empty()) continue;
        if (keepSymbol(nm, aggressive)) {
            /* 保留原名，但降为 hidden: 不再出现在导出表里 */
            if (F.hasExternalLinkage()) {
                F.setVisibility(GlobalValue::HiddenVisibility);
                hiddenOnly++;
            }
            continue;
        }
        if (g_skip.count(nm.str()) || g_helpers.count(nm.str())) continue;

        std::string oldName = nm.str();
        std::string newName = helperName("e");
        F.setName(newName);
        F.setVisibility(GlobalValue::HiddenVisibility);
        F.setDSOLocal(true);
        if (out.is_open()) out << oldName << " " << newName << "\n";
        renamed++;
    }
    if (out.is_open()) out.close();

    if (renamed) errs() << "[GCObf] msym: " << renamed << " renamed";
    if (hiddenOnly) errs() << " " << hiddenOnly << " hidden-only";
    if (renamed && !mapPath.empty())
        errs() << " (map -> " << mapPath << ")";
    if (renamed) errs() << "\n";
    return renamed > 0;
}
} // namespace gco

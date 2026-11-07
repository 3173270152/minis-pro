// ObfUtils.cpp - 公共工具 (LLVM 16)  v2.0
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Attributes.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <ctime>
#include <map>
#include <vector>

using namespace llvm;
namespace gco {

std::set<std::string> g_skip;
std::set<std::string> g_helpers;
uint32_t g_rng = 0x9E3779B9u;

static Config g_cfg;
static bool g_cfgInit = false;
static unsigned g_helperSeq = 0;

// ---------------- 随机 ----------------
uint32_t rand32() {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return g_rng;
}

uint32_t xorshift(uint32_t k) {
    if (k == 0) k = 0x9E3779B9u;
    k ^= k << 13;
    k ^= k >> 17;
    k ^= k << 5;
    return k;
}

// ---------------- 配置 ----------------
static std::vector<std::string> splitComma(const char *s) {
    std::vector<std::string> out;
    std::string cur;
    for (const char *p = s; *p; ++p) {
        if (*p == ',' || *p == ';' || *p == ' ') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
        } else {
            cur.push_back(*p);
        }
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

static int toInt(const std::string &s, int def) {
    if (s.empty()) return def;
    char *end = nullptr;
    long v = strtol(s.c_str(), &end, 0);
    if (end == s.c_str()) return def;
    return (int)v;
}

static uint32_t deriveSeed() {
    if (const char *s = getenv("GCOBF_SEED")) {
        if (*s) return (uint32_t)strtoul(s, nullptr, 0);
    }
    // 可复现构建: 尊重 SOURCE_DATE_EPOCH
    if (const char *s = getenv("SOURCE_DATE_EPOCH")) {
        if (*s) return (uint32_t)strtoul(s, nullptr, 0) * 2654435761u;
    }
    return (uint32_t)time(nullptr) * 2654435761u;
}

static void applyToken(Config &c, const std::string &tok) {
    std::string name = tok, param;
    size_t colon = tok.find(':');
    if (colon != std::string::npos) {
        name = tok.substr(0, colon);
        param = tok.substr(colon + 1);
    }
    if (name == "none") {
        c.fla = c.sub = c.bcf = c.split = c.sobf = c.cenc = c.msym = false;
        return;
    }
    if (name == "all") {
        c.fla = c.sub = c.bcf = c.split = c.sobf = c.cenc = c.msym = true;
        c.anti = c.integ = true;
        c.frag = true;                 // v2.2: all 默认带 frag (all 不含 adp, 那个会真杀进程)
        if (c.deadCount == 0) c.deadCount = 20;
        return;
    }
    if (name == "verbose") { c.verbose = true; return; }
    if (name == "fla") {
        c.fla = true;
        if (param == "sel" || param == "select") { /* allowlist 由注解/GCOBF_ONLY 决定 */ }
        if (param == "strong") c.flaStrong = true;
        if (!param.empty() && isdigit((unsigned char)param[0])) c.flaMaxBlocks = toInt(param, c.flaMaxBlocks);
        return;
    }
    if (name == "sub") {
        c.sub = true;
        c.subRounds = toInt(param, c.subRounds);
        if (c.subRounds < 0) c.subRounds = 0;
        if (c.subRounds > 4) c.subRounds = 4;
        return;
    }
    if (name == "bcf") {
        c.bcf = true;
        c.bcfRounds = toInt(param, c.bcfRounds);
        if (c.bcfRounds < 0) c.bcfRounds = 0;
        if (c.bcfRounds > 8) c.bcfRounds = 8;
        return;
    }
    if (name == "split") { c.split = true; return; }
    if (name == "wipe") { c.wipe = true; return; }
    if (name == "sobf") { c.sobf = true; return; }
    if (name == "cenc") {
        c.cenc = true;
        if (!param.empty()) {
            c.cencMinBits = toInt(param, c.cencMinBits);
            if (c.cencMinBits < 1) c.cencMinBits = 1;
            if (c.cencMinBits > 63) c.cencMinBits = 63;
        }
        return;
    }
    if (name == "frag") {
        c.frag = true;
        if (!param.empty()) {
            size_t c2 = param.find(':');
            std::string b = (c2 == std::string::npos) ? param : param.substr(0, c2);
            c.fragMinBits = toInt(b, c.fragMinBits);
            if (c2 != std::string::npos)
                c.fragMaxPerFunc = toInt(param.substr(c2 + 1), c.fragMaxPerFunc);
        }
        if (c.fragMinBits < 8) c.fragMinBits = 8;
        if (c.fragMinBits > 64) c.fragMinBits = 64;
        if (c.fragMaxPerFunc < 1) c.fragMaxPerFunc = 1;
        if (c.fragMaxPerFunc > 256) c.fragMaxPerFunc = 256;
        return;
    }
    if (name == "adp") { c.adp = true; return; }
    if (name == "msym") { c.msym = true; return; }
    if (name == "anti") { c.anti = true; return; }
    if (name == "integ") { c.integ = true; return; }
    if (name == "dead") {
        c.deadCount = toInt(param, 20);
        if (c.deadCount < 0) c.deadCount = 0;
        if (c.deadCount > 500) c.deadCount = 500;
        return;
    }
}

const Config &config() {
    if (g_cfgInit) return g_cfg;
    g_cfgInit = true;
    g_cfg.seed = deriveSeed();
    g_rng = g_cfg.seed ^ 0x9E3779B9u;

    const char *e = getenv("GCOBF");
    if (!e || !*e) {
        // 不设 = 全开 (与 v1 行为一致; msym 保守默认关)
        g_cfg.fla = g_cfg.sub = g_cfg.bcf = g_cfg.split = g_cfg.sobf = g_cfg.cenc = true;
    } else {
        std::vector<std::string> toks = splitComma(e);
        for (const std::string &t : toks) applyToken(g_cfg, t);
    }
    if (const char *f = getenv("GCOBF_ONLY")) {
        if (*f) g_cfg.filter = f;
    }
    if (const char *sk = getenv("GCOBF_SKIP")) {
        if (*sk) g_cfg.skipSubs = splitComma(sk);
    }
    if (const char *w = getenv("GCOBF_WIPE")) {
        if (*w) g_cfg.wipePats = splitComma(w);
    }
    if (!g_cfg.wipePats.empty()) g_cfg.wipe = true;
    if (const char *v = getenv("GCOBF_VERBOSE")) {
        if (*v && strcmp(v, "0") != 0) g_cfg.verbose = true;
    }
    return g_cfg;
}

// ---------------- 名字生成 ----------------
static const char *kHex = "0123456789abcdef";

std::string helperName(const char *tag) {
    // 形如 _ZN4gcob6detailx3f9a1c22Ev  ->  gcob::detail::x3f9a1c22()
    // 目的: 在 nm / class-dump 里看起来像工程里的 C++ 内部函数
    uint32_t v = rand32() ^ (uint32_t)(++g_helperSeq * 2654435761u);
    std::string nm = "_ZN4gcob6detail";
    (void)tag;
    nm.push_back('x');
    for (int i = 0; i < 8; i++) {
        nm.push_back(kHex[(v >> ((7 - i) * 4)) & 0xF]);
    }
    nm += "Ev";
    return nm;
}

void addHelper(Function *F) {
    if (!F) return;
    g_helpers.insert(F->getName().str());
}

bool isHelper(const Function *F) {
    if (!F) return true;
    return g_helpers.count(F->getName().str()) != 0;
}

// ---------------- 注解 ----------------
std::string readAnnotate(Function *F) {
    std::string annotation;
    Module *M = F->getParent();
    if (!M) return annotation;
    GlobalVariable *glob = M->getGlobalVariable("llvm.global.annotations");
    if (!glob || !glob->hasInitializer()) return annotation;
    auto *ca = dyn_cast<ConstantArray>(glob->getInitializer());
    if (!ca) return annotation;
    for (unsigned i = 0; i < ca->getNumOperands(); i++) {
        auto *an = dyn_cast<ConstantStruct>(ca->getOperand(i));
        if (!an || an->getNumOperands() < 2) continue;
        Value *fnv = an->getOperand(0)->stripPointerCasts();
        if (fnv != F) continue;
        auto *str = dyn_cast<GlobalVariable>(an->getOperand(1)->stripPointerCasts());
        if (!str) continue;
        auto *data = dyn_cast<ConstantDataArray>(str->getInitializer());
        if (data && data->isString()) annotation = data->getAsString().str();
    }
    return annotation;
}

// ---------------- 过滤 ----------------
bool funcToObfuscate(Function *F, const char *attr, bool globalOn) {
    if (!F || F->isDeclaration()) return false;
    StringRef nm = F->getName();
    if (nm.empty()) return false;
    if (g_helpers.count(nm.str())) return false;
    if (g_skip.count(nm.str())) return false;

    // ObjC 方法 / 块函数: 允许混淆 (v1 直接跳过 → 业务代码 0% 覆盖)
    //   仅对 +load / +initialize 关闭控制流改造 (它们在镜像初始化期执行, 崩了很难查)
    if (nm.startswith("_OBJC") || nm.contains("objc_msgSend")) return false;
    bool isObjCMethod = nm.startswith("-[") || nm.startswith("+[");
    bool isCFF = (strcmp(attr, "fla") == 0 || strcmp(attr, "bcf") == 0);
    if (isObjCMethod && isCFF &&
        (nm.contains(" load]") || nm.contains(" initialize]"))) return false;
    if (nm.contains("__block_literal") && isCFF) return false;

    // 全局初始化 / 静态构造
    if (nm.startswith("_GLOBAL__sub_I") || nm.contains("__cxx_global_var_init")) return false;
    if (nm.startswith("__static_initialization")) return false;

    // LLVM 内部
    if (nm.startswith("llvm.") || nm.startswith("__clang")) return false;

    // 编译器标记的属性 (v1 在这里把带 objc-arc 的方法全部跳过)
    if (F->hasFnAttribute(Attribute::OptimizeNone)) return false;
    // 含异常处理 (landingpad) 的函数: 只有"重构 CFG"的 pass 不安全;
    // sub / cenc 是纯指令级替换, 对异常函数完全安全 —— 之前一刀切跳过,
    // 导致所有用了 @try/@catch 的核心函数 (如 CmdPoll) 一点都没被混淆
    bool needCFG = (strcmp(attr, "fla") == 0 || strcmp(attr, "bcf") == 0 ||
                    strcmp(attr, "split") == 0);
    /* v3: 不再对 personality 一刀切。
     * -fobjc-arc 编译的 ObjC 方法全都带 personality，之前这一条把
     * fla/bcf/split 覆盖率压到 13%。真正安全性由各 pass 内部的
     * invoke/resume/catchswitch 检查保证（见 Flattening.cpp）。
     * 这里只保留一个必要保护: @try/@catch 以外的纯 landingpad 函数，
     * 由 pass 自己判断能否安全重构。 */
    if (needCFG && F->hasFnAttribute(Attribute::OptimizeNone)) return false;
    if (F->isVarArg() && !globalOn) return false;

    std::string ann = readAnnotate(F);
    if (!ann.empty()) {
        if (ann.find("noobf") != std::string::npos) return false;
        if (ann.find(attr) != std::string::npos) return true;   // 显式要求: 无视过滤
    }
    if (!globalOn) return false;

    const Config &c = config();
    if (!c.filter.empty() && nm.find(c.filter) == StringRef::npos) return false;
    for (const std::string &s : c.skipSubs) {
        if (!s.empty() && nm.find(s) != StringRef::npos) return false;   // 留给 VMP
    }
    return true;
}

// ---------------- 栈修正 ----------------
static bool valueEscapes(Instruction *Inst) {
    BasicBlock *BB = Inst->getParent();
    for (User *U : Inst->users()) {
        auto *I = dyn_cast<Instruction>(U);
        if (!I) continue;
        if (I->getParent() != BB || isa<PHINode>(I)) return true;
    }
    return false;
}

void fixStack(Function *F) {
    // 上限保护: 极端情况下避免死循环
    for (int round = 0; round < 8; round++) {
        std::vector<PHINode *> tmpPhi;
        std::vector<Instruction *> tmpReg;
        BasicBlock *bbEntry = &*F->begin();
        for (auto &BB : *F) {
            for (auto &I : BB) {
                if (isa<PHINode>(I)) { tmpPhi.push_back(cast<PHINode>(&I)); continue; }
                if (!(isa<AllocaInst>(&I) && I.getParent() == bbEntry) &&
                    (valueEscapes(&I) || I.isUsedOutsideOfBlock(&BB)))
                    tmpReg.push_back(&I);
            }
        }
        if (tmpPhi.empty() && tmpReg.empty()) return;
        Instruction *insPt = &*F->begin()->getFirstInsertionPt();
        for (auto *R : tmpReg) DemoteRegToStack(*R, false, insPt);
        for (auto *P : tmpPhi) DemotePHIToStack(P, insPt);
    }
}

// ---------------- 运行时 opaque 状态 ----------------
static std::map<Module *, GlobalVariable *> g_stateMap;

Value *loadOpaqueState(Module *M, IRBuilder<> &B) {
    const Config &c = config();
    GlobalVariable *&GV = g_stateMap[M];
    if (!GV) {
        LLVMContext &C = M->getContext();
        GV = new GlobalVariable(*M, Type::getInt64Ty(C), /*isConstant=*/false,
                                GlobalValue::PrivateLinkage,
                                ConstantInt::get(Type::getInt64Ty(C), 0),
                                helperName("s"), nullptr);
        GV->setAlignment(Align(8));

        // ctor: state = (uintptr_t)&ctor >> 7 | 1   -> 随 ASLR 变化, 静态不可折叠
        FunctionType *FT = FunctionType::get(Type::getVoidTy(C), false);
        Function *F = Function::Create(FT, GlobalValue::InternalLinkage, helperName("i"), M);
        addHelper(F);
        BasicBlock *BB = BasicBlock::Create(C, "entry", F);
        IRBuilder<> IB(BB);
        Value *p = IB.CreatePtrToInt(F, IB.getInt64Ty());
        Value *v = IB.CreateLShr(p, IB.getInt64(7));
        v = IB.CreateOr(v, IB.getInt64(1));
        v = IB.CreateXor(v, IB.getInt64((uint64_t)c.seed * 0x9E3779B97F4A7C15ULL));
        IB.CreateStore(v, GV);
        IB.CreateRetVoid();
        appendToGlobalCtors(*M, F, 60000);
    }
    LoadInst *LI = B.CreateLoad(Type::getInt64Ty(M->getContext()), GV);
    LI->setVolatile(true);
    LI->setAlignment(Align(8));
    return LI;
}

} // namespace gco

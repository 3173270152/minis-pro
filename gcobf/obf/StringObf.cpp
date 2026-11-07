// StringObf.cpp - 字符串混淆 (LLVM 16)  v2.0
//
// v1 问题 (见《混淆器诊断与改造方案》1.2 / 1.3):
//   * 只处理 [N x i8], 完全漏掉 __TEXT,__ustring 的 UTF-16 中文串 (197 条全裸)
//   * 单字节静态 XOR key, 255 次暴力/频率分析即可还原
//   * 解码函数对每个字节展开一条 store, 一个 197 串的模块生成上千条指令
//
// v2 设计:
//   1. 同时支持 i8 (__cstring) 与 i16 (__ustring), 统一按"字节池"处理
//   2. 每串独立的 32 位 xorshift keystream, 逐字节滚动 → 单字节统计攻击失效
//   3. 所有串共享 1 个解码函数 + 1 个 ctor, 每条串只占 ~10 条指令
//   4. 全模块只有一个混淆常量, 且以 (A ^ B) 形式隐藏
//   5. 跳过 ObjC 元数据 (__objc_*), 跳过非指针安全的 ConstantExpr 用户
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Dominators.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"
#include "llvm/Transforms/Utils/PromoteMemToReg.h"
#include "llvm/Support/raw_ostream.h"
#include <vector>
#include <set>
#include <string>

using namespace llvm;
namespace gco {

namespace {

struct Item {
    GlobalVariable *gv;
    uint32_t n;     // 元素个数 (i8: 字节, i16: 码元)
    bool wide;
};

// 该 global 的所有 ConstantExpr 用户是否都是"指针搬运"类
static bool usersAreSafe(GlobalVariable *GV) {
    for (User *U : GV->users()) {
        auto *CE = dyn_cast<ConstantExpr>(U);
        if (!CE) continue;
        switch (CE->getOpcode()) {
        case Instruction::GetElementPtr:
        case Instruction::BitCast:
        case Instruction::AddrSpaceCast:
        case Instruction::PtrToInt:
            break;
        default:
            return false;   // 比如 ptrtoint 参与算术: 加密会改变语义
        }
    }
    return true;
}

static bool isCandidate(GlobalVariable &GV, bool &wide) {
    if (!GV.hasInitializer() || !GV.isConstant()) return false;
    auto *CDS = dyn_cast<ConstantDataSequential>(GV.getInitializer());
    if (!CDS) return false;

    Type *et = CDS->getElementType();
    if (et->isIntegerTy(8))       wide = false;
    else if (et->isIntegerTy(16)) wide = true;
    else return false;

    StringRef sec = GV.getSection();
    if (sec.contains("objc")) return false;
    if (sec.contains("llvm.metadata")) return false;
    if (sec.contains("__const")) return false;

    // 只动 __cstring / __ustring / 无段
    if (!sec.empty()) {
        if (wide) {
            if (!sec.contains("__ustring")) return false;
        } else {
            if (!sec.contains("__cstring") && !sec.contains("__ustring")) return false;
        }
    }

    StringRef nm = GV.getName();
    if (nm.startswith("llvm.") || nm.startswith("OBJC")) return false;
    if (nm.contains("OBJC")) return false;

    uint64_t n = CDS->getNumElements();
    if (wide) { if (n < 2) return false; }   // v2.1: 2 字短串也覆盖 (原为 4)
    else      { if (n < 5) return false; }

    if (!usersAreSafe(&GV)) return false;
    return true;
}

// ---------------- 编码 (与解码函数严格对称) ----------------
static void encodeInPlace(std::vector<uint8_t> &buf, uint32_t key, bool wide) {
    uint32_t k = key | 1;
    if (wide) {
        for (size_t i = 0; i + 1 < buf.size(); i += 2) {
            k = xorshift(k);
            uint16_t u = (uint16_t)((uint16_t)buf[i] | ((uint16_t)buf[i + 1] << 8));
            u ^= (uint16_t)(k >> 8);
            buf[i]     = (uint8_t)(u & 0xFF);
            buf[i + 1] = (uint8_t)(u >> 8);
        }
    } else {
        for (size_t i = 0; i < buf.size(); i++) {
            k = xorshift(k);
            buf[i] ^= (uint8_t)(k >> 8);
        }
    }
}

// 与 xorshift() 位运算完全一致, 但生成 IR
static Value *xorshiftIR(IRBuilder<> &B, Value *k) {
    Value *s1 = B.CreateShl(k, B.getInt32(13));
    Value *x1 = B.CreateXor(k, s1);
    Value *s2 = B.CreateLShr(x1, B.getInt32(17));
    Value *x2 = B.CreateXor(x1, s2);
    Value *s3 = B.CreateShl(x2, B.getInt32(5));
    return B.CreateXor(x2, s3);
}

// ---------------- 解码函数 void (ptr p, i32 n, i32 key) ----------------
static Function *makeDecoder(Module *M, bool wide) {
    LLVMContext &C = M->getContext();
    Type *elemTy = wide ? Type::getInt16Ty(C) : Type::getInt8Ty(C);
    Type *i32 = Type::getInt32Ty(C);
    Type *ptrTy = PointerType::get(C, 0);

    FunctionType *FT = FunctionType::get(Type::getVoidTy(C), {ptrTy, i32, i32}, false);
    Function *F = Function::Create(FT, GlobalValue::InternalLinkage, helperName("d"), M);
    addHelper(F);
    F->addFnAttr(Attribute::NoInline);
    F->addFnAttr(Attribute::NoUnwind);
    F->setCallingConv(CallingConv::C);

    Value *argP = F->getArg(0);
    Value *argN = F->getArg(1);
    Value *argK = F->getArg(2);
    argP->setName("p"); argN->setName("n"); argK->setName("key");

    BasicBlock *entry = BasicBlock::Create(C, "entry", F);
    BasicBlock *cond  = BasicBlock::Create(C, "cond", F);
    BasicBlock *body  = BasicBlock::Create(C, "body", F);
    BasicBlock *exit  = BasicBlock::Create(C, "exit", F);

    IRBuilder<> B(entry);
    AllocaInst *pa = B.CreateAlloca(ptrTy, nullptr, "pa");
    AllocaInst *na = B.CreateAlloca(i32, nullptr, "na");
    AllocaInst *ia = B.CreateAlloca(i32, nullptr, "ia");
    AllocaInst *ka = B.CreateAlloca(i32, nullptr, "ka");
    B.CreateStore(argP, pa);
    B.CreateStore(argN, na);
    B.CreateStore(B.CreateOr(argK, B.getInt32(1)), ka);
    B.CreateStore(B.getInt32(0), ia);
    B.CreateBr(cond);

    B.SetInsertPoint(cond);
    Value *iv = B.CreateLoad(i32, ia, "i");
    Value *nv = B.CreateLoad(i32, na, "nn");
    B.CreateCondBr(B.CreateICmpULT(iv, nv), body, exit);

    B.SetInsertPoint(body);
    Value *kv = B.CreateLoad(i32, ka, "k");
    Value *k2 = xorshiftIR(B, kv);
    B.CreateStore(k2, ka);

    Value *pv  = B.CreateLoad(ptrTy, pa, "pp");
    Value *idx = B.CreateLoad(i32, ia, "ii");
    Value *ep  = B.CreateGEP(elemTy, pv, idx);
    Value *cur = B.CreateLoad(elemTy, ep);
    Value *ks  = B.CreateLShr(k2, B.getInt32(8));
    Value *ksT = B.CreateTrunc(ks, elemTy);
    B.CreateStore(B.CreateXor(cur, ksT), ep);

    Value *inc = B.CreateAdd(idx, B.getInt32(1));
    B.CreateStore(inc, ia);
    B.CreateBr(cond);

    B.SetInsertPoint(exit);
    B.CreateRetVoid();

    std::vector<AllocaInst *> allocas{pa, na, ia, ka};
    DominatorTree DT(*F);
    PromoteMemToReg(allocas, DT);
    return F;
}

// ---------------- 初始化 ctor ----------------
static Function *makeInit(Module *M, std::vector<Item> &items,
                          Function *d8, Function *d16) {
    if (items.empty()) return nullptr;
    LLVMContext &C = M->getContext();
    Type *i32 = Type::getInt32Ty(C);

    FunctionType *FT = FunctionType::get(Type::getVoidTy(C), false);
    Function *F = Function::Create(FT, GlobalValue::InternalLinkage, helperName("n"), M);
    addHelper(F);
    F->addFnAttr(Attribute::NoInline);
    F->addFnAttr(Attribute::NoUnwind);

    BasicBlock *BB = BasicBlock::Create(C, "entry", F);
    IRBuilder<> B(BB);

    const Config &c = config();
    uint32_t base = (c.seed * 2654435761u) ^ 0x5BF03635u;
    Value *k = B.getInt32(base);

    for (const Item &it : items) {
        k = xorshiftIR(B, k);
        std::vector<Value *> args;
        args.push_back(it.gv);
        args.push_back(B.getInt32(it.n));
        args.push_back(k);
        Function *dec = it.wide ? d16 : d8;
        B.CreateCall(dec, args);
    }
    B.CreateRetVoid();
    appendToGlobalCtors(*M, F, 101);   // 101 = 尽可能早, 先于 +load
    return F;
}

} // namespace

// ---------------- 入口 ----------------
bool runStringObf(Module *M, bool on) {
    if (!on) return false;

    std::vector<GlobalVariable *> targets;
    for (GlobalVariable &GV : M->globals()) {
        bool wide = false;
        if (isCandidate(GV, wide)) targets.push_back(&GV);
    }
    if (targets.empty()) return false;

    const Config &c = config();
    uint32_t base = (c.seed * 2654435761u) ^ 0x5BF03635u;

    std::vector<Item> items;
    items.reserve(targets.size());

    uint32_t k = base;
    unsigned zeroUnits = 0;
    for (GlobalVariable *GV : targets) {
        auto *CDS = cast<ConstantDataSequential>(GV->getInitializer());
        bool wide = CDS->getElementType()->isIntegerTy(16);
        uint32_t n = (uint32_t)CDS->getNumElements();

        StringRef raw = CDS->getRawDataValues();
        std::vector<uint8_t> bytes(raw.begin(), raw.end());

        k = xorshift(k);
        encodeInPlace(bytes, k, wide);

        if (wide) {
            for (size_t i = 0; i + 1 < bytes.size(); i += 2)
                if (bytes[i] == 0 && bytes[i + 1] == 0) { zeroUnits++; break; }
        }

        ArrayType *AT = cast<ArrayType>(GV->getValueType());
        auto *NGV = new GlobalVariable(*M, AT, /*isConstant=*/false,
                                       GlobalValue::PrivateLinkage, nullptr,
                                       helperName("s"), nullptr);
        Constant *init = ConstantDataArray::getRaw(
            StringRef((const char *)bytes.data(), bytes.size()),
            CDS->getNumElements(), CDS->getElementType());
        NGV->setInitializer(init);
        if (MaybeAlign A = GV->getAlign()) NGV->setAlignment(*A);
        NGV->setUnnamedAddr(GlobalValue::UnnamedAddr::None);

        GV->replaceAllUsesWith(NGV);
        GV->eraseFromParent();

        Item it;
        it.gv = NGV;
        it.n = n;
        it.wide = wide;
        items.push_back(it);
    }

    bool needWide = false;
    for (const Item &it : items) if (it.wide) { needWide = true; break; }

    Function *d8  = makeDecoder(M, false);
    Function *d16 = needWide ? makeDecoder(M, true) : d8;

    makeInit(M, items, d8, d16);

    errs() << "[GCObf] sobf: " << items.size() << " strings encoded"
           << " (utf16=" << (needWide ? "yes" : "no")
           << ", zeroUnit=" << zeroUnits << ")\n";
    return true;
}

} // namespace gco

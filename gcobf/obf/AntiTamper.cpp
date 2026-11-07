// AntiTamper.cpp - 反调试 / 反注入 / 自校验 (LLVM 16)  v1.0
//
// 三个独立开关, 全部默认关闭:
//   GCOBF=...,anti   反调试 (ptrace PT_DENY_ATTACH) + dyld 注入扫描
//   GCOBF=...,integ  自校验 (关键函数 256 字节校验和, 不匹配自毁)
//
// 注意:
//   * 反注入只针对 Frida / Dobby / cycript, 不碰 Substrate / ellekit
//     (tweak 本身就跑在它们上面, 误杀等于自杀)
//   * integ 的期望值由 gcobf-post.py 在链接后写入 __gcob_crc;
//     若该全局仍为 0 (没跑后处理) 则跳过校验, 避免自毁
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"
#include <vector>

using namespace llvm;
namespace gco {

static Function *declFn(Module *M, StringRef name, FunctionType *FT) {
    if (Function *F = M->getFunction(name)) return F;
    return Function::Create(FT, GlobalValue::ExternalLinkage, name, M);
}

// void anti(void)
static Function *makeAnti(Module *M) {
    LLVMContext &C = M->getContext();
    Type *i32 = Type::getInt32Ty(C);
    Type *ptr = PointerType::get(C, 0);
    Type *voidTy = Type::getVoidTy(C);

    Function *ptraceF = declFn(M, "ptrace", FunctionType::get(i32, {i32, i32, ptr, ptr}, false));
    Function *dyldCnt = declFn(M, "_dyld_image_count", FunctionType::get(i32, false));
    Function *dyldName = declFn(M, "_dyld_get_image_name", FunctionType::get(ptr, {i32}, false));
    Function *strstrF = declFn(M, "strstr", FunctionType::get(ptr, {ptr, ptr}, false));
    Function *killF = declFn(M, "kill", FunctionType::get(i32, {i32, i32}, false));
    Function *getpidF = declFn(M, "getpid", FunctionType::get(i32, false));

    Function *F = Function::Create(FunctionType::get(voidTy, false),
                                   GlobalValue::InternalLinkage, helperName("a"), M);
    addHelper(F);
    F->addFnAttr(Attribute::NoInline);
    F->addFnAttr(Attribute::NoUnwind);

    BasicBlock *entry = BasicBlock::Create(C, "e", F);
    BasicBlock *loop  = BasicBlock::Create(C, "l", F);
    BasicBlock *chk   = BasicBlock::Create(C, "k", F);
    BasicBlock *killBB= BasicBlock::Create(C, "x", F);
    BasicBlock *next  = BasicBlock::Create(C, "n", F);
    BasicBlock *done  = BasicBlock::Create(C, "r", F);

    IRBuilder<> B(entry);
    // 1) PT_DENY_ATTACH = 31: 调用后调试器无法附加
    B.CreateCall(ptraceF, {B.getInt32(31), B.getInt32(0),
                           ConstantPointerNull::get(cast<PointerType>(ptr)),
                           ConstantPointerNull::get(cast<PointerType>(ptr))});
    AllocaInst *idx = B.CreateAlloca(i32, nullptr, "i");
    AllocaInst *cnt = B.CreateAlloca(i32, nullptr, "n");
    B.CreateStore(B.getInt32(0), idx);
    B.CreateStore(B.CreateCall(dyldCnt), cnt);
    B.CreateBr(loop);

    // 2) 遍历已加载 image, 命中调试/注入工具就 kill
    B.SetInsertPoint(loop);
    Value *iv = B.CreateLoad(i32, idx);
    Value *nv = B.CreateLoad(i32, cnt);
    B.CreateCondBr(B.CreateICmpSLT(iv, nv), chk, done);

    B.SetInsertPoint(chk);
    Value *nm = B.CreateCall(dyldName, {B.CreateLoad(i32, idx)});
    Value *isNull = B.CreateICmpEQ(nm, ConstantPointerNull::get(cast<PointerType>(ptr)));
    BasicBlock *scan = BasicBlock::Create(C, "s", F);
    B.CreateCondBr(isNull, next, scan);

    B.SetInsertPoint(scan);
    /* ★ 黑名单字符串编译期 XOR 0x5A 加密，运行时还原（防 strings 明文搜索） */
    static const char *plain[] = {"Frida", "frida", "Dobby", "cycript", "gum-js-loop"};
    static const size_t nplains = sizeof(plain) / sizeof(plain[0]);
    Value *hit = B.getInt32(0);
    for (size_t pi = 0; pi < nplains; pi++) {
        size_t n = strlen(plain[pi]);
        /* 加密字节数组（含结尾 0） */
        std::vector<Constant *> bytes;
        for (size_t j = 0; j < n; j++)
            bytes.push_back(B.getInt8((unsigned char)plain[pi][j] ^ 0x5A));
        bytes.push_back(B.getInt8(0));
        ArrayType *AT = ArrayType::get(B.getInt8Ty(), n + 1);
        Constant *arr = ConstantArray::get(AT, bytes);
        GlobalVariable *GV = new GlobalVariable(*M, AT, true,
            GlobalValue::PrivateLinkage, arr, helperName("ep"));
        /* 运行时：栈上 XOR 还原 */
        AllocaInst *buf = B.CreateAlloca(B.getInt8Ty(), B.getInt32(n + 1));
        for (size_t j = 0; j < n; j++) {
            Value *gep = B.CreateConstGEP2_32(AT, GV, 0, j);
            Value *e = B.CreateLoad(B.getInt8Ty(), gep);
            Value *d = B.CreateXor(e, B.getInt8(0x5A));
            B.CreateStore(d, B.CreateConstGEP1_32(B.getInt8Ty(), buf, j));
        }
        B.CreateStore(B.getInt8(0), B.CreateConstGEP1_32(B.getInt8Ty(), buf, n));
        Value *s = B.CreatePointerCast(buf, B.getInt8PtrTy());
        Value *r = B.CreateCall(strstrF, {nm, s});
        Value *ne = B.CreateICmpNE(r, ConstantPointerNull::get(cast<PointerType>(ptr)));
        hit = B.CreateOr(hit, B.CreateZExt(ne, i32));
    }
    B.CreateCondBr(B.CreateICmpNE(hit, B.getInt32(0)), killBB, next);

    B.SetInsertPoint(killBB);
    B.CreateCall(killF, {B.CreateCall(getpidF), B.getInt32(9)});   // SIGKILL
    B.CreateBr(done);

    B.SetInsertPoint(next);
    B.CreateStore(B.CreateAdd(B.CreateLoad(i32, idx), B.getInt32(1)), idx);
    B.CreateBr(loop);

    B.SetInsertPoint(done);
    /* hook 检测已移除：TrollFools/libhooker 会 hook ptrace，误杀 */
    /* ---- 扩展检测 2: P_TRACED（sysctl 需要缓冲，用简化版：读 ptrace 返回值无效，跳过） ---- */
    B.CreateRetVoid();
    return F;
}

// void integ(void) - 校验 anti 函数自身 256 字节
static Function *makeInteg(Module *M, Function *target) {
    LLVMContext &C = M->getContext();
    Type *i32 = Type::getInt32Ty(C);
    Type *i64 = Type::getInt64Ty(C);
    Type *voidTy = Type::getVoidTy(C);

    Function *killF = declFn(M, "kill", FunctionType::get(i32, {i32, i32}, false));
    Function *getpidF = declFn(M, "getpid", FunctionType::get(i32, false));

    GlobalVariable *crcG = M->getGlobalVariable("__gcob_crc");
    if (!crcG) {
        crcG = new GlobalVariable(*M, i32, false, GlobalValue::CommonLinkage,
                                  ConstantInt::get(i32, 0), "__gcob_crc", nullptr);
        crcG->setAlignment(Align(4));
    }

    Function *F = Function::Create(FunctionType::get(voidTy, false),
                                   GlobalValue::InternalLinkage, helperName("v"), M);
    addHelper(F);
    F->addFnAttr(Attribute::NoInline);
    F->addFnAttr(Attribute::NoUnwind);

    BasicBlock *entry = BasicBlock::Create(C, "e", F);
    BasicBlock *loop  = BasicBlock::Create(C, "l", F);
    BasicBlock *body  = BasicBlock::Create(C, "b", F);
    BasicBlock *ck    = BasicBlock::Create(C, "c", F);
    BasicBlock *die   = BasicBlock::Create(C, "d", F);
    BasicBlock *done  = BasicBlock::Create(C, "r", F);

    IRBuilder<> B(entry);
    AllocaInst *acc = B.CreateAlloca(i32, nullptr, "a");
    AllocaInst *idx = B.CreateAlloca(i32, nullptr, "i");
    B.CreateStore(B.getInt32(0), acc);
    B.CreateStore(B.getInt32(0), idx);
    Value *base = B.CreatePtrToInt(target, i64);
    AllocaInst *ba = B.CreateAlloca(i64, nullptr, "p");
    B.CreateStore(base, ba);
    B.CreateBr(loop);

    B.SetInsertPoint(loop);
    Value *iv = B.CreateLoad(i32, idx);
    B.CreateCondBr(B.CreateICmpSLT(iv, B.getInt32(64)), body, ck);   // 64 * 4 = 256 字节

    B.SetInsertPoint(body);
    Value *bv = B.CreateLoad(i64, ba);
    Value *iv2 = B.CreateLoad(i32, idx);
    Value *p = B.CreateIntToPtr(B.CreateAdd(bv, B.CreateZExt(B.CreateShl(iv2, B.getInt32(2)), i64)),
                                PointerType::get(C, 0));
    Value *w = B.CreateLoad(i32, p);
    B.CreateStore(B.CreateAdd(B.CreateLoad(i32, acc), w), acc);
    B.CreateStore(B.CreateAdd(iv2, B.getInt32(1)), idx);
    B.CreateBr(loop);

    B.SetInsertPoint(ck);
    Value *sum = B.CreateLoad(i32, acc);
    Value *expect = B.CreateLoad(i32, crcG);
    // expect == 0 表示还没跑后处理, 跳过校验 (避免自毁)
    Value *notInit = B.CreateICmpEQ(expect, B.getInt32(0));
    Value *mismatch = B.CreateICmpNE(sum, expect);
    B.CreateCondBr(B.CreateAnd(B.CreateNot(notInit), mismatch), die, done);

    B.SetInsertPoint(die);
    B.CreateCall(killF, {B.CreateCall(getpidF), B.getInt32(9)});
    B.CreateBr(done);

    B.SetInsertPoint(done);
    B.CreateRetVoid();
    return F;
}

bool runAntiTamper(Module *M, bool anti, bool integ) {
    if (!anti && !integ) return false;
    LLVMContext &C = M->getContext();
    Function *antiF = nullptr, *integF = nullptr;
    if (anti) antiF = makeAnti(M);
    // 把 anti 函数地址暴露到符号表, 供 gcobf-post.py 计算 crc
    if (antiF) {
        new GlobalVariable(*M, PointerType::get(C, 0), /*isConstant=*/true,
                           GlobalValue::WeakAnyLinkage, antiF,
                           "__gcob_anti_ptr", nullptr);
    }
    if (integ) integF = makeInteg(M, antiF ? antiF : M->getFunction("main"));

    Function *ctor = Function::Create(FunctionType::get(Type::getVoidTy(C), false),
                                      GlobalValue::InternalLinkage, helperName("g"), M);
    addHelper(ctor);
    ctor->addFnAttr(Attribute::NoUnwind);
    BasicBlock *BB = BasicBlock::Create(C, "e", ctor);
    IRBuilder<> B(BB);
    if (antiF) B.CreateCall(antiF);
    if (integF) B.CreateCall(integF);
    B.CreateRetVoid();
    appendToGlobalCtors(*M, ctor, 102);   // 紧跟字符串解码之后

    errs() << "[GCObf] guard: anti=" << (anti ? 1 : 0) << " integ=" << (integ ? 1 : 0) << "\n";
    return true;
}
} // namespace gco

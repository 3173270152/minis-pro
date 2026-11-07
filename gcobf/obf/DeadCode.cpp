// DeadCode.cpp - 完整假函数注入 (LLVM 16)  v1.0
//
// 和 bcf 的"垃圾块"不同: 这里生成的是**结构完整的假函数**
//   - 有参数、有循环、有条件分支、有字符串引用、有互相调用
//   - 由运行时 opaque 谓词保护, 永不执行
//   - 互相引用形成调用图, 链接器删不掉
//
// 静态分析时会有大量"看起来像真逻辑"的函数, 干扰函数计数和调用图。
//
// 开关: GCOBF=...,dead:30   (生成 30 个假函数, 默认 0 = 关闭)
#include "ObfUtils.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"
#include <vector>

using namespace llvm;
namespace gco {

// 生成一个"看起来像业务逻辑"的假函数体
static void fillFakeBody(Function *F, ArrayRef<Function *> nexts, Module *M) {
    LLVMContext &C = F->getContext();
    Type *i32 = Type::getInt32Ty(C);
    Type *ptr = PointerType::get(C, 0);

    BasicBlock *entry = BasicBlock::Create(C, "e", F);
    BasicBlock *loop  = BasicBlock::Create(C, "l", F);
    BasicBlock *body  = BasicBlock::Create(C, "b", F);
    BasicBlock *then  = BasicBlock::Create(C, "t", F);
    BasicBlock *els   = BasicBlock::Create(C, "f", F);
    BasicBlock *cont  = BasicBlock::Create(C, "c", F);
    BasicBlock *exit  = BasicBlock::Create(C, "x", F);

    IRBuilder<> B(entry);
    AllocaInst *acc = B.CreateAlloca(i32, nullptr, "a");
    AllocaInst *idx = B.CreateAlloca(i32, nullptr, "i");
    B.CreateStore(F->arg_begin(), acc);
    B.CreateStore(B.getInt32(0), idx);
    B.CreateBr(loop);

    B.SetInsertPoint(loop);
    Value *iv = B.CreateLoad(i32, idx);
    // 循环上界是个运行时值, 静态看不出会不会执行
    Value *limit = B.CreateAnd(B.getInt32((uint32_t)rand32()), B.getInt32(0x1F));
    B.CreateCondBr(B.CreateICmpSLT(iv, limit), body, exit);

    B.SetInsertPoint(body);
    Value *av = B.CreateLoad(i32, acc);
    Value *v1 = B.CreateXor(av, B.getInt32(rand32()));
    v1 = B.CreateAdd(v1, B.CreateShl(v1, B.getInt32(3)));
    Value *cond = B.CreateICmpEQ(B.CreateAnd(v1, B.getInt32(1)), B.getInt32(0));
    B.CreateStore(v1, acc);
    B.CreateCondBr(cond, then, els);

    B.SetInsertPoint(then);
    {
        Value *x = B.CreateLoad(i32, acc);
        x = B.CreateMul(x, B.getInt32(rand32() | 1));
        // 引用一段字符串, 让它看起来在用配置
        Constant *s = ConstantDataArray::getString(C, "cfg.item.enabled", true);
        auto *g = new GlobalVariable(*M, s->getType(), true, GlobalValue::PrivateLinkage,
                                     s, helperName("k"));
        g->setUnnamedAddr(GlobalValue::UnnamedAddr::Global);
        Value *gp = B.CreateGEP(g->getValueType(), g, {B.getInt32(0), B.getInt32(0)});
        Value *ch = B.CreateLoad(B.getInt8Ty(), gp);
        x = B.CreateAdd(x, B.CreateZExt(ch, i32));
        B.CreateStore(x, acc);
    }
    B.CreateBr(cont);

    B.SetInsertPoint(els);
    {
        Value *x = B.CreateLoad(i32, acc);
        x = B.CreateSub(x, B.CreateLShr(x, B.getInt32(2)));
        B.CreateStore(x, acc);
    }
    B.CreateBr(cont);

    B.SetInsertPoint(cont);
    if (!nexts.empty()) {
        // 调用下一个假函数, 形成环 -> 链接器不能删任何一个
        Function *nx = nexts[rand32() % nexts.size()];
        Value *p = B.CreateLoad(ptr, idx);        // 随便传个指针型实参
        B.CreateCall(nx, {B.CreateLoad(i32, acc), p});
    }
    B.CreateStore(B.CreateAdd(B.CreateLoad(i32, idx), B.getInt32(1)), idx);
    B.CreateBr(loop);

    B.SetInsertPoint(exit);
    B.CreateRet(B.CreateLoad(i32, acc));
}

bool runDeadCode(Module *M, int count) {
    if (count <= 0) return false;
    LLVMContext &C = M->getContext();
    Type *i32 = Type::getInt32Ty(C);
    Type *ptr = PointerType::get(C, 0);
    FunctionType *FT = FunctionType::get(i32, {i32, ptr}, false);

    std::vector<Function *> fns;
    fns.reserve(count);
    for (int i = 0; i < count; i++) {
        Function *F = Function::Create(FT, GlobalValue::InternalLinkage, helperName("d"), M);
        // 注意: 不加入 g_helpers -> 这些假函数会被后续 fla/bcf/sub/cenc 一起混淆,
        // 体积和真实函数一样膨胀, 静态上完全看不出是注入的
        F->addFnAttr(Attribute::NoInline);
        F->addFnAttr(Attribute::NoUnwind);
        fns.push_back(F);
    }
    for (Function *F : fns) fillFakeBody(F, fns, M);

    // 根函数: 用一个恒假的不透明谓词保护, 确保整张图都被引用
    Function *root = Function::Create(FunctionType::get(Type::getVoidTy(C), false),
                                      GlobalValue::InternalLinkage, helperName("r"), M);
    addHelper(root);
    root->addFnAttr(Attribute::NoInline);
    BasicBlock *BB = BasicBlock::Create(C, "e", root);
    IRBuilder<> B(BB);
    Value *rt = loadOpaqueState(M, B);
    Value *rt32 = B.CreateTrunc(rt, B.getInt32Ty());
    // (rt & 1) == 2 恒假
    Value *fake = B.CreateICmpEQ(B.CreateAnd(rt32, B.getInt32(1)), B.getInt32(2));
    BasicBlock *callBB = BasicBlock::Create(C, "c", root);
    BasicBlock *endBB = BasicBlock::Create(C, "x", root);
    B.CreateCondBr(fake, callBB, endBB);

    B.SetInsertPoint(callBB);
    B.CreateCall(fns[0], {B.getInt32(1), ConstantPointerNull::get(cast<PointerType>(ptr))});
    B.CreateBr(endBB);

    B.SetInsertPoint(endBB);
    B.CreateRetVoid();

    // 挂到 ctor 上, 保证不会被全局 DCE 干掉
    appendToGlobalCtors(*M, root, 60001);

    errs() << "[GCObf] dead: 注入 " << count << " 个完整假函数\n";
    return true;
}
} // namespace gco

// FragTable.cpp - 运行时不可折叠常量表 (LLVM 16)  v1.0
#include "FragTable.h"
#include "ObfUtils.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Support/raw_ostream.h"
#include <map>
#include <vector>

using namespace llvm;
namespace gco {

namespace {

// 64KB：可容纳 32768 个字节槽 = 16384 个字节常量 = 2048 个 64 位常量。
// 实际工程（几百个函数、每函数上限 32 个）用不到十分之一。
const unsigned kTableSize = 65536;

struct FragState {
    GlobalVariable *GV = nullptr;
    std::vector<uint8_t> data;
    unsigned used = 0;
    bool dirty = false;
    bool frozen = false;    // sync 之后禁止再分配（表已被裁剪）
};

std::map<Module *, FragState> &tables() {
    static std::map<Module *, FragState> m;
    return m;
}

FragState &state(Module *M) {
    FragState &S = tables()[M];
    if (!S.GV) {
        LLVMContext &C = M->getContext();
        S.data.resize(kTableSize);
        for (unsigned i = 0; i < kTableSize; ++i)
            S.data[i] = (uint8_t)(rand32() >> 13);

        ArrayType *AT = ArrayType::get(Type::getInt8Ty(C), kTableSize);
        // isConstant = true → 落在 __TEXT,__const（只读）。
        // 全程只读、不改写 __TEXT，所以不会触发 AMFI。
        S.GV = new GlobalVariable(*M, AT, /*isConstant=*/true,
                                  GlobalValue::InternalLinkage,
                                  ConstantDataArray::get(C, S.data),
                                  helperName("d"));
        S.GV->setAlignment(Align(16));
        S.GV->setUnnamedAddr(GlobalValue::UnnamedAddr::Global);
        S.dirty = false;
    }
    return S;
}

} // namespace

bool fragTableAlloc(Module *M, const uint8_t *bytes, unsigned n,
                    unsigned *idxOut) {
    if (!M || !bytes || n == 0 || n > 8) return false;
    FragState &S = state(M);
    if (S.frozen) return false;
    if (S.used + n * 2 > kTableSize) return false;

    unsigned base = S.used;
    for (unsigned i = 0; i < n; ++i) {
        unsigned a = base + i * 2;
        unsigned b = a + 1;
        uint8_t r = (uint8_t)(rand32() >> 11);
        S.data[a] = r;
        S.data[b] = (uint8_t)(r ^ bytes[i]);
        idxOut[i * 2] = a;
        idxOut[i * 2 + 1] = b;
    }
    S.used = base + n * 2;
    S.dirty = true;
    return true;
}

void fragTableSync(Module *M) {
    auto it = tables().find(M);
    if (it == tables().end()) return;
    FragState &S = it->second;
    if (!S.GV || !S.dirty) return;
    S.dirty = false;
    S.frozen = true;

    LLVMContext &C = M->getContext();
    Type *i8 = Type::getInt8Ty(C);

    /* 一个常量都没分配 -> 把空表整个删掉 */
    if (S.used == 0) {
        S.GV->eraseFromParent();
        S.GV = nullptr;
        S.data.clear();
        return;
    }

    /* ★ 裁剪到实际用量。
     * 踩过的坑: 每张表固定 64KB, 而 twEAK 工程有 20 个编译单元,
     * 每个单元一张表 -> __TEXT,__const 涨了 1.3MB (4.5MB -> 5.5MB)。
     * 裁剪后表大小 == 实际分配的槽数, 20 个单元合计只多几十 KB。 */
    S.data.resize(S.used);
    ArrayType *AT = ArrayType::get(i8, S.data.size());
    Constant *Init = ConstantDataArray::get(C, S.data);

    if (S.GV->getValueType() == AT) {
        S.GV->setInitializer(Init);
        return;
    }

    /* 大小变了必须换一个新全局 (setInitializer 要求类型一致)。
     * opaque pointer 下两边都是 ptr, replaceAllUsesWith 合法。 */
    GlobalVariable *NG = new GlobalVariable(*M, AT, /*isConstant=*/true,
                                            GlobalValue::InternalLinkage, Init,
                                            S.GV->getName());
    NG->setAlignment(Align(16));
    NG->setUnnamedAddr(GlobalValue::UnnamedAddr::Global);
    S.GV->replaceAllUsesWith(NG);
    S.GV->eraseFromParent();
    S.GV = NG;
}

unsigned fragTableUsed(Module *M) {
    auto it = tables().find(M);
    if (it == tables().end()) return 0;
    return it->second.used;
}

Value *fragTableLoadByte(Module *M, IRBuilder<> &B, unsigned idx) {
    FragState &S = state(M);
    LLVMContext &C = M->getContext();
    Value *p = B.CreateInBoundsGEP(Type::getInt8Ty(C), S.GV,
                                   B.getInt64((uint64_t)idx));
    LoadInst *LI = B.CreateLoad(Type::getInt8Ty(C), p);
    LI->setVolatile(true);          // ★ 唯一能挡住常量折叠的东西
    LI->setAlignment(Align(1));
    return LI;
}

Value *fragTableLoadBytes(Module *M, IRBuilder<> &B, const unsigned *idx,
                          unsigned n, Type *ty) {
    Value *acc = nullptr;
    for (unsigned i = 0; i < n; ++i) {
        Value *lo = fragTableLoadByte(M, B, idx[i * 2]);
        Value *hi = fragTableLoadByte(M, B, idx[i * 2 + 1]);
        Value *byte = B.CreateXor(lo, hi);          // 两个 volatile load → 不折叠
        Value *z = B.CreateZExt(byte, ty);
        if (i) z = B.CreateShl(z, (uint64_t)i * 8);
        acc = acc ? B.CreateOr(acc, z) : z;
    }
    return acc;
}

} // namespace gco

// ObfUtils.h - 混淆公共工具 (LLVM 16)  v2.1
//
// v2.0 变更:
//   1. 配置解析集中到 Config (GCOBF 环境变量, 支持 name:param 形式)
//   2. 支持 GCOBF_SEED 固定种子 (可复现构建)
//   3. helper 函数使用伪 C++ mangled 名, 不再暴露插件指纹
//   4. 统一 skip 判定 (helper / 构造函数 / ObjC 方法 / 异常函数 / optnone)
// v2.1:
//   5. 新增 frag (常量碎片化, volatile 表), 见 FragTable.h
#ifndef OBFUTILS_H
#define OBFUTILS_H

#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/Transforms/Utils/Local.h"
#include <string>
#include <set>
#include <cstdint>
#include <vector>

namespace gco {

// ---------------- 配置 ----------------
struct Config {
    bool fla = false;         // 控制流平坦化
    bool sub = false;         // 指令替换 (MBA)
    bool bcf = false;         // 虚假控制流
    bool split = false;       // 基本块拆分
    bool sobf = false;        // 字符串混淆 (C 串 + __ustring)
    bool cenc = false;        // 常量加密
    bool msym = false;        // 导出符号哈希化 (保守, 默认关)
    bool anti = false;        // 反调试 + 反注入 (默认关)
    bool integ = false;       // 自校验 (默认关, 需后处理写 crc)
    int  deadCount = 0;       // dead:N 完整假函数数量 (默认 0 = 关)

    bool flaStrong = false;   // fla:strong  状态变量二次混淆
    int  subRounds = 1;       // sub:N
    int  bcfRounds = 2;       // bcf:N
    int  flaMaxBlocks = 600;  // 超过则不平坦化 (v3: 150->600, 覆盖大函数)
    int  cencMinBits = 9;     // cenc:bits  只加密 >= 2^bits 的常量
    bool frag = false;              // 常量碎片化 (volatile 表, 真正不可折叠)
    int  fragMinBits = 32;          // frag:bits    只碎片化 >= bits 的常量
    int  fragMaxPerFunc = 32;       // frag:bits:N  每函数上限 (性能保护)
    bool adp = false;               // 深度反调试 (bitcode 链接, 默认关 —— 会真的 kill)
    bool wipe = false;               // 函数体抹除
    std::vector<std::string> wipePats; // GCOBF_WIPE=a,b
    bool verbose = false;

    std::string filter;       // GCOBF_ONLY=子串  只混淆名字含该子串的函数
    std::vector<std::string> skipSubs;  // GCOBF_SKIP=a,b  这些子串命中的函数不混淆(留给 VMP)
    uint32_t seed = 0;        // 构建种子
};

const Config &config();

// ---------------- 随机 ----------------
extern uint32_t g_rng;
uint32_t rand32();
uint32_t xorshift(uint32_t k);

// ---------------- 函数集合 ----------------
extern std::set<std::string> g_skip;     // 不混淆的函数 (构造函数等)
extern std::set<std::string> g_helpers;  // 本插件生成的辅助函数

// 生成伪 C++ mangled 名 (demangle 后形如 gcob::detail::xxx)
std::string helperName(const char *tag);
void addHelper(llvm::Function *F);
bool isHelper(const llvm::Function *F);

// 判断函数是否需要混淆 (读注解 "fla"/"sub"/... 或全局开关)
bool funcToObfuscate(llvm::Function *F, const char *attr, bool globalOn);

// 栈修正: 把逃逸的值/PHI 降级到栈 (平坦化后必需)
void fixStack(llvm::Function *F);

// 读函数注解串
std::string readAnnotate(llvm::Function *F);

// 模块级: 取"运行时 opaque 值" (volatile load), 供 BCF/平坦化使用。
// 该全局由 ctor 用函数地址填充, 任何情况下都非 0, 且静态不可折叠。
llvm::Value *loadOpaqueState(llvm::Module *M, llvm::IRBuilder<> &B);

} // namespace gco
#endif

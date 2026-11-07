# VMP 工具链 使用教程

> iOS arm64 dylib 混淆 + 代码虚拟化（VMP）工具链
> 当前虚拟化覆盖率（LC_FUNCTION_STARTS 全量）：**干净版 81.7% / 带 VMP 版 78.9%**

---

## 一、保护四层（从编译期到运行期）

```
编译期(LLVM pass) → 链接后(二进制重写) → 运行期(VM 解释器) → 常驻(反调试)
  obf/*.cpp          tools/gcobf-post.py    VMP/vm_interp.c      AntiDebug/
```

## 二、环境要求

- Theos + iOS SDK（Makefile 用 `iphone:clang:16.5:14.0`）
- LLVM 16（混淆 pass 插件 `obf/GCObf.dylib`）
- `ldid`（重签名）、`python3.6+`、`otool`/`nm`（后处理用）

## 三、一键构建（推荐）

```bash
export DYLIB=/path/to/.theos/obj/app.dylib   # make 产物
./tools/build_all.sh
```

`build_all.sh` 自动完成：
1. 循环「生成 hook+字节码 → make → 检测函数布局收敛」直到稳定；
2. 后处理：`strip` → `rename-selectors --skip-selrefs` → `hide-exports`；
3. `ldid -S` 重签 + `verify`/`report` 自检。

## 四、手动五步（等价流程）

```bash
# 1. 编译混淆插件（一次）
cd obf && clang++ -shared -fPIC -fno-rtti -O2 -I$LLVM16/include -I. \
  -o GCObf.dylib *.cpp -L$LLVM16/lib -lLLVM
cp GCObf.dylib $LLVM16/lib/ && ldid -S $LLVM16/lib/GCObf.dylib

# 2. 编译目标（带混淆）
export GCOBF=sobf,sub,bcf,split,fla,cenc,frag
make

# 3. 生成 hook + 字节码（选函数 → ARM64 翻译成 VM 字节码）
python3 tools/gen_multi_hooks.py

# 4. 再编译（字节码进二进制）
make

# 5. 后处理
python3 tools/gcobf-post.py strip            app.dylib -o s1
python3 tools/gcobf-post.py rename-selectors  s1 -o s2 --skip-selrefs
python3 tools/gcobf-post.py hide-exports      s2 -o final
ldid -S final
```

> 第 2~4 步可能需循环多轮直到地址收敛；用 `build_all.sh` 可免去人工判断。

## 五、工具一览

| 工具 | 作用 |
|---|---|
| `tools/vmp/vmp.py` | ARM64 指令 → VM 字节码翻译器（解码+翻译一体） |
| `tools/gen_multi_hooks.py` | 按 `LC_FUNCTION_STARTS` 选函数、生成 `VMPHooks.xm` + `g_bc_multi.h` |
| `tools/vmp/analyze_coverage.py` | **覆盖率分析**：全量函数可翻译率 + 失败按指令分桶 |
| `tools/vmp/vmsim3.py` | 字节码模拟器（上机前验证翻译正确性） |
| `tools/check_convergence.py` | 自举收敛检测（函数布局是否稳定） |
| `tools/gcobf-post.py` | 二进制后处理：`strip`/`rename-selectors`/`hide-exports`/`write-crc`/`verify`/`report` |

### 看当前覆盖率
```bash
python3 tools/vmp/analyze_coverage.py <未保护的app.dylib>
```

## 六、覆盖率现状与边界

- 已支持：整数 ALU / 分支（含全窗口内部跳转）/ 内存 / `ldrsw`·`ldrsb`·`ldrsh` / 64 位逻辑掩码 /
  `ccmp`·`ccmn` / 浮点 `fadd..fdiv`·`fmax`·`fmin`·`fsqrt`·`frint`·`fcvt`·`fmov立即数` / 浮点字面量加载 /
  `bl`·`br`·`blr`（含浮点参数 d0–d7 传递）。
- **未支持（约 18%，故意不做）**：SIMD 向量（`v0.4s` 等 128 位车道运算，~75 个函数）、`FMADD/FMSUB`、少量 `FCSEL`。
  SIMD 向量化风险高、收益需大量真机验证，建议作为独立批次谨慎推进。
- 稳定性：VM 跑崩自动降级调用原函数（`sigsetjmp` 兜底）；初始化/单例/`+load`/渲染主循环等关键路径**不虚拟化**。

## 七、静态抹除（让静态/dump 也看不到原逻辑）★新增

**背景**：运行期覆盖率 ~80% 指的是「跑的时候走 VM」，但被虚拟化函数的**原始指令（混淆后）默认仍在 `__text`**，静态/dump 能看到。要静态也隐藏，必须「抹除」——把原体换成桩。
被抹函数一律 **fail-closed**（VM 跑崩不再回退原函数，直接返回 0）。

**代价与风险**：抹除去掉了「VM 失败回退原函数」的安全网，且抹到初始化/单例路径会让 App 起不来。
因此**默认关闭**，请**分批、上机验证**地开启。

### 开关（`tools/gen_multi_hooks.py` 顶部 `WIPE_MODE`）
| 值 | 含义 | 建议 |
|---|---|---|
| `"off"`（默认） | 只生成候选名单，不抹、不改降级 | 先保持，确认 80% 运行期虚拟化在真机 OK |
| `"named"` | **只抹命门**（授权/反调试），fail-closed——这是**自保护第一步、低风险高价值** | ✅ 推荐首选：静态藏掉授权/反调试，且「授权 VM 挂→拒绝」本就是正确姿势 |
| `"all"` | 抹全部已虚拟化（冲静态 ~80%），排除 init/单例/+load | 冲极限用；**必须分批**：先 named 确认启动→再 all→起不来就从 `g_wipe_list.txt` 删掉肇事函数 |

### 要虚拟化+抹除「反调试」本身
反调试进 VM 的拦路石（大量 `bl`）本版已拆。要强制虚拟化的函数名用 `GCOBF_TARGETS=foo,bar` 指定(其余全自动扫描)；要静态抹除的用 `GCOBF_WIPE_NAMED=foo,bar` 指定(被抹函数 fail-closed)。工具不内置任何具体符号名单。

### 流程
```
python3 tools/gen_multi_hooks.py        # 生成 g_wipe_list.txt（按 WIPE_MODE）
make                                     # 带 _wiped fail-closed 标志重编
# 后处理末尾（build_all.sh 已集成）：
python3 tools/gcobf-post.py wipe final.dylib --list <VMP>/g_wipe_list.txt [--fill junk]
ldid -S final.dylib
```
`g_wipe_candidates.txt` = 全部已虚拟化函数（供你手挑/分批）；`g_wipe_list.txt` = 本次实际要抹的子集。

## 八、上机逆向验证

见 `逆向验证报告_RE_AUDIT.md`：静态验证结论 + **可直接在真机/越狱设备上跑的动态验证脚本**
（反调试击杀、调试器附加、运行时 dump 检查）。

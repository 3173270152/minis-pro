# gcobf — iOS / arm64 代码混淆与虚拟化工具链

一个面向 **iOS / arm64 (Mach-O dylib)** 的商业级代码保护工具链:LLVM 编译期混淆 +
自研字节码虚拟机 (VM) 函数级虚拟化 + 二进制后处理 + 运行期自保护。用于保护
**你自己拥有或已获授权**的 App / 动态库的核心逻辑,抬高静态/动态逆向成本。

> 适用对象:你有权保护的软件。请在合法合规前提下使用。

## 组成

| 目录 | 内容 |
|---|---|
| `obf/` | LLVM 16 混淆 Pass 插件(控制流平坦化、虚假控制流、指令替换/MBA、常量加密/碎片化、字符串/符号混淆、假函数注入、函数体抹除)。源码编译成 `GCObf.dylib` 后以 `-fpass-plugin=` 挂到 clang。 |
| `VMP/` | 字节码虚拟机引擎:解释器 `vm_interp.c` + 分类 handler(`vm_handlers/`)。约 150 opcode,含整数/浮点/NEON 向量。默认开启间接分发 + handler 分节(抗 IDA)+ 字节码完整性自校验。 |
| `tools/vmp/` | ARM64→字节码翻译器 `vmp.py`、纯 Python 模拟器 `vmsim3.py`(对拍验证)、覆盖率分析 `analyze_coverage.py`、ISA 多态 `gen_isa.py`。 |
| `tools/` | 驱动 `gen_multi_hooks.py`(枚举函数→翻译→生成 hook 桩+字节码)、后处理 `gcobf-post.py`(段改名/strip/selector 改名/wipe)、iOS 工具链安装与引擎编译验证脚本、NEON handler 单元测试 `neon_test.c`。 |
| `AntiDebug/` | 通用反调试/反注入模块(检测→延迟→二次确认→SIGKILL + 看门狗)。可选,按需集成。 |
| `samples/` | 中性测试样本 `demo.c`/`demo.dylib`(纯数学/向量函数),用于演示与回归,不含任何业务逻辑。 |

## 快速开始

```bash
# 1) 装 iOS 交叉工具链(clang + iPhoneOS SDK + lld),一次性
bash tools/setup_ios_toolchain.sh

# 2) 验证 VM 引擎能编译成 arm64 dylib
SDK=/path/to/iPhoneOS.sdk bash tools/verify_engine_ios.sh

# 3) 跑 NEON handler 单元测试(host 侧,验证 lane 语义)
cc -O2 -I VMP tools/neon_test.c -o /tmp/neon_test -lm && /tmp/neon_test

# 4) 看某个 dylib 的可虚拟化覆盖率
python3 tools/vmp/analyze_coverage.py samples/demo.dylib

# 5) 对目标 dylib 生成 VM 字节码 + hook 桩
python3 tools/gen_multi_hooks.py <你的.dylib> <输出目录>
#   可选环境变量:
#     GCOBF_TARGETS=foo,bar        额外强制虚拟化的函数名(其余全自动扫描)
#     GCOBF_WIPE_NAMED=foo,bar     静态抹除的函数名子串(被抹函数 fail-closed)
#     GCOBF_SEED=<int>             固定构建随机种子(可复现)
#     GCOBF_MINGAP=8               hook 安全间距(见文档)
#     GCOBF_BCJUNK=1 / _P=0.33     字节码垃圾注入(默认开)
#     GCOBF_INTEG=1                字节码完整性自校验(默认开)
#     GCOBF_NOSTUBPOLY=1           关入口桩多态(默认开)
```

详见 `使用教程_USAGE.md`(完整流程)与 `通用性与复用_REUSE.md`(如何套到你自己的项目)。

## 当前能力(已验证)

- 指令覆盖:整数全集 + 浮点标量(含 fmadd/fcsel/fcmp#0)+ **NEON 向量子集**(movi/ldr-q/three-same/fmla/dup/ins/ext/zip 等)。中性样本上字节覆盖随代码而定;以 NEON 密集代码为例,字节级虚拟化可达 ~60%。
- 字节码加密:逐指令 oc_key(32 位)+ 每函数 xor_key。
- 自保护:间接分发 + handler 分节(抗 IDA 交叉引用)、入口桩多态(变长+乱序+随机帧)、字节码完整性自校验(篡改→静默算错而非崩溃)、可选运行期反调试。
- ISA 多态:每次构建随机置换 opcode 值。
- 验证:VM 引擎 iOS arm64 真编译+链接;NEON handler C 单元测试;translate↔vmsim3 等价对拍(默认全开配置 vs 基线 100% 一致)。

## 继续开发
见 `REMAINING_TASKS.md`。

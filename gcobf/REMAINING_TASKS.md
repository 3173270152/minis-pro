# 剩余开发任务 (gcobf 混淆器引擎)

本文件给接手开发的人/模型。目标:把这套 iOS/arm64 代码混淆+虚拟化引擎从"中档"推向商业级
(VMProtect/Themida 量级)。按优先级排;每一项都遵循**先实现 → 能编译 → 能对拍就对拍 → 再真机**。

## 工程纪律(务必遵守)
- 改引擎后必须过:`tools/verify_engine_ios.sh`(iOS arm64 编译链接)+ `tools/neon_test.c`(handler 单测)。
- 改翻译器/字节码后必须过等价对拍:用 `tools/vmp/vmsim3.py` 对同一函数「改动前 vs 改动后」跑相同输入,返回值须一致(参见历史做法:translate 两版→vmsim3→比 R0)。
- 默认开关哲学:通用且已验证安全的特性默认开,留 `GCOBF_*` 环境变量可关(便于对拍调试)。

---

## P0 — handler 变异 (最高优先级, 当前最大短板)

**问题**:一次构建里所有同类 handler 是**字节完全相同**的固定 C 函数。逆向者识别出一个
`h_add` 就能模式匹配出全部,进而重建整套 VM 语义、写 devirtualizer。这是与 VMProtect 差距的**核心**。

**目标**:让每个 handler 实例在每次构建中**各不相同**,消除模式匹配。

**建议实现路径(二选一或结合)**:
1. **编译期每实例变异**:给每个 `hw_*` 包装函数按构建种子插入**随机等价垃圾**(对 `x16/x17`
   等非快照寄存器做死运算、随机 NOP 序列、等价指令替换),使同类 handler 的机器码指纹不同。
   可用一个 `VMJUNK(seed)` 宏在每个 handler 体内展开成由种子决定的不同垃圾。
   注意:垃圾绝不能触碰 `vm_ctx_t` 状态(R/V/FL/eval 栈/pc)。单测方式同 `neon_test.c`:
   构造已知字节码喂 handler,核对结果不变。
2. **handler 克隆+置换**:为每个 opcode 生成 N 个语义等价但代码不同的 handler 变体,
   跳转表每次构建随机选一个。配合已有的 ISA 多态(`gen_isa.py`)。

**验收**:两次不同种子的构建里,同一 opcode 的 handler 机器码字节不同(可用 `otool -tV` 比对);
引擎编译过;NEON 单测过;等价对拍 100%。

---

## P1 — 虚拟化前 MBA / 指令膨胀

**问题**:翻译器基本 1 条 ARM ≈ 1 条 VM op,字节码语义与原逻辑太接近 → 谁写出 VM 反编译器就能还原近原始逻辑。

**目标**:在**翻译成字节码之前**(或翻译时)对数据流做 MBA 恒等式展开 / 指令拆分合并,
拉开字节码与原逻辑的距离。注意 `obf/Substitution.cpp` 已有 LLVM-IR 层的 MBA,但那是给**未虚拟化**
代码用的;这里要的是**字节码层**的膨胀。

**现状**:已有 `GCOBF_BCJUNK` 字节码级**中性垃圾**注入(只动 eval 栈,100% 等价)。下一步是把垃圾
从"无副作用噪声"升级为"参与真实计算的等价变换"(更难被识别/消除)。

**验收**:等价对拍 100%;字节码反编译难度上升(人工评估)。

---

## P1 — σ 虚拟寄存器重映射

**问题**:逻辑寄存器 X0-X30 当前直通 `vm->R[0..30]`,反编译器一眼能对应。

**目标**:每函数随机置换逻辑寄存器到存储槽(σ 排列),打散对应关系。

**历史教训(重要)**:曾实现过,vmsim3 对拍只有 38% 一致 —— 根因是 σ 与 **VM 的 ABI 边界冲突**:
`h_call_*`/`h_svc`/HALT/cleanup 硬编码从 `R[0..7]` 读参数、`R[0]` 写返回值,而 σ 把逻辑 X0-X7
挪到了 σ(n) 槽。**正确修法**:让这些 ABI 边界 handler 变成 **σ-aware**——
整数参数从 `R[sigma[i]]` 读、返回写 `R[sigma[0]]`;`vm_ctx_t` 存 `u8 sigma[32]`;
vmsim3 也要同步 σ-aware 才能继续对拍。实现后必须真机验证(原生调用的 ABI 搬运模拟器验不全)。

---

## P2 — 字符串加密升级 (AEAD)

**现状**:`obf/StringObf.cpp` 是 xorshift 流密码 + 立即数密钥,扫 `eor×3` 循环特征 + 回溯
`movz/movk` 即可全量还原。

**目标**:换 **ChaCha20-Poly1305 / AES-GCM** 等 AEAD;密钥**运行时合成**(不以立即数落在调用点旁);
**懒解密**(用到才解,用完抹掉明文)。

---

## P2 — 其他红队项
- **函数表泄露**:虚拟化函数(hook 桩)不在 `LC_FUNCTION_STARTS` → 登记数 vs 实际数有可对比差额。
  可在 `gcobf-post.py` 后处理把桩补进函数表,或打散桩布局。
- **跳转表彻底加密**:当前 handler 表运行时栈上构建(非静态明文,已部分缓解);可进一步表项加密、取用即覆写。
- **不透明谓词多样化**:`obf/BogusControlFlow.cpp` 已用运行时值,但形式只有 3 种;扩充形式 + 多源取值。

---

## 已完成(供参考, 不用重做)
- NEON 向量子集翻译 + handler(movi/ldr-q/str-q/three-same 整数&浮点/fmla/fmls/two-reg-misc/dup/ins/umov/ext/zip-uzp-trn)。
- 浮点标量补齐:fmadd/fmsub/fnmadd/fnmsub、fcmp #0.0、fcsel、64 位源 scvtf/ucvtf/fcvtzs/fcvtzu。
- 自保护:间接分发 + handler 分节默认开(修了 Mach-O 段名 + 补齐跳转表 40 个漏掉的 opcode);
  入口桩多态(变长+乱序+随机帧);字节码完整性自校验(篡改→静默算错)。
- 字节码垃圾注入(eval 栈中性,100% 等价对拍)。
- ISA 多态(每构建随机 opcode 置换)。
- 验证基建:iOS 交叉编译、NEON 单测、vmsim3 等价对拍(已含 eval-stack op)。

## 关键文件地图
- 翻译器: `tools/vmp/vmp.py`(`decode()` 解码 ARM、`translate()` 发射字节码 + 字节码垃圾 + 尾部 CRC)
- 引擎: `VMP/vm_interp.c`(两条分发路径 + 尾部解析 + CRC 校验)、`VMP/vm_handlers/*.h`、`VMP/vm_dispatch.h`(跳转表)、`VMP/vm_opcodes.h`
- 驱动: `tools/gen_multi_hooks.py`(入口桩多态在此)
- 对拍: `tools/vmp/vmsim3.py`
- LLVM passes: `obf/*.cpp`

# 通用性与复用说明

> 问题：成品/工具链是通用的吗？能用在别的 iOS 项目吗？
> 结论：**引擎和工具是通用的（任意 iOS arm64 dylib 都能用）；只有少量"项目配置"需要按新项目改。**

---

## 一、分两层看

### ✅ 通用层（换项目**不用改**，直接拿去用）

| 组件 | 说明 |
|---|---|
| `tools/vmp/vmp.py` | ARM64→字节码翻译器。按指令编码工作，与具体项目无关。 |
| `VMP/vm_interp.c` + `vm_handlers/*.h` + `vm_opcodes.h`/`vm_decode.h`/`vm_types.h` | VM 解释器，纯通用。 |
| `obf/*.cpp`（`GCObf.dylib`） | LLVM pass 混淆器，对任何经它编译的代码生效。 |
| `tools/gcobf-post.py`（strip / rename-selectors / hide-exports / **wipe** / verify / report） | 对任意 64 位 arm64 Mach-O dylib 工作，不认项目。 |
| `tools/vmp/analyze_coverage.py`、`check_convergence.py`、`vmsim3.py` | 传 dylib 路径即用。 |
| `VMP/libdobby.a` | 通用 inline hook 引擎（iOS14+/arm64）。 |
| `AntiDebug/anti_debug_pro.c` + `anti_blobs.h` | 反调试是通用 C，不依赖某个 App。 |
| selector/类名改名+运行时还原机制 | 机制通用（数据是每项目生成的 `sel_map.h`）。 |

### 🔧 项目配置层（换项目**要改**，就这几处）

| 位置 | 改什么 |
|---|---|
| `tools/gen_multi_hooks.py` 顶部 | `DYLIB` / `OUT_H` / `OUT_XM` 路径 → 指向新项目 |
| `tools/gen_multi_hooks.py` 的 (已移除的「针对特定 ObjC 类的方法 hook」逻辑) | 这是**专门 hook 某个具体 ObjC 类的方法**的逻辑。新项目若没有这种类：**删掉或置空即可**——通用的 `Auto_<addr>` 全自动扫描（按 `LC_FUNCTION_STARTS`）对任何项目都工作，不需要它。 |
| 抹除名单 `GCOBF_WIPE_NAMED` / 禁抹 `WIPE_EXCLUDE_SUBSTR` | 用环境变量按你自己的项目指定，工具不内置具体名单 |
| `Makefile` | Theos 工程文件，天然每项目一份（源文件列表、framework 等） |
| 禁抹名单 `g_wipe_list.txt` 的筛选 | 每项目的 init/单例/渲染路径不同，分批上机定 |

> 一句话：**换项目 = 改 `gen_multi_hooks.py` 顶部几行 + 换 Makefile + 重新选命门/禁抹名单**，引擎零改动。

---

## 二、重要的「通用性边界」（务必知道）

1. **覆盖率数字不通用**。当前 ~80% 是针对 app 的**指令组合**算出来的。别的项目若大量用 **SIMD 向量 / C++ 模板 / 特殊指令**，可能触达 VM 还没支持的指令 → 覆盖率更低。VM 支持的指令集是固定的，项目指令越"常规"覆盖率越高。先对新项目跑 `analyze_coverage.py` 看真实覆盖率。
2. **成品 dylib 本身不通用**。`dist/app_deploy.dylib` 是 app 的保护成品，不能套到别的 App。通用的是「**生产这个成品的工具链**」。
3. **本版已无任何 App 专属逻辑**。(已移除的 ObjC 类方法 hook 逻辑)、`WIPE_NAMED_SUBSTR` 等具体符号名单本版已全部移除；强制虚拟化/抹除名单改走环境变量 GCOBF_TARGETS/GCOBF_WIPE_NAMED，默认空。
4. **A（selector 改名）的命门清单每项目不同**——机制通用，清单每项目给一份。
5. 平台假设通用但固定：**iOS 14+ / arm64（非 arm64e）/ TrollStore 或越狱 tweak 形态**。换到 arm64e、或非 tweak（如 App 内直接集成）需额外适配。

---

## 三、想让它更"开箱即用"（可选，Claude 可做）

现在换项目要手动改 `gen_multi_hooks.py` 几处。如果你要频繁用于多个项目，Claude 可以：
- 把所有「项目配置」抽到**一个独立配置文件**（如 `project.conf`：dylib 路径、命门方法、禁抹名单、wipe 模式），`gen_multi_hooks.py` 读它；
- 全自动扫描已是默认路径，无需任何项目专属配置；
- 给一个 `new_project.sh` 脚手架：传入新项目的 dylib 和 Makefile 就生成配置模板。

要的话告诉我，这是纯工程重构、风险低，能让「换项目」从「改代码」降到「填配置」。

---

## 四、复用一个新项目的最短步骤

```
1. 新项目用同一套 Makefile 风格接入 obf(GCObf.dylib)、VMP/vm_interp.c、AntiDebug/、VMPHooks.xm
2. 改 gen_multi_hooks.py 顶部: DYLIB/OUT_* 路径；(本版已无专属段，直接用命令行传目标 dylib 与输出目录)
3. make → python3 tools/gen_multi_hooks.py → make
4. python3 tools/vmp/analyze_coverage.py <你的dylib>   # 看真实覆盖率
5. tools/build_all.sh 一键后处理（strip/rename/hide/可选 wipe）
6. selector 改名、反调试虚拟化、wipe 名单(按需用环境变量指定) → 分批上机验证
```

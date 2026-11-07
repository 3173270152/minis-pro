// anti_debug_pro.c - 深度反调试 v2.0 (调试版)
//
// v2 相对 v1 的三处改动（都是为了能在真机上被验证）:
//   ① 常驻 watchdog: 每 5 秒复查 P_TRACED / 注入框架。
//      v1 只在 ctor 跑一次，游戏启动后再 attach 调试器就再也发现不了 —— 这是硬伤。
//   ② 全量日志: 每个检测项的真实返回值、brk 扫描命中数、扫描耗时、时序基线与倍率,
//      全部追加写到 $HOME/Documents/adbg.log（$HOME 是宿主 app 的容器，
//      和 VMP 日志同一个位置，用 Filza 能直接看）。
//   ③ 自测钩子: $HOME/Documents/.adbg_selftest 存在时, adbg_frameworks 直接返回命中。
//      用途 = 在没有 Frida/调试器的设备上验证「检测到 → 随机延迟 → 二次确认 → SIGKILL」
//      这条完整链路。日志里会标 force=1, 不会和真实命中混淆。
//
// 设计原则不变:
//   * 软信号(brk/时序)只置位不杀; 硬信号(P_TRACED/注入框架)才走延迟击杀
//   * 绝不检测 Substrate / ellekit / libhooker / substitute（本 dylib 就跑在上面）
//   * 黑名单字符串 XOR 0x5A 加密, strings 搜不到
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach_time.h>
#include <dlfcn.h>

#include "anti_blobs.h"

#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif
#ifndef CTL_KERN
#define CTL_KERN 1
#endif
#ifndef KERN_PROC
#define KERN_PROC 14
#endif
#ifndef KERN_PROC_PID
#define KERN_PROC_PID 1
#endif

#define AD_TRACED      (1u << 0)
#define AD_BREAKPOINT  (1u << 1)   // 软信号
#define AD_FRIDA       (1u << 2)   // 硬信号
#define AD_DUMPTOOL    (1u << 3)   // 硬信号
#define AD_TIMING      (1u << 4)   // 软信号
#define AD_FORCED      (1u << 5)   // 自测钩子命中
#define AD_HARD        (AD_FRIDA | AD_DUMPTOOL | AD_FORCED)

volatile uint32_t __gcob_ad_status = 0;
static volatile uint32_t adbg_base_ticks = 0;
static volatile int adbg_kill_armed = 0;
static volatile int adbg_watch_started = 0;
static volatile unsigned adbg_log_lines = 0;
static volatile int adbg_brk_ref = -1;   // brk 命中数基线(ctor 首次扫描时建立)

/* ---------------- 日志 ---------------- */
static void adbg_log(const char *fmt, ...) {
    const char *h;
    char path[400];
    struct timeval tv;
    FILE *f;
    va_list ap;
    if (adbg_log_lines > 400) return;          // 防止日志无限增长
    h = getenv("HOME");
    if (!h) return;
    snprintf(path, sizeof(path), "%s/Documents/adbg.log", h);
    f = fopen(path, "a");
    if (!f) return;
    gettimeofday(&tv, NULL);
    fprintf(f, "[%ld.%03d] ", (long)tv.tv_sec, (int)(tv.tv_usec / 1000));
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
    adbg_log_lines++;
}

/* ---------------- 弱随机 ---------------- */
static uint32_t adbg_rand(void) {
    static volatile uint32_t s = 0;
    uint32_t v = s;
    if (!v)
        v = (uint32_t)mach_absolute_time() ^ ((uint32_t)getpid() << 16)
          ^ (uint32_t)(uintptr_t)&s ^ 0x9E3779B9u;
    v ^= v << 13; v ^= v >> 17; v ^= v << 5;
    s = v;
    return v;
}

/* ---------------- 自测钩子 ---------------- */
/* ★ 自测钩子已在正式版移除（原来读 $HOME/Documents/.adbg_selftest 就判定命中）。
 *   保留空函数只是为了不动调用点，-O2 会把它内联成常量 0，代码里不会留下痕迹。*/
static int adbg_force(void) { return 0; }

/* ---------------- 1) sysctl P_TRACED ---------------- */
static int adbg_traced(void) {
    int mib[4];
    struct kinfo_proc info;
    size_t size = sizeof(info);
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PID;
    mib[3] = (int)getpid();
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return -1;   // -1 = 调用失败
    if (size < sizeof(info)) return -1;
    return (info.kp_proc.p_flag & P_TRACED) ? 1 : 0;
}

/* ---------------- 2) __text 里扫 brk #1 ---------------- */
static int adbg_brk_scan(unsigned *hitsOut, unsigned *sizeOut) {
    Dl_info di;
    const struct mach_header_64 *mh;
    const struct load_command *lc;
    uintptr_t base, textAddr = 0;
    uint64_t textSize = 0;
    uint32_t i;
    uint64_t k, n;
    unsigned hits = 0;
    const volatile uint32_t *p;

    if (hitsOut) *hitsOut = 0;
    if (sizeOut) *sizeOut = 0;
    if (!dladdr((void *)adbg_brk_scan, &di)) return -1;      // -1 = dladdr 失败
    mh = (const struct mach_header_64 *)di.dli_fbase;
    if (!mh || mh->magic != MH_MAGIC_64) return -2;        // -2 = 不是 64 位 Mach-O
    base = (uintptr_t)di.dli_fbase;

    lc = (const struct load_command *)((const char *)mh + sizeof(struct mach_header_64));
    for (i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (memcmp(seg->segname, "__TEXT", 6) == 0) {
                const struct section_64 *sec =
                    (const struct section_64 *)((const char *)seg + sizeof(struct segment_command_64));
                uint32_t j;
                for (j = 0; j < seg->nsects; j++, sec++) {
                    if ((sec->flags & S_ATTR_PURE_INSTRUCTIONS) ||
                        memcmp(sec->sectname, "__text", 6) == 0) {
                        textAddr = base + (uintptr_t)(sec->addr - seg->vmaddr);
                        textSize = sec->size;
                        break;
                    }
                }
            }
        }
        if (lc->cmdsize == 0) break;
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!textAddr || textSize < 8) return -3;              // -3 = 没找到 __text

    if (sizeOut) *sizeOut = (unsigned)textSize;
    p = (const volatile uint32_t *)textAddr;
    n = textSize / 4;
    for (k = 0; k < n; k++) {
        if (p[k] == 0xD4200020u) hits++;
    }
    if (hitsOut) *hitsOut = hits;

    /* ★ 不能"命中就报警"。
     * 实机日志: 本 dylib 的 __text 里本来就嵌着一批 D4200020 数据字
     * (每 0x6C 字节一个的结构体数组, 连续 8 个 + 连续 10 个),
     * otool 反汇编时也把它当数据, 不是指令。
     * 改成基线对比: ctor 首次扫描建基线, 之后 hits 变多才算被下断点。*/
    if (adbg_brk_ref < 0) {
        adbg_brk_ref = (int)hits;
        return 0;
    }
    return (hits > (unsigned)adbg_brk_ref) ? 1 : 0;
}

/* ---------------- 3) 注入框架 / dump 工具扫描 ---------------- */
static int adbg_contains(const char *hay, const char *needle, unsigned nlen) {
    unsigned i, j;
    for (i = 0; hay[i]; i++) {
        for (j = 0; j < nlen; j++)
            if (hay[i + j] != needle[j]) break;
        if (j == nlen) return 1;
    }
    return 0;
}

/* 返回命中下标（-1 = 没命中），kind 里填 AD_FRIDA / AD_DUMPTOOL */
static int adbg_frameworks(uint32_t *kind) {
    uint32_t n = _dyld_image_count();
    uint32_t i;
    unsigned k;
    for (i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        for (k = 0; k < gcob_name_count; k++) {
            unsigned char buf[64];
            unsigned L = gcob_names[k].len;
            unsigned j;
            if (L == 0 || L >= sizeof(buf)) continue;
            for (j = 0; j < L; j++)
                buf[j] = (unsigned char)(gcob_names[k].enc[j] ^ 0x5A);
            if (adbg_contains(nm, (const char *)buf, L - 1)) {
                *kind |= (k < 3) ? AD_FRIDA : AD_DUMPTOOL;
                return (int)k;
            }
        }
    }
    return -1;
}

/* ---------------- 4) 时序标定 ---------------- */
static uint32_t adbg_timing_once(void) {
    volatile uint32_t x = 1;
    uint32_t i;
    uint64_t t0 = mach_absolute_time();
    for (i = 0; i < 2000; i++) x = x * 1103515245u + 12345u;
    uint64_t t1 = mach_absolute_time();
    (void)x;
    return (uint32_t)(t1 - t0);
}

static void adbg_calibrate(void) {
    uint32_t best = 0xFFFFFFFFu;
    int i;
    for (i = 0; i < 8; i++) {
        uint32_t t = adbg_timing_once();
        if (t && t < best) best = t;
    }
    adbg_base_ticks = (best == 0xFFFFFFFFu) ? 0 : best;
}

/* ---------------- 5) 延迟击杀线程 ---------------- */
static void *adbg_killer(void *arg) {
    uint32_t delay = 3 + (adbg_rand() % 12);
    uint32_t i;
    int confirm;
    uint32_t fk = 0;
    (void)arg;
    adbg_log("KILLER armed delay=%us status=0x%x", delay, __gcob_ad_status);
    for (i = 0; i < delay; i++) sleep(1);
    confirm = (adbg_traced() == 1) || (adbg_frameworks(&fk) >= 0) || adbg_force();
    adbg_log("KILLER wake confirm=%d status=0x%x -> %s", confirm,
           __gcob_ad_status, confirm ? "SIGKILL" : "abort(环境已干净)");
    if (confirm) kill(getpid(), SIGKILL);
    return 0;
}

static void adbg_arm_killer(void) {
    pthread_t th;
    pthread_attr_t attr;
    if (adbg_kill_armed) return;
    adbg_kill_armed = 1;
    if (pthread_attr_init(&attr) != 0) return;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&th, &attr, adbg_killer, 0);
    pthread_attr_destroy(&attr);
}

/* ---------------- 6) 常驻监测（v1 没有，attach 调试器后能发现）---------------- */
static void *adbg_watchdog(void *arg) {
    int tick = 0;
    (void)arg;
    for (;;) {
        uint32_t st = 0, fk = 0;
        int tr, fw, force;
        usleep(5 * 1000 * 1000);       // 5 秒
        tick++;
        tr = adbg_traced();
        fw = adbg_frameworks(&fk);
        force = adbg_force();
        if (tr == 1) st |= AD_TRACED;
        if (fw >= 0) st |= fk;
        if (force) st |= AD_FORCED;

        if (st) {
            __gcob_ad_status |= st;
            adbg_log("WATCH tick=%d traced=%d fw_idx=%d force=%d -> status=0x%x",
                   tick, tr, fw, force, __gcob_ad_status);
            if (__gcob_ad_status & AD_HARD) adbg_arm_killer();
        } else if (tick <= 6) {
            adbg_log("WATCH tick=%d clean (traced=%d fw=-1)", tick, tr);
        }
    }
    return 0;
}

/* ---------------- 7) 对外接口 ---------------- */

__attribute__((visibility("hidden"), noinline))
uint32_t __gcob_ad_query(void) {
    return __gcob_ad_status;
}

__attribute__((visibility("hidden"), noinline))
void __gcob_guard_pro(void) {
    uint32_t st = 0, fk = 0;
    int tr, fw, brk = 0, force;
    unsigned hits = 0, textSize = 0;
    uint32_t tScan0, tScan1, tTim;
    uint64_t t0;

    adbg_log("=== GUARD enter (pid=%d) ===", (int)getpid());

    t0 = mach_absolute_time();
    adbg_calibrate();
    adbg_log("CALIB base_ticks=%u (8 次取最小)", adbg_base_ticks);

    tr = adbg_traced();
    if (tr == 1) st |= AD_TRACED;
    adbg_log("CHECK traced=%d", tr);

    fw = adbg_frameworks(&fk);
    if (fw >= 0) st |= fk;
    adbg_log("CHECK frameworks idx=%d kind=0x%x", fw, fk);

    tScan0 = (uint32_t)mach_absolute_time();
    brk = adbg_brk_scan(&hits, &textSize);
    tScan1 = (uint32_t)mach_absolute_time();
    if (brk == 1) st |= AD_BREAKPOINT;
    adbg_log("CHECK brk_scan ret=%d hits=%u ref=%d textSize=%u ticks=%u", brk, hits,
           adbg_brk_ref, textSize, tScan1 - tScan0);

    tTim = adbg_timing_once();
    if (adbg_base_ticks && tTim > adbg_base_ticks * 25u) st |= AD_TIMING;
    adbg_log("CHECK timing=%u base=%u ratio=%u/100", tTim, adbg_base_ticks,
           adbg_base_ticks ? (unsigned)((uint64_t)tTim * 100u / adbg_base_ticks) : 0);

    force = adbg_force();
    if (force) st |= AD_FORCED;
    adbg_log("CHECK force=%d", force);

    __gcob_ad_status = st;
    adbg_log("GUARD done status=0x%x totalTicks=%llu", st,
           (unsigned long long)(mach_absolute_time() - t0));

    if (st & AD_HARD) adbg_arm_killer();

    if (!adbg_watch_started) {
        pthread_t th;
        pthread_attr_t attr;
        adbg_watch_started = 1;
        if (pthread_attr_init(&attr) == 0) {
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            pthread_create(&th, &attr, adbg_watchdog, 0);
            pthread_attr_destroy(&attr);
            adbg_log("WATCHDOG started (5s interval)");
        }
    }
}

__attribute__((visibility("hidden"), noinline))
uint32_t __gcob_ad_rescan(void) {
    uint32_t st = __gcob_ad_status, fk = 0;
    if (adbg_traced() == 1) st |= AD_TRACED;
    if (adbg_frameworks(&fk) >= 0) st |= fk;
    if (adbg_force()) st |= AD_FORCED;
    __gcob_ad_status = st;
    return st;
}

/* ---------------- 8) VMP 自保护检查点 ----------------
 * vm_interp.c 的 vm_entry 每次被调用都会走这里（所有被 VMP 保护的函数共用这一条路径）。
 * 每 16 次调用做一次轻量检测，开销摊薄到几乎为零。
 * 好处:
 *   ① 一处覆盖全部 VMP 函数, 不用改 18 个 hook
 *   ② 检测藏进 VM 解释器的常规路径, 静态分析时和 dispatch 逻辑混在一起
 *   ③ 逆向者想绕反调试, 必须先看懂 VM, 成本翻倍
 * 用 weak 声明调用, 这样单独编 VM 模块时不会链接失败。*/
__attribute__((visibility("hidden"), noinline))
uint32_t adbg_checkpoint(void) {
    static volatile unsigned ck = 0;
    unsigned n = ++ck;
    uint32_t fk = 0;

    if ((n & 0x0F) != 0) return __gcob_ad_status;   /* 每 16 次查一次 */

    if (adbg_traced() == 1) {
        __gcob_ad_status |= AD_TRACED;
        adbg_arm_killer();
    }
    if (adbg_frameworks(&fk) >= 0) {
        __gcob_ad_status |= fk;
        adbg_arm_killer();
    }
    return __gcob_ad_status;
}

/* 源码集成入口: dylib 加载时自动跑（优先级 102，和 AntiTamper 的 ctor 同档） */
__attribute__((constructor(102)))
static void adbg_ctor_entry(void) {
    __gcob_guard_pro();
}

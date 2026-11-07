/* demo.c — 中性测试样本:覆盖整数/浮点/NEON/分支/循环, 用于演示和回归混淆器。
 * 不含任何业务逻辑, 纯粹是给虚拟化引擎喂多样的 arm64 指令。
 * 编译: clang -target arm64-apple-ios14.0 -O2 -dynamiclib demo.c -o demo.dylib */
#include <stdint.h>
#include <math.h>

int64_t calc_mix(int64_t a, int64_t b, int64_t c) {
    int64_t s = 0;
    for (int64_t i = 0; i < (b & 63); i++) {
        s += (a * i) ^ (c + i);
        if (s & 1) s -= (a >> 2); else s += (b << 1);
        s = (s * 0x9E3779B1) + (c | i);
    }
    return s ^ (a + b - c);
}

uint32_t bit_tricks(uint32_t x, uint32_t y) {
    x = (x << 13) | (x >> 19);
    x ^= y * 2654435761u;
    x += __builtin_popcount(y) * 31u;
    return (x & 0xFF00FF00u) | (y & 0x00FF00FFu);
}

double vec_math(const double *p, int n) {
    double acc = 0.0, m = -1e300;
    for (int i = 0; i < n; i++) {
        double v = p[i] * p[i] + 3.5 * p[i] - 2.0;
        acc += sqrt(v > 0 ? v : -v);
        if (v > m) m = v;
    }
    return acc / (double)(n ? n : 1) + m;
}

void saxpy(float a, const float *x, float *y, int n) {
    for (int i = 0; i < n; i++) y[i] = a * x[i] + y[i];
}

int classify(int score) {
    if (score < 0) return -1;
    switch (score / 10) {
        case 0: case 1: case 2: case 3: case 4: case 5: return 0;
        case 6: case 7: return 1;
        case 8: return 2;
        default: return 3;
    }
}

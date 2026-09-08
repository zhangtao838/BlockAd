/*
 * blocklist.c — 实现见 blocklist.h
 *
 * 注意：
 *  - 本文件不依赖 Foundation / UIKit / substrate，可独立编译成测试程序
 *    在 macOS/Linux 上做单元测试（见 test/ 目录）。
 *  - 每个进程的内存开销约 = 域名数 × (字符串 ~25B + 指针 8B)，12 万条
 *    上限下约 4MB，仅对被注入且启用去广告的 App 生效。
 */
#include "blocklist.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 读写锁：允许后台"热更新规则"时并发安全的读/交换。
 * Windows 单测环境无 pthread，退化为空操作。 */
#if defined(_WIN32)
# define bl_lock_rd() do {} while (0)
# define bl_lock_wr() do {} while (0)
# define bl_unlock()  do {} while (0)
#else
# include <pthread.h>
static pthread_rwlock_t s_lock = PTHREAD_RWLOCK_INITIALIZER;
# define bl_lock_rd() pthread_rwlock_rdlock(&s_lock)
# define bl_lock_wr() pthread_rwlock_wrlock(&s_lock)
# define bl_unlock()  pthread_rwlock_unlock(&s_lock)
#endif

/* 上限与井喷保护：超出即停止解析，保护 jetsam 内存限制 */
#define BL_MAX_ENTRIES  300000
/* 单行最长（合法域名 + 可变前缀） */
#define BL_MAX_LINE     512
/* 单个域名最长 */
#define BL_MAX_DOMAIN   253

typedef struct {
    char **items;   /* 反转小写域名数组，字典序升序 */
    size_t count;
    size_t cap;
    char   loaded;
    char   owned;   /* items 是否为自身 malloc 的（可 free）；内置只读数组为 0 */
    char  *path;    /* 成功加载的列表路径（诊断用；内存内置为 NULL） */
} blist_t;

static blist_t s_b;

static int cmp_ptr_str(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* 反转 + 小写 */
static char *rev_lower(const char *src)
{
    size_t n = strlen(src);
    char *r = malloc(n + 1);
    if (!r) return NULL;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)src[n - 1 - i];
        r[i] = (char)tolower(c);
    }
    r[n] = '\0';
    return r;
}

/* 去掉 hosts 前缀 "0.0.0.0 " / "127.0.0.1 " / "::1 " / ":: "，返回域名起点 */
static const char *skip_hosts_prefix(const char *p)
{
    if (strncmp(p, "0.0.0.0 ", 8) == 0) return p + 8;
    if (strncmp(p, "127.0.0.1 ", 10) == 0) return p + 10;
    if (strncmp(p, "::1 ", 4) == 0) return p + 4;
    if (strncmp(p, ":: ", 3) == 0) return p + 3;
    return p;
}

/* 判定一行是否可接受为域名：只允许字母数字 点 短横 下划线 */
static int valid_domain_str(const char *s, size_t n)
{
    if (n == 0 || n > BL_MAX_DOMAIN) return 0;
    /* 首字符不能是点 */
    if (s[0] == '.') return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '.' || c == '-' || c == '_')) return 0;
    }
    return 1;
}

int bl_load_path(const char *path)
{
    if (s_b.loaded) return 1;
    if (!path) return 0;

    FILE *f = fopen(path, "r");
    if (!f) return 0;

    size_t cap = 8192, n = 0;
    char **arr = calloc(cap, sizeof(char *));
    if (!arr) {
        fclose(f);
        return 0;
    }

    char line[BL_MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        size_t len = strlen(line);
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len == 0 || line[0] == '#') continue;

        const char *d = skip_hosts_prefix(line);
        if (*d == '#') continue;
        /* 兼容 "*.domain" 通配条目：剥掉前导 '*.' */
        if (*d == '.') d++;          /* 异常行防御 */
        if (*d == '*') d = (d[1] == '.') ? d + 2 : (d + 1);
        len = strlen(d);
        if (!valid_domain_str(d, len)) continue;

        if (n == BL_MAX_ENTRIES) break;   /* 保编译内存 */
        if (n == cap) {
            cap <<= 1;
            char **na = realloc(arr, cap * sizeof(char *));
            if (!na) break;
            arr = na;
        }
        arr[n] = rev_lower(d);
        if (!arr[n]) break;
        n++;
    }
    fclose(f);

    if (n == 0) {
        free(arr);
        return 0;
    }

    /* 排序 + 去重 */
    qsort(arr, n, sizeof(char *), cmp_ptr_str);
    size_t m = 0;
    for (size_t i = 0; i < n; i++) {
        if (m > 0 && strcmp(arr[m - 1], arr[i]) == 0) {
            free(arr[i]);
        } else {
            arr[m++] = arr[i];
        }
    }

    bl_lock_wr();
    s_b.items = arr;
    s_b.count = m;
    s_b.cap   = cap;
    s_b.owned = 1;
    if (s_b.path) free(s_b.path);
    size_t plen = strlen(path) + 1;
    s_b.path = malloc(plen);
    if (s_b.path) memcpy(s_b.path, path, plen);
    s_b.loaded = 1;
    bl_unlock();
    return 1;
}

int bl_loaded(void)
{
    return s_b.loaded;
}

/* 从内存文本（每行一个域名/hosts 格式）解析并热替换当前列表。
 * 供"自动更新规则"使用：后台下载 → 解析 → 加写锁原子替换，读锁保证并发安全。 */
int bl_load_text(const char *text)
{
    if (!text) return 0;   /* 热更新：不做已加载短路，始终尝试替换 */

    size_t cap = 65536, n = 0;
    char **arr = calloc(cap, sizeof(char *));
    if (!arr) return 0;

    const char *p = text;
    while (*p && n < BL_MAX_ENTRIES) {
        const char *eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        if (len > BL_MAX_LINE - 1) len = BL_MAX_LINE - 1;
        char line[BL_MAX_LINE];
        memcpy(line, p, len);
        line[len] = '\0';
        while (len && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len && line[0] != '#') {
            const char *d = skip_hosts_prefix(line);
            if (*d == '*') d = (d[1] == '.') ? d + 2 : d + 1;
            size_t dlen = strlen(d);
            if (valid_domain_str(d, dlen)) {
                if (n == cap) {
                    cap <<= 1;
                    char **na = realloc(arr, cap * sizeof(char *));
                    if (!na) break;
                    arr = na;
                }
                char *r = rev_lower(d);
                if (r) arr[n++] = r;
            }
        }
        if (!eol) break;
        p = eol + 1;
    }
    if (n == 0) {
        free(arr);
        return 0;
    }

    qsort(arr, n, sizeof(char *), cmp_ptr_str);
    size_t m = 0;
    for (size_t i = 0; i < n; i++) {
        if (m > 0 && strcmp(arr[m - 1], arr[i]) == 0) {
            free(arr[i]);
        } else {
            arr[m++] = arr[i];
        }
    }

    bl_lock_wr();
    if (s_b.owned) {
        for (size_t i = 0; i < s_b.count; i++) free(s_b.items[i]);
        free(s_b.items);
    }
    if (s_b.path) free(s_b.path);
    s_b.items = arr;
    s_b.count = m;
    s_b.cap   = cap;
    s_b.owned = 1;
    s_b.path  = NULL;
    s_b.loaded = 1;
    bl_unlock();
    return 1;
}

int bl_use_array(const char *const *sortedRev, size_t n)
{
    if (s_b.loaded) return 1;
    if (!sortedRev || n == 0) return 0;

    bl_lock_wr();
    if (s_b.path) free(s_b.path);
    s_b.items  = (char **)sortedRev;   /* 指向只读内置数据，不复制、不 free */
    s_b.count  = n;
    s_b.cap    = 0;
    s_b.path   = NULL;
    s_b.owned  = 0;
    s_b.loaded = 1;
    bl_unlock();
    return 1;
}

size_t bl_count(void)
{
    return s_b.loaded ? s_b.count : 0;
}

const char *bl_path(void)
{
    return s_b.path;
}

void bl_cleanup(void)
{
    if (s_b.owned) {
        for (size_t i = 0; i < s_b.count; i++) free(s_b.items[i]);
        free(s_b.items);
    }
    if (s_b.path) free(s_b.path);
    memset(&s_b, 0, sizeof(s_b));
}

/*
 * 在排序数组中精确查找一个候选串（候选即反向域名的一个标签边界前缀）。
 * 返回 1 命中，0 未命中。
 */
static int exact_lookup(const char *candidate)
{
    size_t len = strlen(candidate);
    size_t lo = 0, hi = s_b.count;

    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        const char *item = s_b.items[mid];
        int c = strncmp(candidate, item, len);
        if (c == 0) {
            /* 前缀一致：item 更长则 item 更大 → 往小找 */
            c = item[len] ? -1 : 0;
        }
        if (c < 0) hi = mid;
        else lo = mid + 1;
    }
    /* 插入点为 lo，检查 lo-1 是否恰好等于候选 */
    return (lo > 0 && strncmp(candidate, s_b.items[lo - 1], len) == 0
            && s_b.items[lo - 1][len] == '\0');
}

/*
 * 命中判定：
 *   host = ads.doubleclick.net
 *   rn   = ten.kcilcelbuod.sda     （反转小写）
 *   候选 = "ten" / "ten.kcilcelbuod" / "ten.kcilcelbuod.sda"
 *   列表里若有 doubleclick.net -> 反转 "ten.kcilcelbuod" 即命中。
 */
int bl_host_blocked(const char *host)
{
    int blocked = 0;
    bl_lock_rd();
    if (!host) goto done;
    if (!s_b.loaded) goto done;

    size_t n = strlen(host);
    if (n == 0 || n >= BL_MAX_LINE) goto done;

    /* IP 字面量（无任何字母）直接放行 */
    int has_alpha = 0;
    for (size_t i = 0; i < n; i++) {
        if (isalpha((unsigned char)host[i])) { has_alpha = 1; break; }
    }
    if (!has_alpha) goto done;

    char rn[BL_MAX_LINE];
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)host[n - 1 - i];
        rn[i] = (char)tolower(c);
    }
    rn[n] = '\0';

    /* 每个标签边界截断出一个候选前缀 */
    for (size_t i = 0; i < n; i++) {
        if (rn[i] == '.') {
            if (i == 0) continue;      /* 前导点（非法但防御） */
            rn[i] = '\0';
            if (exact_lookup(rn)) { rn[i] = '.'; blocked = 1; goto done; }
            rn[i] = '.';
        }
    }
    /* 完整串（域名本身被精确命中） */
    blocked = exact_lookup(rn);
done:
    bl_unlock();
    return blocked;
}
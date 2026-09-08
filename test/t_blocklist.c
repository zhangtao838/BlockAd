/*
 * t_blocklist.c — blocklist.c 核心逻辑单元测试（macOS/Linux 直接编译运行）
 *
 * 用法：clang t_blocklist.c ../blocklist.c -o t_blocklist && ./t_blocklist
 * 断言覆盖：
 *   - 精确域名命中
 *   - 任意子域名命中
 *   - 不相关域名放行
 *   - IP 字面量放行
 *   - 多级子域名命中
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../blocklist.h"

/* 跨平台临时文件：macOS/Linux 用 /tmp，Windows 用当前目录 */
#ifdef _WIN32
static const char *LIST_PATH = "blockad_test_list.tmp";
#else
static const char *LIST_PATH = "/tmp/blockad_test_list.txt";
#endif

static const char kList[] =
    "doubleclick.net\n"
    "googleadservices.com\n"
    "googlesyndication.com\n"
    "criteo.com\n"
    "taboola.com\n"
    "0.0.0.0 umeng.com\n"      /* hosts 格式也应能解析 */
    "*.adservice.google.com\n";/* 通配前缀应被剥离成 adservice.google.com */

static int failures = 0;

static void check(const char *host, int expect_blocked)
{
    int got = bl_host_blocked(host);
    int pass = (got == expect_blocked);
    if (!pass) failures++;
    printf("[%s] %-28s expect=%d got=%d\n",
           pass ? "PASS" : "FAIL", host, expect_blocked, got);
}

int main(void)
{
    const char *path = LIST_PATH;
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen"); return 2; }
    fputs(kList, f);
    fclose(f);

    if (!bl_load_path(path)) {
        printf("FAIL: 无法加载列表 %s\n", path);
        remove(path);
        return 1;
    }
    printf("list loaded OK\n");

    /* 命中类 */
    check("doubleclick.net", 1);
    check("ads.doubleclick.net", 1);
    check("a.b.ads.doubleclick.net", 1);
    check("www.googleadservices.com", 1);
    check("ssp.criteo.com", 1);
    check("umeng.com", 1);
    check("push.umeng.com", 1);
    check("adservice.google.com", 1);
    check("s0.adservice.google.com", 1);  /* *.adservice.google.com 剥前缀后拦截其所有子域 */
    check("google.com", 0);               /* 父域不受子域命中影响 */

    /* 放行类 */
    check("apple.com", 0);
    check("www.apple.com", 0);
    check("telegram.org", 0);
    check("github.com", 0);
    check("1.2.3.4", 0);
    check("2001:db8::1", 0);
    check("", 0);
    check(NULL, 0);

    bl_cleanup();

    /* 内置只读数组测试（反转+小写+排序，零拷贝） */
    printf("\n-- 内置只读数组测试 --\n");
    {
        static const char *const memDomains[] = {
            "moc.gnemu",            /* umeng.com 反转 */
            "ten.kcilcelbuod",      /* doubleclick.net 反转 */
            "ten.kcilcelbuod.sda",  /* ads.doubleclick.net 反转 */
        };
        if (bl_use_array(memDomains, sizeof(memDomains) / sizeof(memDomains[0]))) {
            check("doubleclick.net", 1);
            check("a.b.doubleclick.net", 1);
            check("umeng.com", 1);
            check("apple.com", 0);
        } else {
            printf("FAIL: bl_use_array 加载失败\n");
            failures++;
        }
    }
    /* 内存文本热更新测试（自动更新规则的路径） */
    printf("\n-- 内存文本热更新测试 --\n");
    {
        const char *text =
            "# 注释行\n"
            "doubleclick.net\n"
            "0.0.0.0 umeng.com\n"
            "*.adservice.google.com\n";
        if (bl_load_text(text)) {
            check("doubleclick.net", 1);
            check("a.doubleclick.net", 1);
            check("umeng.com", 1);
            check("s0.adservice.google.com", 1);
            check("apple.com", 0);
        } else {
            printf("FAIL: bl_load_text 失败\n");
            failures++;
        }
    }
    bl_cleanup();
    remove(path);

    if (failures) {
        printf("\n=== %d 个用例失败 ===\n", failures);
        return 1;
    }
    printf("\n=== 全部通过 ===\n");
    return 0;
}